#!/usr/bin/env python3
"""Persistent rule and BPF-map controller for the RemnaSuper shaper."""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import struct
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Iterable


MAX_PORTS = 32
MAX_RULES = 32
RULE_FORMAT = f"<II{MAX_PORTS}I6Q"
RULE_SIZE = struct.calcsize(RULE_FORMAT)
STATE_SIZE = 72
DEFAULT_PIN_DIR = Path("/sys/fs/bpf/remnasuper-traffic-shaper/maps")
DEFAULT_RULES_FILE = Path("/etc/remnasuper/traffic-shaper/rules.json")

MODE_NAMES = {
    1: "на каждый IP",
    2: "burst и штраф на каждый IP",
    3: "общий канал",
}


class ShaperError(RuntimeError):
    pass


def run(command: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            command,
            check=check,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
    except FileNotFoundError as exc:
        raise ShaperError(f"Команда не найдена: {command[0]}") from exc
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or "неизвестная ошибка").strip()
        raise ShaperError(f"Команда завершилась с ошибкой: {' '.join(command)}\n{detail}") from exc


def parse_number(value: Any) -> int:
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        try:
            return int(value, 0)
        except ValueError:
            return int(value, 16)
    if isinstance(value, dict):
        for key in ("value", "data"):
            if key in value:
                return parse_number(value[key])
    raise ValueError(f"Нельзя преобразовать в число: {value!r}")


def byte_list(value: Any) -> bytes:
    if isinstance(value, list):
        return bytes(parse_number(item) & 0xFF for item in value)
    if isinstance(value, str):
        parts = value.replace(",", " ").split()
        return bytes(int(item, 16) for item in parts)
    raise ValueError(f"Нельзя преобразовать в байты: {value!r}")


def u32_bytes(value: int) -> bytes:
    return struct.pack("<I", value)


def words_to_bytes(words: Any, count: int) -> bytes:
    if isinstance(words, list):
        if len(words) == count * 4:
            return byte_list(words)
        if len(words) == count:
            return struct.pack(f"<{count}I", *(parse_number(item) for item in words))
    raise ValueError(f"Ожидался массив из {count} u32")


def map_key_bytes(map_name: str, value: Any) -> bytes:
    if isinstance(value, dict) and "formatted" in value:
        value = value["formatted"]

    if map_name == "port_rules":
        if isinstance(value, dict):
            value = next(iter(value.values()))
        return u32_bytes(parse_number(value))

    if map_name == "whitelist":
        if isinstance(value, dict):
            value = value.get("address", value.get("addr"))
        return words_to_bytes(value, 4)

    if map_name in ("download_states", "upload_states"):
        if isinstance(value, dict):
            address = value.get("address", value.get("addr"))
            rule_id = parse_number(value.get("rule_id", 0))
            padding = parse_number(value.get("padding", value.get("_pad", 0)))
            return words_to_bytes(address, 4) + struct.pack("<II", rule_id, padding)
        return byte_list(value)

    return byte_list(value)


def value_bytes(value: Any) -> bytes:
    if isinstance(value, dict) and "formatted" in value:
        value = value["formatted"]
    return byte_list(value)


class BpfMaps:
    def __init__(self, pin_dir: Path):
        self.pin_dir = pin_dir

    def path(self, name: str) -> Path:
        return self.pin_dir / name

    def require(self, name: str) -> Path:
        path = self.path(name)
        if not path.exists():
            raise ShaperError(
                f"BPF-карта не найдена: {path}. Запустите или перезапустите сервис шейпера."
            )
        return path

    def dump(self, name: str) -> list[dict[str, Any]]:
        path = self.path(name)
        if not path.exists():
            return []
        result = run(["bpftool", "-j", "map", "dump", "pinned", str(path)])
        if not result.stdout.strip():
            return []
        try:
            data = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise ShaperError(f"bpftool вернул некорректный JSON для {name}") from exc
        return data if isinstance(data, list) else []

    def update(self, name: str, key: bytes, value: bytes) -> None:
        path = self.require(name)
        run(
            ["bpftool", "map", "update", "pinned", str(path), "key", "hex"]
            + [f"{item:02x}" for item in key]
            + ["value", "hex"]
            + [f"{item:02x}" for item in value]
        )

    def delete(self, name: str, key: bytes) -> None:
        path = self.path(name)
        if not path.exists():
            return
        run(
            ["bpftool", "map", "delete", "pinned", str(path), "key", "hex"]
            + [f"{item:02x}" for item in key],
            check=False,
        )

    def clear_hash(self, name: str) -> None:
        for entry in self.dump(name):
            try:
                key = map_key_bytes(name, entry.get("key"))
            except (TypeError, ValueError):
                continue
            self.delete(name, key)


def empty_config() -> dict[str, Any]:
    return {"version": 1, "rules": {}}


def load_config(path: Path) -> dict[str, Any]:
    if not path.exists():
        return empty_config()
    try:
        with path.open("r", encoding="utf-8") as stream:
            data = json.load(stream)
    except (OSError, json.JSONDecodeError) as exc:
        raise ShaperError(f"Не удалось прочитать {path}: {exc}") from exc
    if not isinstance(data, dict) or not isinstance(data.get("rules"), dict):
        raise ShaperError(f"Некорректный формат файла правил: {path}")
    return data


def save_config(path: Path, config: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix="rules.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(config, stream, ensure_ascii=False, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def parse_ports(text: str) -> list[int]:
    try:
        ports = [int(item.strip()) for item in text.split(",") if item.strip()]
    except ValueError as exc:
        raise ShaperError("Порты должны быть целыми числами через запятую.") from exc
    ports = list(dict.fromkeys(ports))
    if not ports:
        raise ShaperError("Не указан ни один порт.")
    if len(ports) > MAX_PORTS:
        raise ShaperError(f"В одном правиле можно указать не более {MAX_PORTS} портов.")
    if any(port < 0 or port > 65535 for port in ports):
        raise ShaperError("Допустимы порты от 1 до 65535 или одиночное значение 0.")
    if 0 in ports and len(ports) != 1:
        raise ShaperError("Порт 0 (все порты) нельзя объединять с другими портами.")
    return ports


def mbps_to_bytes_per_second(rate: float) -> int:
    return int(rate * 1_000_000 / 8)


def pack_rule(rule: dict[str, Any]) -> bytes:
    ports = [int(port) for port in rule["ports"]]
    padded_ports = ports + [0] * (MAX_PORTS - len(ports))
    payload = struct.pack(
        RULE_FORMAT,
        int(rule["mode"]),
        len(ports),
        *padded_ports,
        mbps_to_bytes_per_second(float(rule["download_mbps"])),
        mbps_to_bytes_per_second(float(rule["upload_mbps"])),
        mbps_to_bytes_per_second(float(rule.get("penalty_mbps", 0))),
        int(float(rule.get("burst_mib", 0)) * 1024 * 1024),
        int(float(rule.get("window_seconds", 0)) * 1_000_000_000),
        int(float(rule.get("penalty_seconds", 0)) * 1_000_000_000),
    )
    if len(payload) != RULE_SIZE:
        raise ShaperError("Внутренняя ошибка сериализации правила.")
    return payload


def validate_rule(rule: dict[str, Any]) -> None:
    rule_id = int(rule["id"])
    mode = int(rule["mode"])
    if rule_id < 0 or rule_id >= MAX_RULES:
        raise ShaperError(f"ID правила должен быть от 0 до {MAX_RULES - 1}.")
    if mode not in MODE_NAMES:
        raise ShaperError("Режим должен быть 1, 2 или 3.")
    parse_ports(",".join(str(port) for port in rule["ports"]))
    for field, label in (("download_mbps", "Download"), ("upload_mbps", "Upload")):
        if float(rule[field]) <= 0:
            raise ShaperError(f"Скорость {label} должна быть больше нуля.")
    if mode == 2:
        if float(rule.get("penalty_mbps", -1)) < 0:
            raise ShaperError("Штрафная скорость не может быть отрицательной.")
        if float(rule.get("burst_mib", 0)) <= 0:
            raise ShaperError("Burst-квота должна быть больше нуля.")
        if float(rule.get("window_seconds", 0)) <= 0:
            raise ShaperError("Окно burst должно быть больше нуля.")
        if float(rule.get("penalty_seconds", 0)) <= 0:
            raise ShaperError("Длительность штрафа должна быть больше нуля.")


def make_rule(args: argparse.Namespace) -> dict[str, Any]:
    rule = {
        "id": args.rule_id,
        "mode": args.mode,
        "ports": parse_ports(args.ports),
        "download_mbps": args.download_mbps,
        "upload_mbps": args.upload_mbps,
        "penalty_mbps": args.penalty_mbps if args.mode == 2 else 0,
        "burst_mib": args.burst_mib if args.mode == 2 else 0,
        "window_seconds": args.window_seconds if args.mode == 2 else 0,
        "penalty_seconds": args.penalty_seconds if args.mode == 2 else 0,
    }
    validate_rule(rule)
    return rule


def find_conflicts(rules: dict[str, Any], candidate: dict[str, Any]) -> list[tuple[int, int]]:
    conflicts: list[tuple[int, int]] = []
    candidate_id = int(candidate["id"])
    candidate_ports = set(candidate["ports"])
    for rule_id, rule in rules.items():
        if int(rule_id) == candidate_id:
            continue
        for port in candidate_ports.intersection(int(item) for item in rule["ports"]):
            conflicts.append((port, int(rule_id)))
    return sorted(conflicts)


def clear_rule_states(maps: BpfMaps, rule_id: int) -> None:
    for map_name in ("download_states", "upload_states"):
        for entry in maps.dump(map_name):
            try:
                key = map_key_bytes(map_name, entry.get("key"))
            except (TypeError, ValueError):
                continue
            if len(key) >= 20 and struct.unpack_from("<I", key, 16)[0] == rule_id:
                maps.delete(map_name, key)


def apply_rule(maps: BpfMaps, rule: dict[str, Any], old_rule: dict[str, Any] | None) -> None:
    if old_rule:
        for port in old_rule["ports"]:
            maps.delete("port_rules", u32_bytes(int(port)))
    maps.update("rules", u32_bytes(int(rule["id"])), pack_rule(rule))
    for port in rule["ports"]:
        maps.update("port_rules", u32_bytes(int(port)), u32_bytes(int(rule["id"])))
    clear_rule_states(maps, int(rule["id"]))


def command_set(args: argparse.Namespace) -> None:
    config = load_config(args.rules_file)
    rule = make_rule(args)
    conflicts = find_conflicts(config["rules"], rule)
    if conflicts:
        details = ", ".join(f"порт {port} → правило #{rule_id}" for port, rule_id in conflicts)
        raise ShaperError(f"Порты уже заняты: {details}")
    maps = BpfMaps(args.pin_dir)
    old_rule = config["rules"].get(str(rule["id"]))
    apply_rule(maps, rule, old_rule)
    config["rules"][str(rule["id"])] = rule
    save_config(args.rules_file, config)
    print(f"[ok] Правило #{rule['id']} сохранено и применено.")


def command_delete(args: argparse.Namespace) -> None:
    config = load_config(args.rules_file)
    old_rule = config["rules"].get(str(args.rule_id))
    if not old_rule:
        raise ShaperError(f"Правило #{args.rule_id} не найдено.")
    maps = BpfMaps(args.pin_dir)
    if maps.path("rules").exists():
        for port in old_rule["ports"]:
            maps.delete("port_rules", u32_bytes(int(port)))
        maps.update("rules", u32_bytes(args.rule_id), bytes(RULE_SIZE))
        clear_rule_states(maps, args.rule_id)
    del config["rules"][str(args.rule_id)]
    save_config(args.rules_file, config)
    print(f"[ok] Правило #{args.rule_id} удалено.")


def restore_all(maps: BpfMaps, config: dict[str, Any]) -> None:
    maps.require("rules")
    maps.clear_hash("port_rules")
    maps.clear_hash("download_states")
    maps.clear_hash("upload_states")
    for rule_id in range(MAX_RULES):
        maps.update("rules", u32_bytes(rule_id), bytes(RULE_SIZE))
    seen_ports: dict[int, int] = {}
    for rule_id, rule in sorted(config["rules"].items(), key=lambda item: int(item[0])):
        validate_rule(rule)
        if int(rule_id) != int(rule["id"]):
            raise ShaperError(
                f"Ключ правила #{rule_id} не совпадает с полем id={rule['id']} в rules.json."
            )
        for port in rule["ports"]:
            port = int(port)
            if port in seen_ports:
                raise ShaperError(
                    f"Порт {port} указан в правилах #{seen_ports[port]} и #{rule_id}."
                )
            seen_ports[port] = int(rule_id)
        apply_rule(maps, rule, None)


def command_restore(args: argparse.Namespace) -> None:
    config = load_config(args.rules_file)
    restore_all(BpfMaps(args.pin_dir), config)
    print(f"[ok] Восстановлено правил: {len(config['rules'])}.")


def display_ports(ports: Iterable[int]) -> str:
    values = list(ports)
    return "все TCP/UDP" if values == [0] else ", ".join(str(port) for port in values)


def command_list(args: argparse.Namespace) -> None:
    config = load_config(args.rules_file)
    if not config["rules"]:
        print("Настроенных правил нет.")
        return
    for rule_id, rule in sorted(config["rules"].items(), key=lambda item: int(item[0])):
        print(
            f"#{rule_id}: {MODE_NAMES.get(int(rule['mode']), 'неизвестно')}; "
            f"порты: {display_ports(rule['ports'])}; "
            f"DL/UL: {rule['download_mbps']:g}/{rule['upload_mbps']:g} Мбит/с"
        )
        if int(rule["mode"]) == 2:
            print(
                f"    burst: {rule['burst_mib']:g} МиБ/{rule['window_seconds']:g} с; "
                f"штраф: {rule['penalty_mbps']:g} Мбит/с на "
                f"{rule['penalty_seconds']:g} с"
            )


def ip_key(ip: ipaddress.IPv4Address | ipaddress.IPv6Address) -> bytes:
    if ip.version == 4:
        return ip.packed + bytes(12)
    return ip.packed


def load_whitelist(files: list[Path]) -> list[ipaddress.IPv4Address | ipaddress.IPv6Address]:
    addresses: list[ipaddress.IPv4Address | ipaddress.IPv6Address] = []
    seen: set[str] = set()
    for path in files:
        if not path.exists():
            continue
        for number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
            value = raw_line.split("#", 1)[0].strip()
            if not value:
                continue
            try:
                address = ipaddress.ip_address(value)
            except ValueError as exc:
                raise ShaperError(f"Некорректный IP в {path}:{number}: {value}") from exc
            if str(address) not in seen:
                addresses.append(address)
                seen.add(str(address))
    return addresses


def command_whitelist_sync(args: argparse.Namespace) -> None:
    maps = BpfMaps(args.pin_dir)
    maps.require("whitelist")
    addresses = load_whitelist(args.files)
    maps.clear_hash("whitelist")
    for address in addresses:
        maps.update("whitelist", ip_key(address), b"\x01")
    print(f"[ok] В whitelist загружено адресов: {len(addresses)}.")


def state_key(value: Any) -> tuple[str, int]:
    raw = map_key_bytes("download_states", value)
    if len(raw) < 24:
        raise ValueError("Короткий ключ состояния")
    address = raw[:16]
    rule_id = struct.unpack_from("<I", raw, 16)[0]
    if not any(address):
        return "общий пул", rule_id
    if not any(address[4:]):
        return str(ipaddress.IPv4Address(address[:4])), rule_id
    return str(ipaddress.IPv6Address(address)), rule_id


def state_value(value: Any) -> dict[str, int]:
    if isinstance(value, dict) and "formatted" in value:
        value = value["formatted"]
    if isinstance(value, dict):
        return {
            "bytes": parse_number(value.get("total_bytes", 0)),
            "packets": parse_number(value.get("total_packets", 0)),
            "drops": parse_number(value.get("dropped_packets", 0)),
            "penalized": parse_number(value.get("penalized", 0)),
        }
    raw = value_bytes(value)
    if len(raw) < STATE_SIZE:
        raise ValueError("Короткое значение состояния")
    return {
        "bytes": struct.unpack_from("<Q", raw, 40)[0],
        "packets": struct.unpack_from("<Q", raw, 48)[0],
        "drops": struct.unpack_from("<Q", raw, 56)[0],
        "penalized": struct.unpack_from("<I", raw, 64)[0],
    }


def human_bytes(value: int) -> str:
    amount = float(value)
    for unit in ("Б", "КиБ", "МиБ", "ГиБ", "ТиБ"):
        if amount < 1024 or unit == "ТиБ":
            return f"{amount:.1f} {unit}"
        amount /= 1024
    return f"{amount:.1f} ТиБ"


def command_stats(args: argparse.Namespace) -> None:
    maps = BpfMaps(args.pin_dir)
    totals: dict[tuple[str, int], dict[str, int]] = {}
    for direction, map_name in (("dl", "download_states"), ("ul", "upload_states")):
        for entry in maps.dump(map_name):
            try:
                key = state_key(entry.get("key"))
                parsed = state_value(entry.get("value"))
            except (TypeError, ValueError):
                continue
            row = totals.setdefault(
                key,
                {"dl": 0, "ul": 0, "packets": 0, "drops": 0, "penalized": 0},
            )
            row[direction] += parsed["bytes"]
            row["packets"] += parsed["packets"]
            row["drops"] += parsed["drops"]
            row["penalized"] = max(row["penalized"], parsed["penalized"])

    if not totals:
        print("Статистика пока пуста.")
        return

    rows = sorted(totals.items(), key=lambda item: item[1]["dl"] + item[1]["ul"], reverse=True)
    if not args.full:
        rows = rows[:20]
    print(f"{'Правило':>7}  {'IP/пул':<39} {'Download':>11} {'Upload':>11} {'Drops':>9}  Статус")
    for (address, rule_id), row in rows:
        status = "штраф" if row["penalized"] else "норма"
        print(
            f"#{rule_id:<6}  {address:<39} {human_bytes(row['dl']):>11} "
            f"{human_bytes(row['ul']):>11} {row['drops']:>9}  {status}"
        )


def command_init(args: argparse.Namespace) -> None:
    if not args.rules_file.exists():
        save_config(args.rules_file, empty_config())
    print(f"[ok] Файл правил готов: {args.rules_file}")


def command_self_test(_: argparse.Namespace) -> None:
    assert RULE_SIZE == 184
    assert parse_ports("443, 8443,443") == [443, 8443]
    assert ip_key(ipaddress.ip_address("1.2.3.4"))[:4] == b"\x01\x02\x03\x04"
    sample = {
        "id": 0,
        "mode": 1,
        "ports": [443],
        "download_mbps": 80.0,
        "upload_mbps": 40.0,
    }
    assert len(pack_rule(sample)) == RULE_SIZE
    print("[ok] Внутренние проверки controller.py пройдены.")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Управление eBPF-шейпером RemnaSuper")
    parser.add_argument("--pin-dir", type=Path, default=DEFAULT_PIN_DIR)
    parser.add_argument("--rules-file", type=Path, default=DEFAULT_RULES_FILE)
    commands = parser.add_subparsers(dest="command", required=True)

    commands.add_parser("init").set_defaults(handler=command_init)
    commands.add_parser("list").set_defaults(handler=command_list)
    commands.add_parser("restore").set_defaults(handler=command_restore)
    commands.add_parser("self-test").set_defaults(handler=command_self_test)

    set_parser = commands.add_parser("set")
    set_parser.add_argument("--rule-id", type=int, required=True)
    set_parser.add_argument("--mode", type=int, choices=MODE_NAMES, required=True)
    set_parser.add_argument("--ports", required=True)
    set_parser.add_argument("--download-mbps", type=float, required=True)
    set_parser.add_argument("--upload-mbps", type=float, required=True)
    set_parser.add_argument("--penalty-mbps", type=float, default=0.0)
    set_parser.add_argument("--burst-mib", type=float, default=0.0)
    set_parser.add_argument("--window-seconds", type=float, default=0.0)
    set_parser.add_argument("--penalty-seconds", type=float, default=0.0)
    set_parser.set_defaults(handler=command_set)

    delete_parser = commands.add_parser("delete")
    delete_parser.add_argument("--rule-id", type=int, required=True)
    delete_parser.set_defaults(handler=command_delete)

    whitelist_parser = commands.add_parser("whitelist-sync")
    whitelist_parser.add_argument("--file", dest="files", type=Path, action="append", required=True)
    whitelist_parser.set_defaults(handler=command_whitelist_sync)

    stats_parser = commands.add_parser("stats")
    stats_parser.add_argument("--full", action="store_true")
    stats_parser.set_defaults(handler=command_stats)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        args.handler(args)
    except ShaperError as exc:
        print(f"[x] {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
