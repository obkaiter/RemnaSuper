"""Bounded, authenticated control messages. Metadata is not encrypted."""

import hashlib
import hmac
import json
import os
import queue
import socket
import threading
import time

VERSION = 1
MAX_FRAME = 1024 * 1024
_buffers = {}
TYPES = {"HELLO", "READY", "START_TEST", "STOP_TEST", "RESULT",
         "HEARTBEAT", "ABORT", "DONE"}


def canonical(value):
    return json.dumps(value, separators=(",", ":"), sort_keys=True,
                      ensure_ascii=False).encode("utf-8")


def mac(secret, value):
    return hmac.new(secret, canonical(value), hashlib.sha256).hexdigest()


def read_frame(sock):
    data = _buffers.setdefault(sock, bytearray())
    while b"\n" not in data:
        if len(data) > MAX_FRAME:
            raise ValueError("Слишком длинное управляющее сообщение")
        part = sock.recv(min(65536, MAX_FRAME + 1 - len(data)))
        if not part:
            raise ConnectionError("Канал управления закрыт")
        data.extend(part)
    line, _, rest = data.partition(b"\n")
    if len(line) + 1 > MAX_FRAME:
        raise ValueError("Слишком длинное управляющее сообщение")
    _buffers[sock] = bytearray(rest)
    return json.loads(line.decode("utf-8"))


def write_frame(sock, value):
    frame = canonical(value) + b"\n"
    if len(frame) > MAX_FRAME:
        raise ValueError("Слишком длинное управляющее сообщение")
    sock.sendall(frame)


def authenticate_server(sock, sid, secret):
    nonce_a = os.urandom(32).hex()
    write_frame(sock, {"version": VERSION, "sid": sid, "nonce": nonce_a})
    answer = read_frame(sock)
    if set(answer) != {"version", "sid", "nonce", "proof"}:
        raise ValueError("Неверный формат сопряжения")
    if answer["version"] != VERSION or answer["sid"] != sid:
        raise ValueError("Версия или session_id не совпадает")
    nonce_b = answer["nonce"]
    if not isinstance(nonce_b, str) or len(nonce_b) != 64:
        raise ValueError("Некорректный nonce")
    expected = hmac.new(secret, ("join:" + sid + ":" + nonce_a + ":" + nonce_b).encode(),
                        hashlib.sha256).hexdigest()
    if not hmac.compare_digest(str(answer["proof"]), expected):
        raise ValueError("Секрет сопряжения не совпадает")
    proof = hmac.new(secret, ("accept:" + sid + ":" + nonce_b + ":" + nonce_a).encode(),
                     hashlib.sha256).hexdigest()
    write_frame(sock, {"version": VERSION, "sid": sid, "proof": proof})
    return AuthSocket(sock, sid, secret, "A", nonce_a, nonce_b)


def authenticate_client(sock, sid, secret):
    greeting = read_frame(sock)
    if set(greeting) != {"version", "sid", "nonce"}:
        raise ValueError("Неверное приветствие")
    if greeting["version"] != VERSION or greeting["sid"] != sid:
        raise ValueError("Версия или session_id не совпадает")
    nonce_a = greeting["nonce"]
    if not isinstance(nonce_a, str) or len(nonce_a) != 64:
        raise ValueError("Некорректный nonce")
    nonce_b = os.urandom(32).hex()
    proof = hmac.new(secret, ("join:" + sid + ":" + nonce_a + ":" + nonce_b).encode(),
                     hashlib.sha256).hexdigest()
    write_frame(sock, {"version": VERSION, "sid": sid, "nonce": nonce_b, "proof": proof})
    answer = read_frame(sock)
    expected = hmac.new(secret, ("accept:" + sid + ":" + nonce_b + ":" + nonce_a).encode(),
                        hashlib.sha256).hexdigest()
    if answer.get("version") != VERSION or answer.get("sid") != sid or not hmac.compare_digest(
            str(answer.get("proof", "")), expected):
        raise ValueError("Координатор не прошёл проверку")
    return AuthSocket(sock, sid, secret, "B", nonce_a, nonce_b)


class AuthSocket:
    def __init__(self, sock, sid, secret, role, nonce_a, nonce_b):
        self.sock = sock
        self.sid = sid
        seed = hmac.new(secret, ("control:" + sid + ":" + nonce_a + ":" + nonce_b).encode(),
                        hashlib.sha256).digest()
        a_to_b = hmac.new(seed, b"A_TO_B", hashlib.sha256).digest()
        b_to_a = hmac.new(seed, b"B_TO_A", hashlib.sha256).digest()
        self.out_key, self.in_key = (a_to_b, b_to_a) if role == "A" else (b_to_a, a_to_b)
        self.in_seq = 0
        self.out_seq = 0
        self.inbox = queue.Queue()
        self.send_lock = threading.Lock()
        self.stop = threading.Event()
        self.last_rx = time.monotonic()
        self.sock.settimeout(2)
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.pinger = threading.Thread(target=self._heartbeat, daemon=True)
        self.reader.start()
        self.pinger.start()

    def send(self, kind, payload=None):
        if kind not in TYPES or not isinstance(payload or {}, dict):
            raise ValueError("Недопустимая управляющая команда")
        with self.send_lock:
            self.out_seq += 1
            message = {"version": VERSION, "sid": self.sid, "seq": self.out_seq,
                       "type": kind, "payload": payload or {}}
            message["mac"] = mac(self.out_key, message)
            write_frame(self.sock, message)

    def _read(self):
        try:
            while not self.stop.is_set():
                try:
                    message = read_frame(self.sock)
                except socket.timeout:
                    continue
                if set(message) != {"version", "sid", "seq", "type", "payload", "mac"}:
                    raise ValueError("Неверная схема управляющего сообщения")
                tag = message.pop("mac")
                if (message["version"] != VERSION or message["sid"] != self.sid or
                        message["seq"] != self.in_seq + 1 or message["type"] not in TYPES or
                        not isinstance(message["payload"], dict) or
                        not hmac.compare_digest(str(tag), mac(self.in_key, message))):
                    raise ValueError("Нарушена подлинность или последовательность сообщений")
                self.in_seq += 1
                self.last_rx = time.monotonic()
                if message["type"] != "HEARTBEAT":
                    self.inbox.put(message)
        except Exception as exc:
            self.stop.set()
            self.inbox.put({"type": "ABORT", "payload": {"reason": str(exc)}})

    def _heartbeat(self):
        while not self.stop.wait(3):
            if time.monotonic() - self.last_rx > 15:
                self.stop.set()
                self.inbox.put({"type": "ABORT", "payload": {"reason": "Потерян канал управления"}})
                return
            try:
                self.send("HEARTBEAT")
            except Exception:
                self.stop.set()
                return

    def receive(self, timeout=30):
        try:
            message = self.inbox.get(timeout=timeout)
        except queue.Empty:
            raise TimeoutError("Нет ответа второй VPS") from None
        if message["type"] == "ABORT":
            raise ConnectionError(message["payload"].get("reason", "Вторая VPS прервала сессию"))
        return message

    def close(self):
        self.stop.set()
        _buffers.pop(self.sock, None)
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.sock.close()
