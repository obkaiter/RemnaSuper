"""Versioned JSON and human-readable summary for measured values only."""

import json
from datetime import datetime, timezone
from pathlib import Path

WEIGHTS = {"tcp": 25, "stability": 15, "udp": 20, "jitter": 10,
           "under_load": 15, "echo": 10, "pmtu": 5}
THRESHOLDS = {
    "tcp": [(0, 0), (0.2, 2.5), (0.4, 5), (0.6, 7), (0.8, 8.5), (1, 10)],
    "udp": [(0, 10), (0.05, 10), (0.2, 8), (1, 5), (3, 2), (5, 0)],
    "under_load": [(0, 10), (15, 10), (30, 8), (75, 5), (150, 2), (300, 0)],
    "retrans_per_gib": [(0, 10), (10, 9), (100, 7), (500, 4), (2000, 0)],
    "jitter": [(0, 10), (2, 9), (5, 7), (15, 4), (40, 0)],
    "echo_ratio": [(1, 10), (1.5, 8), (2, 6), (4, 3), (10, 0)],
    "drop_fraction": [(0, 10), (0.05, 8), (0.2, 4), (0.5, 0)],
    "pmtu": [(576, 0), (1200, 5), (1280, 7), (1400, 9), (1500, 10)],
}


def scale(value, points):
    if value is None:
        return None
    if value <= points[0][0]:
        return points[0][1]
    for (x0, y0), (x1, y1) in zip(points, points[1:]):
        if value <= x1:
            return y0 + (value - x0) * (y1 - y0) / (x1 - x0)
    return points[-1][1]


def relevant(results, direction, kind):
    return [item for item in results if item["direction"] == direction and
            item["kind"] == kind and item["status"] == "FINISHED"]


def metric(item, *keys):
    value = item.get("metrics", {})
    for key in keys:
        value = value.get(key) if isinstance(value, dict) else None
    return value


def score_direction(results, direction, target, cap):
    components = {}
    tcp = relevant(results, direction, "tcp")
    tcp1 = next((item for item in tcp if item["params"].get("streams") == 1), None)
    if tcp1:
        components["tcp"] = scale((metric(tcp1, "receiver_mbps") or 0) / target,
                                  THRESHOLDS["tcp"])
    stability = relevant(results, direction, "stability")
    if stability:
        sample = stability[0]
        bytes_sent = metric(sample, "bytes")
        retrans = metric(sample, "retransmits")
        if bytes_sent and retrans is not None:
            per_gib = retrans / (bytes_sent / 1073741824)
            intervals = metric(sample, "interval_mbps") or []
            if intervals:
                ordered = sorted(intervals)
                median = ordered[len(ordered) // 2]
                drops = sum(value < median * 0.5 for value in intervals) / len(intervals)
                components["stability"] = (0.7 * scale(per_gib, THRESHOLDS["retrans_per_gib"]) +
                                           0.3 * scale(drops, THRESHOLDS["drop_fraction"]))
    udp = relevant(results, direction, "udp")
    if udp:
        loss = [metric(item, "loss_pct") for item in udp]
        loss = [value for value in loss if value is not None]
        if loss:
            components["udp"] = scale(sum(loss) / len(loss), THRESHOLDS["udp"])
    baseline = relevant(results, direction, "baseline")
    base_p95 = metric(baseline[0], "rtt_ms", "p95") if baseline else None
    base_p50 = metric(baseline[0], "rtt_ms", "p50") if baseline else None
    if base_p95 is not None and base_p50 is not None:
        components["jitter"] = scale(max(0, base_p95 - base_p50), THRESHOLDS["jitter"])
    under = relevant(results, direction, "under_load")
    under_p95 = metric(under[0], "load_rtt_ms", "p95") if under else None
    if base_p95 is not None and under_p95 is not None:
        components["under_load"] = scale(max(0, under_p95 - base_p95),
                                         THRESHOLDS["under_load"])
    echo = relevant(results, direction, "echo")
    p95 = metric(echo[0], "rtt_ms", "p95") if echo else None
    if p95 is not None and base_p95:
        components["echo"] = scale(max(1, p95 / base_p95), THRESHOLDS["echo_ratio"])
    pmtu = relevant(results, direction, "pmtu")
    if pmtu and metric(pmtu[0], "pmtu"):
        components["pmtu"] = scale(metric(pmtu[0], "pmtu"), THRESHOLDS["pmtu"])
    coverage = sum(WEIGHTS[name] for name in components)
    partial = (sum(components[name] * WEIGHTS[name] for name in components) / coverage
               if coverage else None)
    files = relevant(results, direction, "file")
    mandatory = bool(files and metric(files[0], "checksum_ok") is True and udp and tcp1 and
                     files[0]["metrics"].get("bytes", 0) >= 1073741824 and stability)
    capped = cap <= target
    status = "ПРЕДВАРИТЕЛЬНАЯ/НЕДОСТАТОЧНО ДАННЫХ" if (coverage < 80 or not mandatory or capped) else "ПОЛНАЯ"
    if partial is not None and not tcp1:
        partial = min(partial, 2)
    if partial is not None and tcp1 and (metric(tcp1, "receiver_mbps") or 0) < 0.01:
        partial = min(partial, 2)
    if partial is not None and udp and any((metric(item, "loss_pct") or 0) >= 5 for item in udp):
        partial = min(partial, 4)
    if partial is not None and data_file_required(results, direction) and not files:
        partial = min(partial, 6)
    return {"score": round(partial, 1) if partial is not None else None,
            "coverage_pct": coverage, "status": status, "components": components,
            "capped": capped}


def data_file_required(results, direction):
    return any(item["kind"] == "file" and item["direction"] == direction and
               item["params"].get("required", True) for item in results)


def build_score(data):
    scores = {direction: score_direction(data["stages"], direction,
                                          data["config"]["target_mbps"],
                                          data["config"]["cap_mbps"])
              for direction in ("A_TO_B", "B_TO_A")}
    numbers = [entry["score"] for entry in scores.values()]
    full = all(entry["status"] == "ПОЛНАЯ" for entry in scores.values())
    scores["overall"] = {"score": min(numbers) if all(x is not None for x in numbers) else None,
                         "method": "минимум двух направлений",
                         "status": "ПОЛНАЯ" if full else "ПРЕДВАРИТЕЛЬНАЯ/НЕДОСТАТОЧНО ДАННЫХ"}
    return scores


def fmt(value, digits=1):
    return "не измерено" if value is None else ("%.*f" % (digits, value))


def category(value):
    if value is None:
        return "нет данных"
    for threshold, label in ((9, "отлично"), (8, "очень хорошо"), (7, "хорошо"),
                             (5, "удовлетворительно"), (3, "плохо")):
        if value >= threshold:
            return label
    return "критично"


def bottleneck_flags(data):
    flags = []
    for stage in data["stages"]:
        cpu = metric(stage, "cpu_local")
        if cpu is not None and cpu >= 90:
            flags.append("Высокая локальная загрузка CPU во время %s %s" %
                         (stage["kind"], stage["direction"]))
    for direction in ("A_TO_B", "B_TO_A"):
        tcp = next((item for item in relevant(data["stages"], direction, "tcp")
                    if item["params"].get("streams") == 1), None)
        file_stage = next(iter(relevant(data["stages"], direction, "file")), None)
        if tcp and file_stage and metric(tcp, "receiver_mbps") and metric(file_stage, "avg_mbps"):
            if metric(file_stage, "avg_mbps") < 0.5 * metric(tcp, "receiver_mbps"):
                flags.append("Файл %s заметно медленнее TCP; возможен упор в диск/CPU" % direction)
    if abs(data.get("clock_difference_estimate_s") or 0) > 5:
        flags.append("Оценочная разница часов VPS превышает 5 секунд")
    return flags


def summary(data):
    stages = data["stages"]
    def find(direction, kind, **params):
        return next((item for item in stages if item["direction"] == direction and
                     item["kind"] == kind and all(item["params"].get(key) == value
                                                   for key, value in params.items())), {})
    lines = ["# RemnaSuper — диагностика соединения VPS", "",
             "Сессия: `%s`  Профиль: %s  Статус: %s" %
             (data["session_id"], data["config"]["profile"], data["status"]),
             "VPS A: %s  VPS B: %s" % (data.get("a_ip"), data.get("b_ip")), "",
             "| Метрика | A → B | B → A |", "|---|---:|---:|"]
    if data.get("cleanup_verified") is not None:
        lines.insert(4, "Проверка очистки: %s" %
                     ("успешна" if data["cleanup_verified"] else "НЕ ЗАВЕРШЕНА"))
    for streams in (1, 4, 8):
        values = [metric(find(direction, "tcp", streams=streams), "receiver_mbps")
                  for direction in ("A_TO_B", "B_TO_A")]
        lines.append("| TCP %d поток(ов), Mbps | %s | %s |" %
                     (streams, fmt(values[0]), fmt(values[1])))
    for label, kind, path, suffix in [
            ("Файл", "file", ("avg_mib_s",), "MiB/s"),
            ("UDP loss", "udp", ("loss_pct",), "%"),
            ("RTT p95", "baseline", ("rtt_ms", "p95"), "ms")]:
        values = [metric(find(direction, kind), *path) for direction in ("A_TO_B", "B_TO_A")]
        lines.append("| %s, %s | %s | %s |" % (label, suffix, fmt(values[0]), fmt(values[1])))
    hashes = [metric(find(direction, "file"), "checksum_ok") for direction in
              ("A_TO_B", "B_TO_A")]
    lines.append("| Файл SHA-256 | %s | %s |" %
                 tuple("OK" if value is True else "FAIL" if value is False else "не проверено"
                       for value in hashes))
    lines.extend(["", "## Оценка профиля VPN/VPS-мост", ""])
    for direction in ("A_TO_B", "B_TO_A", "overall"):
        entry = data["scores"][direction]
        lines.append("- %s: %s/10 (%s), %s%s" %
                     (direction, fmt(entry["score"]), category(entry["score"]), entry["status"],
                      " (покрытие %d%%)" % entry["coverage_pct"] if "coverage_pct" in entry else ""))
    lines.extend(["", "Цель TCP: %s Mbps; предел нагрузки: %s Mbps. Предел ниже или равен цели — скорость канала не установлена." %
                  (data["config"]["target_mbps"], data["config"]["cap_mbps"]),
                  "Оценка эвристическая. ICMP и TCP RTT не являются односторонней задержкой. "
                  "Общие счётчики ядра могут включать трафик других пользователей. "
                  "Прямой IP→IP тест не измеряет накладные расходы VLESS, WireGuard или Xray.", "",
                  "Вес оценки: TCP 25%, стабильность/retransmits 15%, UDP 20%, вариация RTT 10%, "
                  "RTT под нагрузкой 15%, echo 10%, PMTU 5%. "
                  "Для каждого показателя используется линейная интерполяция порогов из report.py. "
                  "Общий балл равен меньшему из двух направлений.", "",
                  "Практический смысл: скачивание и стриминг зависят прежде всего от TCP и файла; "
                  "интерактивность — от echo и RTT под нагрузкой; игры и UDP-туннели — от UDP-потерь. "
                  "Итог относится к профилю VPN/VPS-мост, а не к конкретному VPN-протоколу.", "",
                  "## Этапы с ошибками и пропусками", ""])
    for stage in stages:
        if stage["status"] != "FINISHED":
            lines.append("- %s %s: %s — %s" %
                         (stage["kind"], stage["direction"], stage["status"], stage.get("reason")))
    if data.get("bottleneck_flags"):
        lines.extend(["", "## Возможные ограничения измерения", ""])
        lines.extend("- " + item for item in data["bottleneck_flags"])
    if data.get("cleanup_errors"):
        lines.extend(["", "## Требуется ручная проверка cleanup", ""])
        lines.extend("- " + item for item in data["cleanup_errors"])
        lines.append("Журнал: `%s`. Сверьте `ufw status numbered` с полными атрибутами "
                     "и комментарием `rsdiag` в журнале. Не удаляйте похожие чужие правила. "
                     "После проверки выполните штатное восстановление через повторный запуск пункта 24." %
                     data.get("cleanup_journal", "неизвестно"))
    if data.get("remote_cleanup_errors"):
        lines.extend(["", "## Очистка на второй VPS не завершена", ""])
        lines.extend("- " + item for item in data["remote_cleanup_errors"])
    return "\n".join(lines) + "\n"


def write_reports(report_dir, data):
    report_dir = Path(report_dir)
    data["updated_utc"] = datetime.now(timezone.utc).isoformat()
    data["scores"] = build_score(data)
    data["bottleneck_flags"] = bottleneck_flags(data)
    result = report_dir / "result.json"
    temp = report_dir / "result.json.tmp"
    temp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    temp.replace(result)
    md_temp = report_dir / "summary.md.tmp"
    md_temp.write_text(summary(data), encoding="utf-8")
    md_temp.replace(report_dir / "summary.md")
