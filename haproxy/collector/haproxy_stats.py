import csv
import io
import socket
from pathlib import Path


def read_backends(payload):
    reader = csv.DictReader(io.StringIO(payload.removeprefix('# ')), strict=True)
    required = {'pxname', 'svname', 'bin', 'bout', 'status'}
    if not reader.fieldnames or not required.issubset(reader.fieldnames):
        raise ValueError('В ответе show stat отсутствуют обязательные поля CSV')

    backends = {}
    for row in reader:
        if any(row[field] is None for field in required):
            raise ValueError('Неполная строка в ответе show stat')
        if row['svname'] != 'BACKEND':
            continue
        if 'type' in row and row['type'] != '1':
            continue
        name = row['pxname']
        if not name or not row['status']:
            raise ValueError('В ответе show stat отсутствует имя или состояние Backend')
        upload, download = int(row['bin']), int(row['bout'])
        if min(upload, download) < 0 or max(upload, download) > 2**63 - 1:
            raise ValueError('Счётчики HAProxy выходят за диапазон SQLite')
        values = (upload, download, row['status'])
        if name in backends and backends[name] != values:
            raise ValueError(f'HAProxy вернул разные счётчики для Backend {name}')
        backends[name] = values
    return backends


def read_stats(path):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(str(path))
        connection.sendall(b'show info;show stat\n')
        with connection.makefile('r', encoding='utf-8') as response:
            payload = response.read()

    info, separator, stats = payload.partition('\n\n')
    if not separator or not stats.startswith('# ') or not stats.endswith('\n\n'):
        raise ValueError('Неполный ответ Stats Socket HAProxy')
    fields = dict(line.split(': ', 1) for line in info.splitlines() if ': ' in line)
    if int(fields.get('Nbproc', '1')) != 1:
        raise ValueError('Для подсчёта через один Stats Socket HAProxy должен работать с одним worker-процессом')
    pid = int(fields.get('Pid', '0'))
    if pid <= 0:
        raise ValueError('HAProxy не сообщил PID worker-процесса')
    boot_id = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
    process = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
    return f'{boot_id}:{pid}:{process[19]}', read_backends(stats)
