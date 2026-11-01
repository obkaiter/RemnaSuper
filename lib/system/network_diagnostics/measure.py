"""Bounded host-side measurements; no shell commands from the peer."""

import hashlib
import hmac
import json
import math
import os
import resource
import secrets
import shutil
import signal
import socket
import statistics
import struct
import subprocess
import sys
import time
from pathlib import Path

from safety import command

CHUNK = 1024 * 1024
MAX_FILE = 4 * 1024 ** 3


def check_pressure(resources):
    available_kib = next((int(line.split()[1]) for line in
                          Path("/proc/meminfo").read_text().splitlines()
                          if line.startswith("MemAvailable:")), 0)
    if available_kib < 128 * 1024:
        raise RuntimeError("Доступная память упала ниже 128 MiB; нагрузка остановлена")
    if shutil.disk_usage(resources.path.parent).free < 128 * 1024 ** 2:
        raise RuntimeError("Свободное место упало ниже 128 MiB; нагрузка остановлена")


def check_stop(stop):
    if stop is not None and stop.is_set():
        reason = stop.reason() if hasattr(stop, "reason") else "Потерян канал управления"
        if reason == "Достигнут временной бюджет профиля":
            raise TimeoutError(reason)
        raise ConnectionError(reason)


def percentile(values, percent):
    if not values:
        return None
    ordered = sorted(values)
    rank = (len(ordered) - 1) * percent / 100
    lower = math.floor(rank)
    upper = math.ceil(rank)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (rank - lower)


def distribution(values):
    if not values:
        return {"samples": 0, "min": None, "mean": None, "p50": None,
                "p95": None, "p99": None, "max": None, "stdev": None}
    return {"samples": len(values), "min": min(values), "mean": statistics.mean(values),
            "p50": percentile(values, 50), "p95": percentile(values, 95),
            "p99": percentile(values, 99), "max": max(values),
            "stdev": statistics.pstdev(values)}


def recv_exact(sock, length):
    data = bytearray()
    while len(data) < length:
        part = sock.recv(min(CHUNK, length - len(data)))
        if not part:
            raise ConnectionError("Преждевременное закрытие потока")
        data.extend(part)
    return bytes(data)


def auth_tag(secret, sid, stage):
    return hmac.new(secret, (sid + ":" + stage).encode(), hashlib.sha256).digest()


def service(journal, kind, stage, port, size):
    data = json.loads(Path(journal).read_text(encoding="utf-8"))
    sid, peer = data["sid"], data["peer"]
    temp = Path(journal).parent / "tmp"
    secret = (temp / "secret").read_bytes()
    result_path = temp / (stage + ".json")
    ready_path = temp / (stage + ".ready")
    family = socket.AF_INET6 if ":" in peer else socket.AF_INET
    bind_ip = "::" if family == socket.AF_INET6 else "0.0.0.0"
    sock_type = socket.SOCK_DGRAM if kind == "udp" else socket.SOCK_STREAM
    server = socket.socket(family, sock_type)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if family == socket.AF_INET6:
        server.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    server.bind((bind_ip, port))
    server.settimeout(1)
    if kind != "udp":
        server.listen(1)
    ready_path.write_text("ready", encoding="ascii")
    stopped = False

    def end_service(_signum, _frame):
        nonlocal stopped
        stopped = True

    signal.signal(signal.SIGTERM, end_service)
    result = {"status": "FAILED", "reason": "Нет тестовых данных", "metrics": {}}
    try:
        if kind == "udp":
            seen = set()
            last_seq = -1
            duplicate = 0
            reordered = 0
            arrivals = []
            first = None
            last = None
            while not stopped:
                try:
                    packet, address = server.recvfrom(2048)
                except socket.timeout:
                    continue
                if address[0] != peer or len(packet) < 32:
                    continue
                body, tag = packet[:-16], packet[-16:]
                expected = hmac.new(secret, sid.encode() + stage.encode() + body,
                                    hashlib.sha256).digest()[:16]
                if not hmac.compare_digest(tag, expected):
                    continue
                sequence = struct.unpack("!Q", body[:8])[0]
                now = time.monotonic()
                if sequence in seen:
                    duplicate += 1
                    continue
                if sequence < last_seq:
                    reordered += 1
                seen.add(sequence)
                last_seq = max(last_seq, sequence)
                first = first or now
                if last is not None:
                    arrivals.append((now - last) * 1000)
                last = now
            result = {"status": "FINISHED", "metrics": {
                "received": len(seen), "duplicate": duplicate, "out_of_order": reordered,
                "duration": max((last or 0) - (first or 0), 0),
                "interarrival_ms": distribution(arrivals),
                "jitter_ms": (statistics.mean(abs(b - a) for a, b in
                              zip(arrivals, arrivals[1:])) if len(arrivals) > 1 else None),
                "jitter_method": "средняя абсолютная разность последовательных интервалов прибытия"}}
        else:
            deadline = time.monotonic() + max(30, min(900, size // 1048576 + 60))
            conn = None
            while conn is None and time.monotonic() < deadline and not stopped:
                try:
                    candidate, address = server.accept()
                    if address[0] == peer:
                        conn = candidate
                    else:
                        candidate.close()
                except socket.timeout:
                    continue
            if conn is None:
                raise TimeoutError("Тестовый клиент не подключился")
            with conn:
                conn.settimeout(20)
                if not hmac.compare_digest(recv_exact(conn, 32), auth_tag(secret, sid, stage)):
                    raise ValueError("Неверная аутентификация тестового потока")
                if kind == "file":
                    received = 0
                    digest = hashlib.sha256()
                    gaps = []
                    previous = time.monotonic()
                    started = previous
                    target = temp / (stage + ".received")
                    with target.open("xb") as output:
                        while received < size and not stopped:
                            part = conn.recv(min(CHUNK, size - received))
                            if not part:
                                break
                            now = time.monotonic()
                            gaps.append(now - previous)
                            previous = now
                            output.write(part)
                            digest.update(part)
                            received += len(part)
                        output.flush()
                        os.fsync(output.fileno())
                    duration = time.monotonic() - started
                    result = {"status": "FINISHED" if received == size else "PARTIAL",
                              "reason": None if received == size else "Неполная передача",
                              "metrics": {"bytes": received, "sha256": digest.hexdigest(),
                                          "duration": duration, "max_gap_s": max(gaps, default=None)}}
                    target.unlink()
                elif kind == "echo":
                    count = 0
                    while not stopped:
                        try:
                            header = recv_exact(conn, 12)
                        except (ConnectionError, socket.timeout):
                            break
                        length, _nonce = struct.unpack("!IQ", header)
                        if not 1 <= length <= 4096:
                            raise ValueError("Размер echo вне диапазона")
                        payload = recv_exact(conn, length)
                        conn.sendall(header + payload)
                        count += 1
                    result = {"status": "FINISHED", "metrics": {"requests": count}}
                else:
                    raise ValueError("Неизвестный сервис")
    except Exception as exc:
        result = {"status": "FAILED", "reason": str(exc), "metrics": result["metrics"]}
    finally:
        server.close()
        result_tmp = temp / (stage + ".json.tmp")
        result_tmp.write_text(json.dumps(result), encoding="utf-8")
        result_tmp.replace(result_path)
        ready_path.unlink(missing_ok=True)


def available_port(peer, proto="tcp", preferred=None):
    family = socket.AF_INET6 if ":" in peer else socket.AF_INET
    bind_ip = "::" if family == socket.AF_INET6 else "0.0.0.0"
    for port in ([preferred] if preferred else secrets.SystemRandom().sample(range(55000, 56000), 25)):
        if not 55000 <= port <= 55999:
            continue
        try:
            with socket.socket(family, socket.SOCK_STREAM if proto == "tcp" else socket.SOCK_DGRAM) as sock:
                sock.bind((bind_ip, port))
            return port
        except OSError:
            continue
    raise RuntimeError("Нет свободного диагностического порта")


def start_listener(resources, kind, stage, port, size=0):
    proto = "udp" if kind == "udp" else "tcp"
    available_port(resources.peer, proto, port)
    if kind == "iperf_udp":
        available_port(resources.peer, "udp", port)
    resources.open_port(port, proto, stage)
    if kind == "iperf_udp":
        try:
            resources.open_port(port, "udp", stage)
        except Exception:
            resources.close_port(port, "tcp")
            raise
    ready = resources.path.parent / "tmp" / (stage + ".ready")
    if ready.exists():
        ready.unlink()
    if kind in ("iperf", "iperf_udp"):
        args = ["iperf3", "-6" if ":" in resources.peer else "-4",
                "-s", "-p", str(port), "-1"]
    else:
        args = [sys.executable, str(resources.agent_path), "service", str(resources.path),
                kind, stage, str(port), str(size)]
    log_path = resources.path.parent / "tmp" / (stage + ".listener.log")
    log = log_path.open("wb")
    try:
        process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                   stderr=log, start_new_session=True)
    except Exception:
        log.close()
        resources.close_port(port, proto)
        if kind == "iperf_udp":
            resources.close_port(port, "udp")
        raise
    log.close()
    try:
        entry = resources.add_process(process)
    except Exception:
        process.terminate()
        process.wait(timeout=3)
        resources.close_port(port, proto)
        if kind == "iperf_udp":
            resources.close_port(port, "udp")
        raise
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if process.poll() is not None:
            break
        if kind not in ("iperf", "iperf_udp") and ready.exists():
            return entry
        if kind in ("iperf", "iperf_udp"):
            ss = command(["ss", "-ltn", "sport", "=", ":%d" % port])
            if ss.returncode == 0 and ":%d" % port in ss.stdout:
                return entry
        time.sleep(0.1)
    resources.release_process(entry)
    resources.close_port(port, proto)
    if kind == "iperf_udp":
        resources.close_port(port, "udp")
    detail = log_path.read_text(errors="replace")[-400:]
    raise RuntimeError("Слушатель %s не запустился на порту %d: %s" % (kind, port, detail))


def stop_listener(resources, entry, kind, stage, port):
    path = resources.path.parent / "tmp" / (stage + ".json")
    if kind in ("file", "echo"):
        deadline = time.monotonic() + 15
        while not path.exists() and time.monotonic() < deadline:
            time.sleep(0.1)
    resources.release_process(entry)
    resources.close_port(port, "udp" if kind == "udp" else "tcp")
    if kind == "iperf_udp":
        resources.close_port(port, "udp")
    if path.exists():
        result = json.loads(path.read_text(encoding="utf-8"))
        path.unlink()
        return result
    if kind in ("iperf", "iperf_udp"):
        return {"status": "PARTIAL", "reason": "Результат iperf3 хранится у отправителя", "metrics": {}}
    return {"status": "FAILED", "reason": "Нет результата слушателя", "metrics": {}}


def run_owned(resources, args, timeout, output=None, stop=None):
    capture = Path(output or resources.path.parent / "tmp" / ("command-%d.out" % os.getpid()))
    stream = capture.open("wb")
    try:
        process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=stream,
                                   stderr=subprocess.PIPE, start_new_session=True)
    except Exception:
        stream.close()
        if not output:
            capture.unlink(missing_ok=True)
        raise
    try:
        entry = resources.add_process(process)
    except Exception:
        process.terminate()
        process.wait(timeout=3)
        stream.close()
        raise
    started = time.monotonic()
    last_pressure = started
    try:
        while process.poll() is None:
            check_stop(stop)
            if time.monotonic() - started > timeout:
                raise TimeoutError("Превышен лимит времени теста")
            if time.monotonic() - last_pressure > 5:
                check_pressure(resources)
                last_pressure = time.monotonic()
            time.sleep(0.2)
        _unused, stderr = process.communicate(timeout=2)
        stream.close()
        stdout = capture.read_bytes()[:16 * 1024 * 1024]
        if process.returncode:
            raise RuntimeError((stderr or stdout).decode("utf-8", "replace")[:400])
        return stdout
    finally:
        stream.close()
        resources.release_process(entry)
        if not output:
            capture.unlink(missing_ok=True)


def run_iperf(resources, peer, port, streams, duration, cap_mbps, raw_path, stop,
              udp_bandwidth=False):
    per_stream_kbps = max(1, int(cap_mbps * 1000 / streams))
    args = ["iperf3", "-6" if ":" in peer else "-4",
            "-c", peer, "-p", str(port), "-P", str(streams),
            "-O", "2", "-t", str(duration), "-J", "-b", "%dK" % per_stream_kbps]
    if udp_bandwidth:
        args.extend(["-u", "-l", "1200"])
    raw = run_owned(resources, args, duration + 20, raw_path, stop)
    try:
        data = json.loads(raw)
        if data.get("error"):
            raise ValueError(str(data["error"]))
        sender = data["end"]["sum_sent"]
        receiver = data["end"]["sum_received"]
        intervals = [item["sum"]["bits_per_second"] / 1_000_000
                     for item in data["intervals"] if "sum" in item]
        result = {"sender_mbps": sender["bits_per_second"] / 1_000_000,
                "receiver_mbps": receiver["bits_per_second"] / 1_000_000,
                "bytes": sender.get("bytes"), "retransmits": sender.get("retransmits"),
                "interval_mbps": intervals,
                "cpu_local": data["end"].get("cpu_utilization_percent", {}).get("host_total")}
        streams = [item.get("receiver", {}).get("bits_per_second", 0) / 1000000
                   for item in data["end"].get("streams", [])]
        if streams and sum(value * value for value in streams):
            result["stream_mbps"] = streams
            result["fairness_index"] = (sum(streams) ** 2 /
                                         (len(streams) * sum(value * value for value in streams)))
        if udp_bandwidth:
            result["loss_pct"] = receiver.get("lost_percent")
            result["jitter_ms"] = receiver.get("jitter_ms")
            result["lost_packets"] = receiver.get("lost_packets")
        return result
    except (KeyError, TypeError, ValueError) as exc:
        raise RuntimeError("Не удалось разобрать JSON iperf3: %s; сырой вывод: %s" %
                           (exc, raw_path)) from exc


def create_file(resources, size, stage, stop=None):
    if not 1 <= size <= MAX_FILE:
        raise ValueError("Размер файла вне разрешённого диапазона")
    free = shutil.disk_usage(resources.path.parent).free
    if free < size + 512 * 1024 ** 2:
        raise RuntimeError("Недостаточно места для файла и запаса 512 MiB")
    path = resources.path.parent / "tmp" / (stage + ".source")
    digest = hashlib.sha256()
    started = time.monotonic()
    try:
        with path.open("xb") as output:
            remaining = size
            while remaining:
                check_stop(stop)
                chunk = os.urandom(min(CHUNK, remaining))
                output.write(chunk)
                digest.update(chunk)
                remaining -= len(chunk)
            output.flush()
            os.fsync(output.fileno())
    except BaseException:
        path.unlink(missing_ok=True)
        raise
    return path, digest.hexdigest(), time.monotonic() - started


def send_file(resources, peer, port, stage, size, cap_mbps, stop):
    source, digest, preparation = create_file(resources, size, stage, stop)
    sent = 0
    started = time.monotonic()
    try:
        with socket.create_connection((peer, port), timeout=10) as sock, source.open("rb") as stream:
            sock.settimeout(20)
            secret = (resources.path.parent / "tmp" / "secret").read_bytes()
            sock.sendall(auth_tag(secret, resources.sid, stage))
            started = time.monotonic()
            while sent < size:
                check_stop(stop)
                if sent % (64 * CHUNK) == 0:
                    check_pressure(resources)
                chunk = stream.read(min(CHUNK, size - sent))
                if not chunk:
                    raise IOError("Источник файла неожиданно закончился")
                sock.sendall(chunk)
                sent += len(chunk)
                expected_time = sent * 8 / (cap_mbps * 1_000_000)
                delay = expected_time - (time.monotonic() - started)
                if delay > 0:
                    time.sleep(min(delay, 0.2))
            sock.shutdown(socket.SHUT_WR)
        duration = time.monotonic() - started
        return {"bytes": sent, "sha256": digest, "duration": duration,
                "preparation_s": preparation, "avg_mbps": sent * 8 / duration / 1_000_000,
                "avg_mib_s": sent / duration / 1048576}
    except (OSError, ConnectionError, TimeoutError, RuntimeError) as exc:
        duration = time.monotonic() - started
        return {"status": "PARTIAL" if sent else "FAILED", "reason": str(exc),
                "metrics": {"bytes": sent, "duration": duration,
                            "preparation_s": preparation, "checksum_ok": False,
                            "avg_mbps": sent * 8 / duration / 1_000_000 if duration else None}}
    finally:
        source.unlink(missing_ok=True)


def run_echo(resources, peer, port, stage, size, count, cap_mbps, stop):
    secret = (resources.path.parent / "tmp" / "secret").read_bytes()
    times = []
    errors = 0
    started = time.monotonic()
    interval = max(0.001, size * 16 / (cap_mbps * 1000000))
    with socket.create_connection((peer, port), timeout=10) as sock:
        sock.settimeout(5)
        sock.sendall(auth_tag(secret, resources.sid, stage))
        for index in range(count):
            check_stop(stop)
            if index % 100 == 0:
                check_pressure(resources)
            message = struct.pack("!IQ", size, index) + secrets.token_bytes(size)
            t0 = time.monotonic()
            try:
                sock.sendall(message)
                if recv_exact(sock, len(message)) != message:
                    raise ValueError("Echo ID или данные не совпали")
                times.append((time.monotonic() - t0) * 1000)
            except (socket.timeout, ConnectionError):
                errors += 1
                break
            delay = started + (index + 1) * interval - time.monotonic()
            if delay > 0:
                time.sleep(delay)
    duration = time.monotonic() - started
    return {"requests": count, "received": len(times), "errors": errors,
            "rps": len(times) / duration if duration else None, "rtt_ms": distribution(times)}


def send_udp(resources, peer, port, stage, size, pps, seconds, stop):
    secret = (resources.path.parent / "tmp" / "secret").read_bytes()
    family = socket.AF_INET6 if ":" in peer else socket.AF_INET
    interval = 1 / pps
    count = min(int(pps * seconds), 25000)
    started = time.monotonic()
    with socket.socket(family, socket.SOCK_DGRAM) as sock:
        for index in range(count):
            check_stop(stop)
            body = struct.pack("!Q", index) + secrets.token_bytes(size - 24)
            tag = hmac.new(secret, resources.sid.encode() + stage.encode() + body,
                           hashlib.sha256).digest()[:16]
            sock.sendto(body + tag, (peer, port))
            delay = started + (index + 1) * interval - time.monotonic()
            if delay > 0:
                time.sleep(delay)
    duration = time.monotonic() - started
    return {"sent": count, "duration": duration, "pps_sent": count / duration,
            "payload_mbps": count * size * 8 / duration / 1_000_000}


def ping(peer, count, timeout=1, interval=0.2):
    family_flag = "-6" if ":" in peer else "-4"
    args = ["ping", family_flag, "-n", "-c", str(count), "-i", str(interval),
            "-W", str(timeout), peer]
    try:
        output = command(args, timeout=count * (interval + timeout) + 5).stdout
        import re
        values = [float(match) for match in re.findall(r"time=([\d.]+) ms", output)]
        return {"sent": count, "received": len(values), "loss_pct":
                100 * (count - len(values)) / count, "rtt_ms": distribution(values),
                "method": "ICMP RTT"}
    except Exception as exc:
        return {"sent": count, "received": 0, "loss_pct": None,
                "rtt_ms": distribution([]), "reason": str(exc), "method": "ICMP RTT"}


def preflight(peer, file_size, control_port):
    required = ["python3", "iperf3", "ufw", "ip", "ss", "ping", "systemctl"]
    missing = [name for name in required if not shutil.which(name)]
    if missing:
        raise RuntimeError("Не хватает команд: %s. Установите их отдельно и повторите запуск." %
                           ", ".join(missing))
    if not Path("/run/systemd/system").is_dir():
        raise RuntimeError("Для boot recovery сервер должен работать под systemd")
    firewall = command(["ufw", "status", "verbose"], check=True).stdout
    from safety import check_firewall
    check_firewall(peer)
    route = command(["ip", "-6" if ":" in peer else "-4", "route", "get", peer],
                    check=True).stdout.strip()
    if not route or "unreachable" in route:
        raise RuntimeError("Нет маршрута к IP второй VPS")
    free = shutil.disk_usage("/var/lib").free
    if free < file_size + 512 * 1024 ** 2:
        raise RuntimeError("Недостаточно свободного места для файла и запаса 512 MiB")
    memory_lines = Path("/proc/meminfo").read_text().splitlines()
    available_kib = int(next((line.split()[1] for line in memory_lines
                              if line.startswith("MemAvailable:")), "0"))
    if available_kib < 256 * 1024:
        raise RuntimeError("Перед запуском нужно не менее 256 MiB доступной памяти")
    tools = {}
    for name in ["iperf3", "python3", "curl", "mtr", "tracepath", "ping", "sar", "nstat", "ufw"]:
        if shutil.which(name):
            try:
                tools[name] = command([name, "--version"], timeout=3).stdout.splitlines()[:1]
            except Exception:
                tools[name] = ["установлен"]
        else:
            tools[name] = None
    snapshots = {}
    for name, args in {
            "interfaces": ["ip", "-j", "address"],
            "link_counters": ["ip", "-s", "link"],
            "qdisc": ["tc", "-s", "qdisc"],
            "sockets": ["ss", "-s"],
            "default_route": ["ip", "route", "show", "default"],
            "nstat": ["nstat", "-az"],
    }.items():
        try:
            snapshots[name] = command(args, timeout=5).stdout[:12000]
        except (OSError, subprocess.TimeoutExpired):
            snapshots[name] = None
    for name, path in {
            "congestion_control": "/proc/sys/net/ipv4/tcp_congestion_control",
            "tcp_mtu_probing": "/proc/sys/net/ipv4/tcp_mtu_probing",
            "net_dev": "/proc/net/dev",
            "diskstats": "/proc/diskstats",
    }.items():
        try:
            snapshots[name] = Path(path).read_text()[:12000]
        except OSError:
            snapshots[name] = None
    snapshots["nftables"] = ("present" if shutil.which("nft") else "unknown")
    snapshots["cloud_firewall"] = "unknown"
    snapshots["loadavg"] = os.getloadavg()
    snapshots["nofile_limit"] = resource.getrlimit(resource.RLIMIT_NOFILE)
    version_path = Path(__file__).resolve().parents[3] / "VERSION"
    return {"remnasuper_version": version_path.read_text().strip() if version_path.exists() else None,
            "os": Path("/etc/os-release").read_text(errors="replace")[:1000],
            "kernel": os.uname().release, "vcpu": os.cpu_count(),
            "memory_kib": int(next((line.split()[1] for line in
                memory_lines if line.startswith("MemTotal:")), "0")),
            "memory_available_kib": available_kib,
            "free_bytes": free, "route": route, "ufw": firewall[:2000],
            "tools": tools, "control_port": control_port, "snapshots": snapshots}
