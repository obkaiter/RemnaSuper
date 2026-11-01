#!/usr/bin/env python3
"""Interactive two-VPS network diagnostics and autonomous recovery entry point."""

import getpass
import ipaddress
import json
import os
import re
import secrets
import shutil
import socket
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

from measure import (available_port, ping, preflight,
                     run_echo, run_iperf, send_file, send_udp, service, start_listener,
                     stop_listener)
from protocol import authenticate_client, authenticate_server
from report import write_reports
from safety import (REPORT_ROOT, Resources, acquire_lock, command,
                    recover, recover_stale, secure_dir, watch)

PROFILE_PRESETS = {
    "1": {"profile": "Быстрый", "file_bytes": 64 * 1024 ** 2,
          "tcp_seconds": 6, "stability_seconds": 20, "target_mbps": 100,
          "cap_mbps": 150, "session_seconds": 300, "baseline_probes": 30,
          "echo_count": 100, "udp_seconds": 2, "udp_pps": 200,
          "udp_bandwidth_seconds": 6, "udp_fractions": [0.05],
          "under_load_seconds": 10, "duplex_seconds": 10,
          "route_probe": False, "repeat_tcp": False,
          "tcp_streams": [1, 4, 8], "udp_sizes": [64, 128, 256, 512, 1200]},
    "2": {"profile": "Средний", "file_bytes": 1024 ** 3,
          "tcp_seconds": 15, "stability_seconds": 120, "target_mbps": 100,
          "cap_mbps": 150, "session_seconds": 900, "baseline_probes": 100,
          "echo_count": 500, "udp_seconds": 3, "udp_pps": 500,
          "udp_bandwidth_seconds": 6, "udp_fractions": [0.05, 0.25, 0.50],
          "under_load_seconds": 15, "duplex_seconds": 15,
          "route_probe": True, "repeat_tcp": False,
          "tcp_streams": [1, 4, 8], "udp_sizes": [64, 128, 256, 512, 1200]},
    "3": {"profile": "Полный", "file_bytes": 1024 ** 3,
          "tcp_seconds": 30, "stability_seconds": 420, "target_mbps": 100,
          "cap_mbps": 150, "session_seconds": 1800, "baseline_probes": 100,
          "echo_count": 1000, "udp_seconds": 5, "udp_pps": 1000,
          "udp_bandwidth_seconds": 10, "udp_fractions": [0.05, 0.25, 0.50],
          "under_load_seconds": 20, "duplex_seconds": 20,
          "route_probe": True, "repeat_tcp": True,
          "tcp_streams": [1, 4, 8], "udp_sizes": [64, 128, 256, 512, 1200]},
}
KINDS = {"iperf", "iperf_udp", "file", "echo", "udp"}
STAGE_RE = re.compile(r"^[a-f0-9]{6}$")


class PartialTransfer(RuntimeError):
    pass


class SessionStop:
    def __init__(self, session):
        self.session = session

    def reason(self):
        session = self.session
        if session.started is not None and time.monotonic() - session.started >= session.config["session_seconds"] - 20:
            return "Достигнут временной бюджет профиля"
        return "Потерян канал управления"

    def is_set(self):
        session = self.session
        return (session.stop.is_set() or
                (session.control is not None and session.control.stop.is_set()) or
                self.reason() == "Достигнут временной бюджет профиля")


def question(label, default):
    answer = input("%s [%s]: " % (label, default)).strip()
    return answer or str(default)


def peer_ip():
    show_local_ips()
    value = input("IP второй VPS: ").strip()
    address = ipaddress.ip_address(value)
    if address.is_loopback or address.is_multicast or address.is_unspecified:
        raise ValueError("Нужен маршрутизируемый адрес второй VPS")
    return str(address)


def show_local_ips():
    try:
        interfaces = json.loads(command(["ip", "-j", "address", "show"], check=True).stdout)
        addresses = []
        for interface in interfaces:
            for item in interface.get("addr_info", []):
                address = ipaddress.ip_address(item["local"])
                if not (address.is_loopback or address.is_link_local or
                        address.is_multicast or address.is_unspecified):
                    addresses.append("%s: %s" % (interface["ifname"], address))
        if addresses:
            print("IP этой VPS (локальные интерфейсы):")
            for address in addresses:
                print("  %s" % address)
            print("При NAT внешний IP может отличаться от адреса интерфейса.")
        else:
            print("IP интерфейсов не найден; проверьте сетевые настройки VPS.")
    except Exception as exc:
        print("Не удалось определить IP этой VPS: %s" % exc)


def settings():
    print("Профиль: 1 — быстрый (до 5 минут), 2 — средний (до 15 минут), "
          "3 — полный (до 30 минут)")
    choice = question("Выбор профиля", "2")
    if choice not in PROFILE_PRESETS:
        raise ValueError("Выберите профиль 1, 2 или 3")
    return dict(PROFILE_PRESETS[choice])


def planned_seconds(config):
    cap = config["cap_mbps"] * 1000000
    echo = sum(max(0.001, size * 16 / cap) * config["echo_count"]
               for size in (64, 256, 1024, 4096)) * 2
    return (2 * config["baseline_probes"] * 0.2 +
            2 * (3 + config["repeat_tcp"]) * config["tcp_seconds"] +
            2 * config["file_bytes"] * 8 / cap +
            (5 if config["profile"] == "Быстрый" else 30) + echo +
            2 * len(config["udp_sizes"]) * config["udp_seconds"] +
            2 * len(config["udp_fractions"]) * config["udp_bandwidth_seconds"] +
             (130 if config["route_probe"] else 0) +
            2 * config["under_load_seconds"] +
            2 * config["stability_seconds"] + config["duplex_seconds"] +
            (60 if config["profile"] == "Быстрый" else
             70 if config["profile"] == "Средний" else 90))


def confirm_load(config):
    file_gib = 2 * config["file_bytes"] / 1024 ** 3
    tcp_seconds = (2 * (3 + config["repeat_tcp"]) * config["tcp_seconds"] +
                   2 * config["stability_seconds"] +
                   2 * config["under_load_seconds"] + config["duplex_seconds"])
    udp_seconds = 2 * len(config["udp_fractions"]) * config["udp_bandwidth_seconds"]
    estimate = (tcp_seconds + udp_seconds) * config["cap_mbps"] * 1000000 / 8 / 1024 ** 3
    print("\nПрофиль: %s, до %d минут; файл: %.2f GiB в каждую сторону." %
          (config["profile"], config["session_seconds"] // 60,
           config["file_bytes"] / 1024 ** 3))
    print("Только файловый этап: минимум %.2f GiB трафика; дополнительно TCP/UDP." % file_gib)
    print("Ориентир дополнительного полезного трафика при пределе %d Mbps: около %.1f GiB; "
          "тарифицируемый объём с заголовками и повторами может быть больше." %
          (config["cap_mbps"], estimate))
    if planned_seconds(config) > config["session_seconds"] - 20:
        raise ValueError("Заданный профиль не укладывается в свой временной бюджет")
    print("Плановая нагрузка с резервом: около %.1f мин. "
          "На медленном канале время может истечь до полного файла." %
          (planned_seconds(config) / 60))
    print("Нагрузка может замедлить VPN-пользователей и расходовать платный трафик VPS.")
    print("Ctrl+C прерывает сессию и запускает очистку.")
    if input("Подтверждаю нагрузку и стоимость трафика (введите ДА): ").strip() != "ДА":
        raise RuntimeError("Сессия отменена пользователем")


def local_address(peer):
    family = socket.AF_INET6 if ":" in peer else socket.AF_INET
    with socket.socket(family, socket.SOCK_DGRAM) as sock:
        sock.connect((peer, 9))
        return sock.getsockname()[0]


def report_directory(sid):
    if REPORT_ROOT.parent.is_symlink():
        raise RuntimeError("Каталог отчётов не должен быть символической ссылкой")
    REPORT_ROOT.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if REPORT_ROOT.parent.stat().st_uid != 0:
        raise RuntimeError("Каталог отчётов не принадлежит root")
    secure_dir(REPORT_ROOT)
    name = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ-") + sid
    path = REPORT_ROOT / name
    path.mkdir(mode=0o700)
    return path


def make_report(sid, role, peer, config, preflight_data):
    own = local_address(peer)
    return {"schema_version": 1, "session_id": sid, "role": role,
            "a_ip": own if role == "A" else peer,
            "b_ip": peer if role == "A" else own,
            "config": config, "local_preflight": preflight_data,
            "remote_preflight": None, "stages": [], "status": "ЧАСТИЧНО",
            "cleanup_errors": [], "limitations": [
                "Управляющие сообщения аутентифицированы HMAC-SHA256, но метаданные не шифруются.",
                "Адресный UFW не управляет cloud firewall, nftables или правилами Docker.",
                "Скорость при включённом пределе нагрузки не является пределом канала."]}


def stage_record(kind, direction, params, status, metrics=None, reason=None, stage_id=None):
    return {"id": stage_id or secrets.token_hex(6), "planned": True,
            "executed": status != "SKIPPED", "kind": kind, "direction": direction,
            "params": params, "status": status, "reason": reason,
            "duration": (metrics or {}).get("duration"), "metrics": metrics or {},
            "limitations": []}


class Session:
    def __init__(self, role, sid, peer, secret, config, preflight_data, port):
        self.role, self.sid, self.peer = role, sid, peer
        self.secret, self.config, self.port = secret, config, port
        self.resources = Resources(sid, peer, Path(__file__))
        self.report_dir = report_directory(sid)
        self.report = make_report(sid, role, peer, config, preflight_data)
        self.control = None
        self.stop = threading.Event()
        self.test_stop = SessionStop(self)
        self.active_listener = None
        self.started = None
        self.heartbeat_thread = None
        self.used_stages = set()

    def next_stage(self):
        while True:
            stage = secrets.token_hex(3)
            if stage not in self.used_stages:
                self.used_stages.add(stage)
                return stage

    def prepare(self):
        self.resources.create(self.config["session_seconds"] + 300)
        self.resources.data["report_dir"] = str(self.report_dir)
        self.resources.save()
        secret_path = self.resources.path.parent / "tmp" / "secret"
        fd = os.open(secret_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as output:
            output.write(self.secret)
        self.resources.install_recovery()
        self.resources.start_watchdog()
        self.heartbeat_thread = threading.Thread(target=self._heartbeat, daemon=True)
        self.heartbeat_thread.start()
        write_reports(self.report_dir, self.report)

    def _heartbeat(self):
        while not self.stop.wait(3):
            try:
                self.resources.heartbeat()
            except OSError:
                self.stop.set()

    def ensure_alive(self):
        if self.stop.is_set() or (self.control and self.control.stop.is_set()):
            raise ConnectionError("Сессия прервана или потерян канал управления")

    def ensure_budget(self):
        self.ensure_alive()
        if self.test_stop.reason() == "Достигнут временной бюджет профиля":
            raise TimeoutError("Достигнут временной бюджет профиля")

    def send(self, kind, payload=None):
        self.ensure_alive()
        self.control.send(kind, payload)

    def expect(self, kind, timeout=30):
        self.ensure_alive()
        message = self.control.receive(timeout)
        if message["type"] != kind:
            raise ValueError("Ожидалось %s, получено %s" % (kind, message["type"]))
        return message["payload"]

    def record(self, stage):
        self.report["stages"].append(stage)
        write_reports(self.report_dir, self.report)
        value = stage["metrics"]
        print("%s %s: %s%s" % (stage["kind"], stage["direction"], stage["status"],
                               " — %.1f Mbps" % value["receiver_mbps"]
                               if value.get("receiver_mbps") is not None else ""))

    def connect_a(self):
        self.resources.open_port(self.port, "tcp", "ctrl")
        family = socket.AF_INET6 if ":" in self.peer else socket.AF_INET
        bind = "::" if family == socket.AF_INET6 else "0.0.0.0"
        with socket.socket(family, socket.SOCK_STREAM) as server:
            server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            if family == socket.AF_INET6:
                server.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            server.bind((bind, self.port))
            server.listen(1)
            server.settimeout(300)
            print("Ожидание VPS B на %s:%d (не более 5 минут)..." % (bind, self.port))
            conn, address = server.accept()
        if address[0] != self.peer:
            conn.close()
            raise RuntimeError("Источник подключения %s не равен ожидаемому %s. Проверьте NAT/IP." %
                               (address[0], self.peer))
        conn.settimeout(10)
        self.control = authenticate_server(conn, self.sid, self.secret)

    def connect_b(self):
        conn = socket.create_connection((self.peer, self.port), timeout=15)
        conn.settimeout(10)
        self.control = authenticate_client(conn, self.sid, self.secret)

    def client(self, kind, stage, port, params):
        self.ensure_alive()
        if kind in ("iperf", "iperf_udp"):
            path = self.report_dir / ("iperf3-%s.json" % stage)
            result = run_iperf(self.resources, self.peer, port, params["streams"],
                               params["seconds"], params.get("rate_mbps", self.config["cap_mbps"]),
                               path, self.test_stop, kind == "iperf_udp")
            if params.get("under_load"):
                result["load_rtt_ms"] = self._load_ping_result.get("rtt_ms")
            return result
        if kind == "file":
            return send_file(self.resources, self.peer, port, stage,
                             self.config["file_bytes"], self.config["cap_mbps"],
                             self.test_stop)
        if kind == "echo":
            return run_echo(self.resources, self.peer, port, stage,
                            params["size"], params["count"],
                            self.config["cap_mbps"], self.test_stop)
        if kind == "udp":
            return send_udp(self.resources, self.peer, port, stage,
                            params["size"], params["pps"], params["seconds"],
                            self.test_stop)
        raise ValueError("Неизвестный вид измерения")

    def _client_with_load(self, kind, stage, port, params):
        self._load_ping_result = {}
        thread = None
        if params.get("under_load"):
            thread = threading.Thread(target=lambda: setattr(self, "_load_ping_result",
                              ping(self.peer, params["seconds"], interval=1)), daemon=True)
            thread.start()
        result = self.client(kind, stage, port, params)
        if thread:
            thread.join(timeout=2)
            result["load_rtt_ms"] = self._load_ping_result.get("rtt_ms")
        return result

    def paired(self, kind, direction, params):
        self.ensure_budget()
        stage = self.next_stage()
        port = available_port(self.peer, "udp" if kind == "udp" else "tcp")
        listener_size = self.config["file_bytes"] if kind == "file" else 0
        local_listener = None
        sender, receiver = None, None
        reason = None
        status = "FAILED"
        abort_after_record = False
        try:
            if direction == "A_TO_B":
                for attempt in range(5):
                    self.send("START_TEST", {"op": "prepare", "kind": kind,
                                              "stage": stage, "port": port,
                                              "size": listener_size})
                    response = self.expect("READY")
                    if response.get("status") == "READY":
                        break
                    if attempt == 4:
                        raise RuntimeError(response.get("reason", "Слушатель не готов"))
                    port = available_port(self.peer, "udp" if kind == "udp" else "tcp")
                try:
                    sender = self._client_with_load(kind, stage, port, params)
                finally:
                    if kind == "udp":
                        time.sleep(0.5)
                    self.send("STOP_TEST", {"stage": stage})
                    receiver = self.expect("RESULT", 15)
            else:
                local_listener = start_listener(self.resources, kind, stage, port, listener_size)
                try:
                    self.send("START_TEST", {"op": "send", "kind": kind,
                                              "stage": stage, "port": port,
                                              "params": params})
                    expected_timeout = (params.get("seconds", 0) +
                                        self.config["file_bytes"] * 8 /
                                        (self.config["cap_mbps"] * 1000000) + 90)
                    remaining = (self.config["session_seconds"] -
                                 (time.monotonic() - self.started) - 20)
                    sender = self.expect("RESULT", max(1, remaining if kind == "file" else
                                                      min(expected_timeout, remaining)))
                finally:
                    receiver = stop_listener(self.resources, local_listener, kind, stage, port)
                    local_listener = None
            if isinstance(sender, dict) and sender.get("status") == "FAILED":
                raise RuntimeError(sender.get("reason", "Ошибка отправителя"))
            if isinstance(sender, dict) and sender.get("status") == "PARTIAL":
                raise PartialTransfer(sender.get("reason", "Неполная передача"))
            if isinstance(sender, dict) and sender.get("status") == "FINISHED":
                sender = sender.get("metrics", {})
            if kind == "file":
                recv_metrics = receiver.get("metrics", {})
                if receiver.get("status") != "FINISHED" or sender["bytes"] != self.config["file_bytes"]:
                    raise RuntimeError("Файловая передача не завершилась полностью")
                sender["received_bytes"] = recv_metrics.get("bytes")
                sender["receiver_duration"] = recv_metrics.get("duration")
                sender["max_gap_s"] = recv_metrics.get("max_gap_s")
                sender["checksum_ok"] = (sender["bytes"] == recv_metrics.get("bytes") and
                                         sender["sha256"] == recv_metrics.get("sha256"))
                if not sender["checksum_ok"]:
                    raise RuntimeError("Размер или SHA-256 файла не совпал")
            elif kind == "udp":
                recv_metrics = receiver.get("metrics", {})
                if receiver.get("status") != "FINISHED":
                    raise RuntimeError(receiver.get("reason", "Нет результата UDP"))
                sender["send_duration"] = sender["duration"]
                sender.update(recv_metrics)
                sender["lost"] = max(0, sender["sent"] - sender["received"])
                sender["loss_pct"] = max(0, 100 * (sender["sent"] -
                                             sender["received"]) / sender["sent"])
                sender["pps_received"] = sender["received"] / max(sender["duration"], 0.001)
            status = "FINISHED"
        except PartialTransfer as exc:
            reason = str(exc)
            status = "PARTIAL"
            sender = sender.get("metrics", {}) if isinstance(sender, dict) else {}
            if receiver and isinstance(receiver, dict):
                sender["received_bytes"] = receiver.get("metrics", {}).get("bytes")
        except (OSError, ValueError, RuntimeError, TimeoutError, KeyError, TypeError) as exc:
            reason = str(exc)
            status = "TIMEOUT" if isinstance(exc, TimeoutError) else "FAILED"
            abort_after_record = isinstance(exc, TimeoutError) and direction == "B_TO_A"
            if isinstance(exc, (OSError, TimeoutError)):
                reason += "; проверьте маршрут, NAT и cloud firewall обеих VPS"
            if self.control.stop.is_set():
                raise
        finally:
            if local_listener is not None:
                stop_listener(self.resources, local_listener, kind, stage, port)
        metrics = sender if isinstance(sender, dict) else {}
        report_kind = ("under_load" if params.get("under_load") else
                       "stability" if params.get("stability") else
                       "udp_bandwidth" if kind == "iperf_udp" else
                       "tcp" if kind == "iperf" else kind)
        self.record(stage_record(report_kind, direction,
                                 params, status, metrics, reason, stage))
        if abort_after_record or self.test_stop.reason() == "Достигнут временной бюджет профиля":
            raise TimeoutError(reason or "Достигнут временной бюджет профиля")

    def probe(self, direction):
        self.ensure_budget()
        if direction == "A_TO_B":
            result = ping(self.peer, self.config["baseline_probes"])
        else:
            self.send("START_TEST", {"op": "probe", "kind": "ping"})
            result = self.expect("RESULT", self.config["baseline_probes"] + 30).get("metrics", {})
        status = "FINISHED" if result.get("received", 0) else "UNAVAILABLE"
        self.record(stage_record("baseline", direction, {}, status, result,
                                 result.get("reason") if status != "FINISHED" else None))

    def route_probe(self, direction):
        self.ensure_budget()
        if direction == "A_TO_B":
            result = route_data(self.peer)
        else:
            self.send("START_TEST", {"op": "probe", "kind": "route"})
            result = self.expect("RESULT", 45).get("metrics", {})
        status = "FINISHED" if result.get("pmtu") else "SKIPPED"
        self.record(stage_record("pmtu", direction, {}, status, result,
                                 "PMTU не определён" if status != "FINISHED" else None))

    def duplex(self):
        self.ensure_budget()
        if self.config["cap_mbps"] < 2:
            self.record(stage_record("duplex", "BOTH", {}, "SKIPPED",
                                     reason="Предел нагрузки ниже 2 Mbps"))
            return
        stage = self.next_stage()
        b_port = available_port(self.peer)
        a_port = available_port(self.peer)
        local_listener = None
        remote_prepared = False
        remote_stopped = False
        metrics = {}
        reason = None
        status = "FAILED"
        params = {"streams": 1, "seconds": self.config["duplex_seconds"],
                  "rate_mbps": self.config["cap_mbps"] // 2}
        try:
            self.send("START_TEST", {"op": "prepare", "kind": "iperf",
                                      "stage": stage, "port": b_port, "size": 0})
            response = self.expect("READY")
            if response.get("status") != "READY":
                raise RuntimeError(response.get("reason", "VPS B не готова"))
            remote_prepared = True
            local_listener = start_listener(self.resources, "iperf", stage, a_port)
            try:
                self.send("START_TEST", {"op": "duplex_send", "kind": "iperf",
                                          "stage": stage, "port": a_port, "params": params})
                a_to_b = self._client_with_load("iperf", stage, b_port, params)
                b_to_a = self.expect("RESULT", 50)
                if b_to_a.get("status") != "FINISHED":
                    raise RuntimeError(b_to_a.get("reason", "VPS B не завершила двусторонний тест"))
                metrics = {"a_to_b_mbps": a_to_b["receiver_mbps"],
                           "b_to_a_mbps": b_to_a["metrics"]["receiver_mbps"]}
                metrics["aggregate_mbps"] = metrics["a_to_b_mbps"] + metrics["b_to_a_mbps"]
                for direction, key in (("A_TO_B", "a_to_b_mbps"),
                                       ("B_TO_A", "b_to_a_mbps")):
                    baseline = next((item["metrics"].get("receiver_mbps") for item in
                                     self.report["stages"] if item["kind"] == "tcp" and
                                     item["direction"] == direction and item["status"] == "FINISHED" and
                                     item["params"].get("streams") == 1), None)
                    metrics["ratio_to_single_" + key] = (metrics[key] / baseline
                                                         if baseline else None)
                status = "FINISHED"
            finally:
                stop_listener(self.resources, local_listener, "iperf", stage, a_port)
                local_listener = None
                self.send("STOP_TEST", {"stage": stage})
                remote_stopped = True
                self.expect("RESULT", 15)
        except (RuntimeError, OSError, ValueError, TimeoutError) as exc:
            reason = str(exc)
            if self.control.stop.is_set():
                raise
        finally:
            if local_listener:
                stop_listener(self.resources, local_listener, "iperf", stage, a_port)
            if remote_prepared and not remote_stopped and not self.control.stop.is_set():
                try:
                    self.send("STOP_TEST", {"stage": stage})
                    self.expect("RESULT", 15)
                except Exception:
                    pass
        self.record(stage_record("duplex", "BOTH", params, status, metrics, reason, stage))

    def coordinate(self):
        self.send("HELLO", {"config": self.config, "preflight": shareable_preflight(self.report["local_preflight"]),
                            "a_ip": self.report["a_ip"], "utc": time.time()})
        response = self.expect("READY", 300)
        if response.get("status") != "READY":
            raise RuntimeError(response.get("reason", "Вторая VPS не готова"))
        self.report["remote_preflight"] = response.get("preflight")
        if isinstance(response.get("utc"), (int, float)):
            self.report["clock_difference_estimate_s"] = response["utc"] - time.time()
        self.started = time.monotonic()
        self.resources.data["expires"] = time.time() + self.config["session_seconds"] + 60
        self.resources.save()
        write_reports(self.report_dir, self.report)
        for direction in ("A_TO_B", "B_TO_A"):
            self.probe(direction)
        for direction in ("A_TO_B", "B_TO_A"):
            original = next((item for item in self.report["stages"] if
                             item["kind"] == "baseline" and item["direction"] == direction), None)
            if original and original["status"] == "UNAVAILABLE":
                self.paired("echo", direction, {"size": 64,
                                                 "count": self.config["echo_count"]})
                echo_stage = self.report["stages"][-1]
                if echo_stage["kind"] == "echo" and echo_stage["status"] == "FINISHED":
                    metrics = {"rtt_ms": echo_stage["metrics"]["rtt_ms"],
                               "sent": self.config["echo_count"],
                               "received": echo_stage["metrics"]["received"],
                               "method": "TCP echo RTT; ICMP заблокирован"}
                    self.record(stage_record("baseline", direction, {"fallback": "TCP echo"},
                                             "FINISHED", metrics))
        for direction in ("A_TO_B", "B_TO_A"):
            for streams in self.config["tcp_streams"]:
                self.paired("iperf", direction,
                            {"streams": streams, "seconds": self.config["tcp_seconds"]})
            if self.config["repeat_tcp"]:
                self.paired("iperf", direction, {"streams": 1,
                                                  "seconds": self.config["tcp_seconds"],
                                                  "repeat": 2})
        for direction in ("A_TO_B", "B_TO_A"):
            self.paired("file", direction, {})
        for direction in ("A_TO_B", "B_TO_A"):
            for size in (64, 256, 1024, 4096):
                self.paired("echo", direction, {"size": size,
                                                 "count": self.config["echo_count"]})
        for direction in ("A_TO_B", "B_TO_A"):
            for size in self.config["udp_sizes"]:
                pps = min(self.config["udp_pps"],
                          max(1, self.config["cap_mbps"] * 1000000 // (size * 8)))
                self.paired("udp", direction, {"size": size, "pps": pps,
                                                "seconds": self.config["udp_seconds"]})
                last = self.report["stages"][-1]
                if last["status"] == "FINISHED" and last["metrics"].get("loss_pct", 0) >= 5:
                    for remaining in self.config["udp_sizes"][self.config["udp_sizes"].index(size) + 1:]:
                        self.record(stage_record("udp", direction, {"size": remaining}, "SKIPPED",
                                                 reason="UDP-потери достигли 5%; нагрузка остановлена"))
                    break
        for direction in ("A_TO_B", "B_TO_A"):
            candidate = next((item["metrics"].get("receiver_mbps") for item in self.report["stages"]
                              if item["kind"] == "tcp" and item["direction"] == direction and
                              item["params"].get("streams") == 1 and item["status"] == "FINISHED"), None)
            if candidate is None:
                self.record(stage_record("udp_bandwidth", direction, {}, "SKIPPED",
                                         reason="Нет ориентира TCP-скорости"))
                continue
            for index, fraction in enumerate(self.config["udp_fractions"]):
                rate = max(1, min(self.config["cap_mbps"], int(candidate * fraction)))
                self.paired("iperf_udp", direction, {"streams": 1,
                                                      "seconds": self.config["udp_bandwidth_seconds"],
                                                      "rate_mbps": rate})
                last = self.report["stages"][-1]
                if last["status"] == "FINISHED" and (
                        (last["metrics"].get("loss_pct") or 0) >= 3 or
                        (last["metrics"].get("cpu_local") or 0) >= 90):
                    for remaining in self.config["udp_fractions"][index + 1:]:
                        self.record(stage_record("udp_bandwidth", direction,
                                                 {"fraction": remaining}, "SKIPPED",
                                                 reason="Потери UDP или CPU превысили безопасный порог"))
                    break
        for direction in ("A_TO_B", "B_TO_A"):
            if self.config["route_probe"]:
                self.route_probe(direction)
            else:
                self.record(stage_record("pmtu", direction, {}, "SKIPPED",
                                         reason="Быстрый профиль"))
            self.paired("iperf", direction, {"streams": 1,
                                              "seconds": self.config["under_load_seconds"],
                                              "under_load": True})
        if self.config["stability_seconds"]:
            for direction in ("A_TO_B", "B_TO_A"):
                self.paired("iperf", direction, {"streams": 1,
                                                  "seconds": self.config["stability_seconds"],
                                                  "stability": True})
        else:
            for direction in ("A_TO_B", "B_TO_A"):
                self.record(stage_record("stability", direction, {}, "SKIPPED", reason="Быстрый профиль"))
        self.duplex()
        self.report["status"] = "ЗАВЕРШЕНО" if self.config["file_bytes"] >= 1024 ** 3 and all(
            item["status"] == "FINISHED" for item in self.report["stages"] if
            item["kind"] != "pmtu") else "ЧАСТИЧНО"
        write_reports(self.report_dir, self.report)
        self.send("DONE", {"report": {"session_id": self.sid,
                                      "stages": self.report["stages"],
                                      "status": self.report["status"]}})
        cleanup_ack = self.expect("RESULT", 60)
        if cleanup_ack.get("op") != "cleanup" or not isinstance(cleanup_ack.get("errors"), list):
            raise ValueError("Нет подтверждения очистки VPS B")
        self.report["remote_cleanup_errors"] = cleanup_ack["errors"]
        if cleanup_ack["errors"]:
            self.report["status"] = "CLEANUP_INCOMPLETE"
        write_reports(self.report_dir, self.report)

    def worker(self):
        hello = self.expect("HELLO", 30)
        config = hello.get("config")
        if not valid_config(config):
            raise ValueError("Некорректные параметры координатора")
        self.config = config
        self.report["config"] = config
        self.report["remote_preflight"] = hello.get("preflight")
        if isinstance(hello.get("utc"), (int, float)):
            self.report["clock_difference_estimate_s"] = hello["utc"] - time.time()
        if shutil.disk_usage(self.resources.path.parent).free < config["file_bytes"] + 512 * 1024 ** 2:
            raise RuntimeError("На VPS B недостаточно места для файлового этапа")
        confirm_load(config)
        write_reports(self.report_dir, self.report)
        self.send("READY", {"status": "READY", "preflight":
                            shareable_preflight(self.report["local_preflight"]),
                            "utc": time.time()})
        self.started = time.monotonic()
        self.resources.data["expires"] = time.time() + config["session_seconds"] + 60
        self.resources.save()
        while True:
            self.ensure_alive()
            try:
                message = self.control.receive(30)
            except TimeoutError:
                continue
            kind, payload = message["type"], message["payload"]
            if kind == "DONE":
                remote = payload.get("report")
                if not isinstance(remote, dict) or remote.get("session_id") != self.sid:
                    raise ValueError("Некорректный итоговый отчёт")
                self.report["stages"] = remote["stages"]
                self.report["status"] = remote["status"]
                write_reports(self.report_dir, self.report)
                self.stop.set()
                if self.heartbeat_thread:
                    self.heartbeat_thread.join(timeout=4)
                errors = self.resources.cleanup()
                self.report["cleanup_errors"] = errors
                self.report["cleanup_verified"] = not errors
                if errors:
                    self.report["status"] = "CLEANUP_INCOMPLETE"
                    self.report["cleanup_journal"] = str(self.resources.path)
                write_reports(self.report_dir, self.report)
                self.control.send("RESULT", {"op": "cleanup", "errors": errors})
                return
            if kind == "START_TEST":
                op = payload.get("op")
                if op == "probe":
                    if payload.get("kind") == "ping":
                        result = ping(self.peer, self.config["baseline_probes"])
                    elif payload.get("kind") == "route":
                        result = route_data(self.peer)
                    else:
                        raise ValueError("Неизвестная проба")
                    self.send("RESULT", {"status": "FINISHED", "metrics": result})
                    probe_kind = "baseline" if payload["kind"] == "ping" else "pmtu"
                    self.record(stage_record(probe_kind, "B_TO_A", {},
                                             "FINISHED" if (result.get("received") or result.get("pmtu"))
                                             else "UNAVAILABLE", result))
                    continue
                validate_stage(payload, self.config)
                stage = payload["stage"]
                if op == "prepare":
                    if self.active_listener:
                        raise ValueError("Уже есть активный слушатель")
                    try:
                        entry = start_listener(self.resources, payload["kind"], stage,
                                               payload["port"], payload["size"])
                        self.active_listener = (entry, payload["kind"], stage, payload["port"])
                        self.send("READY", {"status": "READY", "stage": stage})
                    except Exception as exc:
                        self.send("READY", {"status": "FAILED", "reason": str(exc), "stage": stage})
                elif op in ("send", "duplex_send"):
                    if op == "duplex_send" and (not self.active_listener or
                                                self.active_listener[2] != stage or
                                                self.active_listener[1] != "iperf" or
                                                payload["kind"] != "iperf"):
                        raise ValueError("Двусторонний этап не подготовлен")
                    try:
                        metrics = self._client_with_load(payload["kind"], stage,
                                                         payload["port"], payload["params"])
                        self.send("RESULT", metrics if metrics.get("status") in
                                  ("FAILED", "PARTIAL") else
                                  {"status": "FINISHED", "metrics": metrics})
                        local_status = "PARTIAL" if metrics.get("status") in (None, "PARTIAL") else "FAILED"
                        local_metrics = metrics.get("metrics", {}) if metrics.get("status") else metrics
                        self.record(stage_record(payload["kind"],
                                                 "BOTH" if op == "duplex_send" else "B_TO_A",
                                                 payload["params"], local_status, local_metrics,
                                                 "Ожидается итоговая сверка координатора", stage))
                    except Exception as exc:
                        self.send("RESULT", {"status": "FAILED", "reason": str(exc), "metrics": {}})
                        self.record(stage_record(payload["kind"], "B_TO_A", payload["params"],
                                                 "FAILED", reason=str(exc), stage_id=stage))
                else:
                    raise ValueError("Неизвестная операция")
            elif kind == "STOP_TEST":
                if not self.active_listener or payload.get("stage") != self.active_listener[2]:
                    raise ValueError("STOP_TEST не соответствует активному этапу")
                entry, service_kind, stage, port = self.active_listener
                result = stop_listener(self.resources, entry, service_kind, stage, port)
                self.active_listener = None
                self.send("RESULT", result)
                self.record(stage_record(service_kind, "A_TO_B", {},
                                         "PARTIAL" if result.get("status") in ("FINISHED", "PARTIAL") else "FAILED",
                                         result.get("metrics", {}),
                                         "Ожидается итоговая сверка координатора", stage))
            else:
                raise ValueError("Недопустимая команда в состоянии worker")

    def finish(self):
        self.stop.set()
        if self.control:
            self.control.close()
        if self.resources.path.exists():
            try:
                errors = self.resources.cleanup()
            except Exception as exc:
                errors = [str(exc)]
            self.report["cleanup_errors"] = errors
            self.report["cleanup_verified"] = not errors
            if errors:
                self.report["status"] = "CLEANUP_INCOMPLETE"
                self.report["cleanup_journal"] = str(self.resources.path)
                print("Очистка не завершена: %s" % "; ".join(errors))
                print("Журнал для ручной проверки: %s" % self.resources.path)
        write_reports(self.report_dir, self.report)
        print("Итоговый статус: %s" % self.report["status"])
        for direction, label in (("A_TO_B", "A→B"), ("B_TO_A", "B→A"), ("overall", "Общий")):
            entry = self.report["scores"][direction]
            value = "не рассчитан" if entry["score"] is None else "%.1f/10" % entry["score"]
            print("%s: %s — %s" % (label, value, entry["status"]))
        print("Отчёты: %s и %s" % (self.report_dir / "summary.md",
                                   self.report_dir / "result.json"))


def valid_config(value):
    return isinstance(value, dict) and any(value == preset for preset in PROFILE_PRESETS.values())


def validate_stage(value, config):
    if value.get("op") not in ("prepare", "send", "duplex_send") or value.get("kind") not in KINDS:
        raise ValueError("Недопустимый этап")
    expected = ({"op", "kind", "stage", "port", "size"} if value["op"] == "prepare"
                else {"op", "kind", "stage", "port", "params"})
    if set(value) != expected:
        raise ValueError("Лишние или отсутствующие поля этапа")
    if not isinstance(value.get("stage"), str) or not STAGE_RE.fullmatch(value["stage"]):
        raise ValueError("Недопустимый ID этапа")
    if not isinstance(value.get("port"), int) or not 55000 <= value["port"] <= 55999:
        raise ValueError("Недопустимый порт")
    if value["op"] == "prepare":
        if value.get("size") != (config["file_bytes"] if value["kind"] == "file" else 0):
            raise ValueError("Недопустимый размер принимаемых данных")
    else:
        params = value.get("params")
        if not isinstance(params, dict):
            raise ValueError("Нет параметров этапа")
        kind = value["kind"]
        if kind == "file" and params:
            raise ValueError("Файловый этап не принимает дополнительные параметры")
        if kind == "iperf" and not set(params) in (
                {"streams", "seconds"}, {"streams", "seconds", "under_load"},
                {"streams", "seconds", "stability"},
                {"streams", "seconds", "rate_mbps"},
                {"streams", "seconds", "repeat"}):
            raise ValueError("Неверная схема TCP-этапа")
        if kind == "iperf_udp" and set(params) != {"streams", "seconds", "rate_mbps"}:
            raise ValueError("Неверная схема UDP iperf3")
        if kind == "echo" and set(params) != {"size", "count"}:
            raise ValueError("Неверная схема echo")
        if kind == "udp" and set(params) != {"size", "pps", "seconds"}:
            raise ValueError("Неверная схема UDP")
        if kind in ("iperf", "iperf_udp") and (params.get("streams") not in (1, 4, 8) or
                                 not isinstance(params.get("seconds"), int) or
                                 not 5 <= params["seconds"] <= 600):
            raise ValueError("Недопустимые параметры iperf3")
        if kind == "iperf" and (params.get("under_load") not in (None, True) or
                                 params.get("stability") not in (None, True) or
                                 params.get("repeat") not in (None, 2)):
            raise ValueError("Недопустимый тип TCP-прогона")
        if kind == "iperf" and "rate_mbps" in params and (
                not isinstance(params["rate_mbps"], int) or
                not 1 <= params["rate_mbps"] <= config["cap_mbps"]):
            raise ValueError("Недопустимый предел TCP-этапа")
        if kind == "iperf_udp" and (
                not isinstance(params.get("rate_mbps"), int) or
                not 1 <= params["rate_mbps"] <= config["cap_mbps"]):
            raise ValueError("Недопустимая скорость UDP")
        if kind == "echo" and (params.get("size") not in (64, 256, 1024, 4096) or
                                params.get("count") != config["echo_count"]):
            raise ValueError("Недопустимые параметры echo")
        if kind == "udp" and (params.get("size") not in (64, 128, 256, 512, 1200) or
                               not isinstance(params.get("pps"), int) or
                               not 1 <= params["pps"] <= config["udp_pps"] or
                               params["pps"] * params["size"] * 8 > config["cap_mbps"] * 1000000 or
                               params.get("seconds") != config["udp_seconds"]):
            raise ValueError("Недопустимые параметры UDP")


def route_data(peer):
    result = {"route": command(["ip", "-6" if ":" in peer else "-4",
                                "route", "get", peer], check=True).stdout.strip(),
              "pmtu": None, "tracepath": None}
    if shutil.which("tracepath"):
        try:
            output = command(["tracepath", "-n", "-m", "16", peer], timeout=20).stdout[:4000]
            result["tracepath"] = output
            match = re.search(r"pmtu\s+(\d+)", output)
            if match:
                result["pmtu"] = int(match[1])
        except Exception as exc:
            result["reason"] = str(exc)
    if shutil.which("mtr"):
        try:
            result["mtr"] = command(["mtr", "-r", "-n", "-c", "3", "-m", "16", peer],
                                     timeout=30).stdout[:4000]
        except Exception as exc:
            result["mtr_reason"] = str(exc)
    if ":" not in peer:
        result["df_ping"] = {}
        for payload_size in (1200, 1400, 1472):
            try:
                probe = command(["ping", "-4", "-n", "-M", "do", "-s",
                                 str(payload_size), "-c", "1", "-W", "1", peer], timeout=4)
                result["df_ping"][str(payload_size)] = probe.returncode == 0
            except Exception:
                result["df_ping"][str(payload_size)] = None
    return result


def shareable_preflight(value):
    return {name: value.get(name) for name in
            ("kernel", "vcpu", "memory_kib", "free_bytes", "tools")}


def run():
    if os.geteuid() != 0:
        raise RuntimeError("Диагностику нужно запускать от root")
    os.umask(0o077)
    lock = acquire_lock(nonblocking=True)
    session = None
    success = False
    try:
        problems = recover_stale()
        if problems:
            raise RuntimeError("Незавершённая прежняя сессия: %s" % "; ".join(problems))
        print("RemnaSuper — парная диагностика двух VPS")
        peer = peer_ip()
        role = question("Роль: 1 — создать (A), 2 — присоединиться (B)", "1")
        if role not in ("1", "2"):
            raise ValueError("Неверная роль")
        try:
            port = int(os.environ.get("REMNASUPER_DIAG_PORT", "55443"))
        except ValueError as exc:
            raise ValueError("REMNASUPER_DIAG_PORT должен быть числом") from exc
        if not 1024 <= port <= 65535:
            raise ValueError("REMNASUPER_DIAG_PORT должен быть в диапазоне 1024–65535")
        print("TCP-порт управления на VPS A: %d" % port)
        if role == "1":
            config = settings()
            confirm_load(config)
            pre = preflight(peer, config["file_bytes"], port)
            family = socket.AF_INET6 if ":" in peer else socket.AF_INET
            with socket.socket(family, socket.SOCK_STREAM) as probe:
                probe.bind(("::" if family == socket.AF_INET6 else "0.0.0.0", port))
            sid, secret = secrets.token_hex(6), secrets.token_bytes(32)
            session = Session("A", sid, peer, secret, config, pre, port)
            session.prepare()
            print("\nID сессии: %s" % sid)
            print("Одноразовый секрет для ввода на VPS B: %s" % secret.hex())
            print("Секрет не будет записан в отчёт. Передайте его по доверенному каналу.")
            session.connect_a()
            session.coordinate()
        else:
            sid = input("ID сессии (12 шестнадцатеричных символов): ").strip().lower()
            if not re.fullmatch(r"[a-f0-9]{12}", sid):
                raise ValueError("Неверный ID сессии")
            secret_hex = getpass.getpass("Одноразовый секрет (без эха): ").strip()
            if not re.fullmatch(r"[a-fA-F0-9]{64}", secret_hex):
                raise ValueError("Неверный формат секрета")
            secret = bytes.fromhex(secret_hex)
            # The incoming profile is authenticated before any listener is opened.
            pre = preflight(peer, 1048576, port)
            config = dict(PROFILE_PRESETS["1"])
            config["session_seconds"] = 900  # Time to pair before the authenticated profile arrives.
            session = Session("B", sid, peer, secret, config, pre, port)
            session.prepare()
            session.connect_b()
            session.worker()
        print("Диагностика завершена: %s" % session.report["status"])
        success = session.report["status"] == "ЗАВЕРШЕНО"
    except KeyboardInterrupt:
        print("\nДиагностика прервана пользователем")
        if session and session.control and not session.control.stop.is_set():
            try:
                session.control.send("ABORT", {"reason": "Отмена пользователем"})
            except OSError:
                pass
        if session:
            session.report["status"] = "ПРЕРВАНО"
    except Exception as exc:
        print("Ошибка диагностики: %s" % exc)
        if session and session.control and not session.control.stop.is_set():
            try:
                session.control.send("ABORT", {"reason": str(exc)[:200]})
            except OSError:
                pass
        if session:
            session.report["status"] = "С ОШИБКАМИ"
    finally:
        if session:
            session.finish()
            if session.report["cleanup_errors"]:
                success = False
        os.close(lock)
    return 0 if success else 1


def main():
    if len(sys.argv) < 2:
        raise ValueError("Нужна команда run, service, recover или watch")
    mode = sys.argv[1]
    if mode == "run" and len(sys.argv) == 2:
        sys.exit(run())
    elif mode == "service" and len(sys.argv) == 7:
        path, kind, stage, port, size = sys.argv[2:]
        if kind not in ("file", "echo", "udp") or not STAGE_RE.fullmatch(stage):
            raise ValueError("Недопустимый сервис")
        service(path, kind, stage, int(port), int(size))
    elif mode == "recover" and len(sys.argv) == 3:
        problems = recover(sys.argv[2])
        if problems:
            print("CLEANUP_INCOMPLETE: %s" % "; ".join(problems), file=sys.stderr)
            sys.exit(1)
    elif mode == "watch" and len(sys.argv) == 3:
        watch(sys.argv[2])
    else:
        raise ValueError("Недопустимые аргументы")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print("Агент: %s" % exc, file=sys.stderr)
        sys.exit(1)
