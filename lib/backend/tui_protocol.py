import json
import os
import secrets


def receive():
    line = bytearray()
    while len(line) < 4096:
        byte = os.read(3, 1)
        if byte == b"\n":
            return json.loads(line)
        if not byte:
            break
        line.extend(byte)
    raise ValueError("Некорректное сообщение интерфейса.")


def emit(job_id, kind, **data):
    event = {"v": 1, "job_id": job_id, "type": kind, **data}
    encoded = (json.dumps(event, ensure_ascii=False) + "\n").encode()
    while encoded:
        encoded = encoded[os.write(4, encoded):]


def ask(job_id, kind, message, default="", choices=None, sensitive=""):
    prompt_id = secrets.token_hex(8)
    emit(job_id, "prompt", prompt_id=prompt_id, kind=kind, message=message, default=default,
         choices=choices or [], sensitive=sensitive)
    reply = receive()
    if (reply.get("v") != 1 or reply.get("job_id") != job_id or reply.get("prompt_id") != prompt_id
            or not isinstance(reply.get("accepted"), bool) or not isinstance(reply.get("value"), str)):
        raise ValueError("Некорректный ответ интерфейса.")
    return reply["value"] if reply["accepted"] else None


if __name__ == "__main__":
    import sys

    job_id, method, kind, text, *args = sys.argv[1:]
    if method == "event":
        emit(job_id, kind, message=text)
    else:
        choice_args = args[1:]
        choices = [{"value": choice_args[i], "label": choice_args[i + 1]} for i in range(0, len(choice_args), 2)]
        result = ask(job_id, kind, text, args[0] if args else "", choices)
        if result is None:
            sys.exit(130)
        if choices and result not in {choice["value"] for choice in choices}:
            sys.exit(2)
        sys.stdout.write(result)
