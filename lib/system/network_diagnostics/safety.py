"""Owned temporary resources for a single RemnaSuper diagnostic session."""

import fcntl
import ipaddress
import json
import os
import re
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path("/var/lib/remnasuper/network-diagnostics/sessions")
REPORT_ROOT = Path("/var/log/remnasuper/network-diagnostics")
LOCK_PATH = Path("/run/lock/remnasuper-network-diagnostics.lock")
UNIT_DIR = Path("/etc/systemd/system")
SID_RE = re.compile(r"^[a-f0-9]{12}$")
RULE_RE = re.compile(
    r"^\[\s*(\d+)\]\s+(\d+)/(tcp|udp)(?: \(v6\))?\s+ALLOW IN\s+(.+?)(?:\s+#\s*(\S+))?\s*$"
)


def command(args, timeout=10, check=False):
    env = dict(os.environ, LC_ALL="C", LANG="C")
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=timeout, env=env)
    if check and result.returncode:
        raise RuntimeError("%s: %s" % (args[0], (result.stderr or result.stdout).strip()[:300]))
    return result


def secure_dir(path):
    path = Path(path)
    if path.is_symlink():
        raise RuntimeError("Символическая ссылка в служебном пути: %s" % path)
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.stat().st_uid != 0:
        raise RuntimeError("Служебный каталог не принадлежит root: %s" % path)
    path.chmod(0o700)
    return path


def atomic_json(path, value):
    path = Path(path)
    tmp = path.with_name(path.name + ".tmp.%s" % secrets.token_hex(8))
    fd = os.open(tmp, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if tmp.exists():
            tmp.unlink()


def validate_journal_path(path):
    path = Path(path).absolute()
    if path.name != "journal.json" or not SID_RE.fullmatch(path.parent.name):
        raise RuntimeError("Некорректный путь журнала")
    if path.parent.parent != ROOT or path.is_symlink() or path.parent.is_symlink():
        raise RuntimeError("Журнал вне служебного каталога")
    return path


def process_start(pid):
    try:
        stat = Path("/proc/%d/stat" % pid).read_text()
        return stat.rsplit(") ", 1)[1].split()[19]
    except (OSError, IndexError):
        return None


def owned_process(entry):
    pid = entry["pid"]
    try:
        stat = Path("/proc/%d/stat" % pid).read_text().rsplit(") ", 1)[1].split()
        return stat[0] != "Z" and stat[19] == entry["start"]
    except (OSError, IndexError):
        return False


def stop_process(entry):
    if not owned_process(entry):
        try:
            os.waitpid(entry["pid"], os.WNOHANG)
        except (ChildProcessError, ProcessLookupError):
            pass
        return
    pid = entry["pid"]
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline and owned_process(entry):
        time.sleep(0.1)
    if owned_process(entry):
        os.kill(pid, signal.SIGKILL)
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline and owned_process(entry):
            time.sleep(0.1)
        if owned_process(entry):
            raise RuntimeError("Собственный процесс %d не остановился" % pid)
    try:
        os.waitpid(pid, os.WNOHANG)
    except (ChildProcessError, ProcessLookupError):
        pass


def ufw_lines():
    output = command(["ufw", "status", "numbered"], check=True).stdout
    return [(int(match[1]), int(match[2]), match[3], normalize_source(match[4]), match[5])
            for line in output.splitlines()
            if (match := RULE_RE.match(line.strip()))]


def normalize_source(value):
    value = value.strip()
    if value.endswith(" (v6)"):
        value = value[:-5]
    try:
        return str(ipaddress.ip_address(value))
    except ValueError:
        return value


def check_firewall(peer=None):
    if not shutil.which("ufw"):
        raise RuntimeError("UFW отсутствует; сетевые тесты заблокированы")
    status = command(["ufw", "status", "verbose"], check=True).stdout
    if not re.search(r"^Status: active\s*$", status, re.M):
        raise RuntimeError("UFW неактивен; слушающие порты не будут открыты")
    if not re.search(r"^Default: deny \(incoming\)", status, re.M):
        raise RuntimeError("Для диагностики нужна входящая политика UFW deny")
    if peer and ":" in peer:
        config = Path("/etc/default/ufw").read_text(encoding="utf-8")
        if not re.search(r"^IPV6=yes\s*$", config, re.M):
            raise RuntimeError("UFW не фильтрует IPv6 (IPV6=yes отсутствует); IPv6-слушатель не будет открыт")
    return status


class Resources:
    def __init__(self, sid, peer, agent_path, journal=None):
        if not SID_RE.fullmatch(sid):
            raise RuntimeError("Некорректный идентификатор сессии")
        self.sid = sid
        self.peer = peer
        self.agent_path = Path(agent_path).resolve()
        self.path = validate_journal_path(journal or ROOT / sid / "journal.json")
        self.data = None

    def create(self):
        secure_dir(ROOT.parent)
        secure_dir(ROOT)
        secure_dir(self.path.parent)
        secure_dir(self.path.parent / "tmp")
        self.data = {"version": 1, "sid": self.sid, "peer": self.peer,
                     "created": time.time(),
                     "owner": {"pid": os.getpid(), "start": process_start(os.getpid())},
                     "rules": [], "processes": [], "state": "active"}
        self.save()
        self.heartbeat()

    def load(self):
        self.data = json.loads(self.path.read_text(encoding="utf-8"))
        if self.data.get("sid") != self.sid or self.data.get("peer") != self.peer:
            raise RuntimeError("Журнал сессии повреждён")
        return self.data

    def save(self):
        atomic_json(self.path, self.data)

    def heartbeat(self):
        heartbeat = self.path.parent / "heartbeat"
        fd = os.open(heartbeat, os.O_CREAT | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        os.close(fd)
        os.utime(heartbeat, None)

    def install_recovery(self):
        if not shutil.which("systemctl"):
            raise RuntimeError("Для гарантированного восстановления нужен systemd")
        unit = UNIT_DIR / ("remnasuper-diag-%s.service" % self.sid)
        if unit.exists() or unit.is_symlink():
            raise RuntimeError("Recovery unit уже существует")
        content = ("[Unit]\nDescription=RemnaSuper diagnostic watchdog %s\n"
                   "After=local-fs.target ufw.service\n"
                   "[Service]\nType=simple\nRestart=on-failure\nRestartSec=5\n"
                   "ExecStart=%s %s watch %s\n"
                   "[Install]\nWantedBy=multi-user.target\n" %
                   (self.sid, sys.executable, self.agent_path, self.path))
        fd = os.open(unit, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        self.data["unit"] = str(unit)
        self.save()
        try:
            command(["systemctl", "daemon-reload"], check=True)
            command(["systemctl", "enable", "--now", unit.name], check=True)
            enabled = command(["systemctl", "is-enabled", unit.name])
            if enabled.returncode or enabled.stdout.strip() != "enabled":
                raise RuntimeError("Не удалось проверить boot recovery")
            active = command(["systemctl", "is-active", unit.name])
            if active.returncode or active.stdout.strip() != "active":
                raise RuntimeError("Watchdog не запущен")
            self.data["recovery_ready"] = True
            self.save()
        except Exception:
            self.remove_recovery()
            raise

    def start_watchdog(self):
        unit = "remnasuper-diag-%s.service" % self.sid
        active = command(["systemctl", "is-active", unit])
        if active.returncode or active.stdout.strip() != "active":
            raise RuntimeError("Watchdog не запущен")

    def add_process(self, process):
        entry = {"pid": process.pid, "start": process_start(process.pid)}
        if not entry["start"]:
            raise RuntimeError("Не удалось зарегистрировать процесс")
        self.data["processes"].append(entry)
        self.save()
        return entry

    def release_process(self, entry):
        stop_process(entry)
        self.data["processes"] = [p for p in self.data["processes"] if p != entry]
        self.save()

    def open_port(self, port, proto, stage):
        check_firewall(self.peer)
        comment = "rsdiag:%s:%s" % (self.sid, stage)
        raw = command(["ufw", "status", "numbered"], check=True).stdout
        for line in raw.splitlines():
            if ("%d/%s" % (port, proto)) in line and line.lstrip().startswith("[") and not RULE_RE.match(line.strip()):
                raise RuntimeError("Есть нестандартное правило UFW на порту %d/%s; безопасная проверка невозможна" %
                                   (port, proto))
        matches = [line for line in ufw_lines() if line[1:3] == (port, proto)]
        for _, _, _, source, _ in matches:
            if source != self.peer:
                raise RuntimeError("Порт %d/%s имеет другое или широкое правило UFW" % (port, proto))
        if any(line[3] == self.peer for line in matches):
            self.data["rules"].append({"port": port, "proto": proto, "peer": self.peer,
                                       "comment": comment, "preexisting": True})
            self.save()
            return
        entry = {"port": port, "proto": proto, "peer": self.peer,
                 "comment": comment, "preexisting": False, "state": "intent"}
        self.data["rules"].append(entry)
        self.save()
        command(["ufw", "allow", "proto", proto, "from", self.peer, "to", "any",
                 "port", str(port), "comment", comment], check=True)
        if not any(line[1:] == (port, proto, self.peer, comment) for line in ufw_lines()):
            raise RuntimeError("UFW не подтвердил адресное правило %s" % comment)
        entry["state"] = "added"
        self.save()

    def close_port(self, port, proto):
        errors = []
        for entry in list(self.data["rules"]):
            if (entry["port"], entry["proto"]) != (port, proto):
                continue
            if not entry["preexisting"]:
                matches = [line for line in ufw_lines()
                           if line[1:] == (port, proto, entry["peer"], entry["comment"])]
                if len(matches) > 1:
                    errors.append("Неоднозначное правило %s" % entry["comment"])
                    continue
                if matches:
                    # Immediately re-read numbered status; never delete by a stale number.
                    fresh = [line for line in ufw_lines() if line == matches[0]]
                    if len(fresh) != 1:
                        errors.append("Правило изменилось: %s" % entry["comment"])
                        continue
                    command(["ufw", "--force", "delete", str(fresh[0][0])], check=True)
                    if any(line[1:] == (port, proto, entry["peer"], entry["comment"])
                           for line in ufw_lines()):
                        errors.append("Правило осталось: %s" % entry["comment"])
                        continue
            self.data["rules"].remove(entry)
            self.save()
        if errors:
            raise RuntimeError("; ".join(errors))

    def remove_recovery(self):
        unit = UNIT_DIR / ("remnasuper-diag-%s.service" % self.sid)
        if unit.exists() and not unit.is_symlink():
            command(["systemctl", "disable", unit.name], check=True)
            unit.unlink()
            command(["systemctl", "daemon-reload"])
            if unit.exists():
                raise RuntimeError("Recovery unit не удалён")

    def cleanup(self):
        self.load()
        errors = []
        for entry in list(self.data["processes"]):
            try:
                stop_process(entry)
                self.data["processes"].remove(entry)
                self.save()
            except Exception as exc:
                errors.append(str(exc))
        for entry in list(self.data["rules"]):
            try:
                self.close_port(entry["port"], entry["proto"])
            except Exception as exc:
                errors.append(str(exc))
        if not errors:
            try:
                tmp = self.path.parent / "tmp"
                if tmp.is_symlink() or tmp.parent != self.path.parent:
                    raise RuntimeError("Небезопасный временный путь")
                shutil.rmtree(tmp)
                if tmp.exists():
                    raise RuntimeError("Временные файлы не удалены")
                self.remove_recovery()
            except Exception as exc:
                errors.append(str(exc))
        self.data["state"] = "cleanup_incomplete" if errors else "done"
        self.data["cleanup_errors"] = errors
        self.save()
        if not errors:
            for leftover in self.path.parent.glob("journal.json.tmp.*"):
                if leftover.is_symlink() or not leftover.is_file():
                    raise RuntimeError("Неожиданный объект журнала: %s" % leftover)
                leftover.unlink()
            for name in ("heartbeat", "journal.json"):
                (self.path.parent / name).unlink(missing_ok=True)
            self.path.parent.rmdir()
        return errors


def acquire_lock(nonblocking=False):
    LOCK_PATH.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(LOCK_PATH, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    mode = fcntl.LOCK_EX | (fcntl.LOCK_NB if nonblocking else 0)
    fcntl.flock(fd, mode)
    return fd


def recover(path, locked=False):
    path = validate_journal_path(path)
    lock = None if locked else acquire_lock()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        resources = Resources(data["sid"], data["peer"], __file__, path)
        problems = resources.cleanup()
        report_dir = data.get("report_dir")
        if isinstance(report_dir, str):
            try:
                report_path = Path(report_dir)
                if report_path.parent == REPORT_ROOT and not report_path.is_symlink():
                    result_path = report_path / "result.json"
                    if result_path.exists():
                        from report import write_reports
                        result = json.loads(result_path.read_text(encoding="utf-8"))
                        result["status"] = "CLEANUP_INCOMPLETE" if problems else "ПРЕРВАНО"
                        result["cleanup_errors"] = problems
                        result["cleanup_verified"] = not problems
                        if problems:
                            result["cleanup_journal"] = str(path)
                        write_reports(report_path, result)
            except Exception as exc:
                problems.append("Не удалось обновить аварийный отчёт: %s" % exc)
        return problems
    finally:
        if lock is not None:
            os.close(lock)


def recover_stale():
    if not ROOT.exists():
        return []
    problems = []
    for path in ROOT.glob("*/journal.json"):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            if data.get("state") != "done":
                heartbeat = path.parent / "heartbeat"
                age = time.time() - heartbeat.stat().st_mtime
                if age > 25:
                    problems.extend(recover(path, locked=True))
                else:
                    problems.append("Активная сессия %s" % data.get("sid"))
        except Exception as exc:
            problems.append("%s: %s" % (path, exc))
    return problems


def watch(path):
    path = validate_journal_path(path)
    while path.exists():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            if data.get("state") == "done":
                return
            heartbeat = path.parent / "heartbeat"
            if time.time() - heartbeat.stat().st_mtime > 25:
                owner = data.get("owner")
                if isinstance(owner, dict) and owned_process(owner):
                    stop_process(owner)
                problems = recover(path)
                if problems:
                    raise RuntimeError("CLEANUP_INCOMPLETE: %s" % "; ".join(problems))
                return
        except FileNotFoundError:
            return
        except (OSError, ValueError, KeyError):
            raise
        time.sleep(5)
