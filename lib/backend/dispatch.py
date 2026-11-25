import fcntl
import json
import os
import re
import signal
import subprocess
import tempfile
from pathlib import Path

from tui_protocol import emit, receive


ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "lib/backend/actions.json"
BRIDGE = ROOT / "lib/backend/bridge.sh"


def report_events(job, source):
    payload = source.read(8 * 1024 * 1024 + 1)
    if len(payload) > 8 * 1024 * 1024:
        raise ValueError("Отчёт слишком велик для встроенного просмотра.")
    report = json.loads(payload)
    if report.get("v") != 1 or not isinstance(report.get("sections"), list):
        raise ValueError("Некорректный ответ сборщика HAProxy.")
    for section in report["sections"]:
        if "text" in section:
            emit(job, "report_text", message=section["text"][:8192])
            continue
        headers = section["headers"]
        rows = section["rows"]
        emit(job, "report_header", columns=headers[:64])
        if len(rows) > 1000 or len(headers) > 64:
            emit(job, "warning", message="Встроенный просмотр ограничен 1000 строками и 64 столбцами.")
        selection = rows if len(rows) <= 1000 else rows[:999] + rows[-1:]
        for row in selection:
            emit(job, "report_row", cells=[str(value)[:128] for value in row[:64]])


def arguments(action, supplied):
    fields = action.get("fields", ())
    if not isinstance(supplied, dict) or supplied.keys() != {field["id"] for field in fields}:
        raise ValueError("Не совпадает набор параметров.")
    for field in fields:
        value = supplied[field["id"]]
        if (not isinstance(value, str) or any(ord(char) < 32 for char in value)
                or len(value) > field.get("limit", 768)
                or not re.fullmatch(field.get("pattern", ".*"), value)):
            raise ValueError("Проверьте поле «" + field["label"] + "».")
        if field.get("secret"):
            raise ValueError("Секрет должен передаваться в отдельном запросе.")
    return [part if not part.startswith("@") else supplied[part[1:]] for part in action.get("args", ())]


def run():
    job = "unknown"
    signal.signal(signal.SIGINT, lambda *_: None)
    try:
        request = receive()
        job = request["job_id"]
        if request.get("v") != 1 or not re.fullmatch(r"[0-9]{1,20}", job):
            raise ValueError("Неизвестная версия запроса.")
        with CATALOG.open(encoding="utf-8") as source:
            registry = json.load(source)
        if registry["v"] != 1:
            raise ValueError("Неизвестная версия каталога.")
        action = next((item for item in registry["actions"] if item["id"] == request["action_id"]), None)
        if action is None:
            raise ValueError("Действие отсутствует в каталоге.")
        args = arguments(action, request["params"])
        emit(job, "started")
        if action["id"] == "demo.sample":
            emit(job, "step", message="Проверка связи интерфейса с backend.")
            emit(job, "result", status="ok", exit_code=0, data={})
            return 0
        if os.geteuid() != 0:
            raise ValueError("Действие требует root.")
        data = {}
        with tempfile.TemporaryFile() as outcome:
            lock = None
            try:
                if action["risk"] in {"mutate", "destructive", "reboot"}:
                    lock = os.open("/run/lock/remnasuper-tui.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                kind = action.get("kind", "bash")
                if kind in {"bash", "report"}:
                    cmd = ["/bin/bash", str(BRIDGE), job, str(outcome.fileno()),
                           action["module"], action["target"], *args]
                elif kind == "update":
                    cmd = ["/bin/bash", str(ROOT / "lib/backend/update-tui.sh"), *args]
                else:
                    raise ValueError("Неизвестный тип запуска.")
                if action["id"] == "update.check":
                    check = subprocess.run(cmd, stdout=subprocess.PIPE, text=True, check=False)
                    code = check.returncode
                    if code == 0:
                        available = check.stdout.strip()
                        data["available"] = available
                        labels = {"current": "Установлена актуальная версия.",
                                  "local": "Запущена локальная сборка.",
                                  "skipped": "Проверка обновлений отключена."}
                        emit(job, "log", message=labels.get(available, "Доступна версия " + available + "."))
                elif kind == "report":
                    with tempfile.TemporaryFile() as report_file:
                        code = subprocess.run(cmd, stdout=report_file, pass_fds=(3, 4, outcome.fileno()),
                                              check=False).returncode
                        if code == 0:
                            report_file.seek(0)
                            report_events(job, report_file)
                else:
                    code = subprocess.run(cmd, pass_fds=(3, 4, outcome.fileno()), check=False).returncode
                    if action["id"] == "update.apply" and code == 0:
                        data["installed"] = (ROOT.parent / "current").resolve() != ROOT
            finally:
                if lock is not None:
                    os.close(lock)
            outcome.seek(0)
            reported_error = bool(outcome.read(1))
        code = 128 - code if code < 0 else code
        status = ("cancelled" if code == 130 else "rollback_failed" if code == 76 else
                  "partial" if code == 75 or (code == 0 and reported_error) else "failed" if code else "ok")
    except BlockingIOError:
        emit(job, "error", message="Другая копия интерфейса выполняет изменение настроек.")
        code, status = 1, "failed"
        data = {}
    except (OSError, ValueError, KeyError, TypeError) as failure:
        emit(job, "error", message=str(failure))
        code, status = 1, "failed"
        data = {}
    emit(job, "result", status=status, exit_code=code, data=data)
    return code


if __name__ == "__main__":
    raise SystemExit(run())
