import argparse
import csv
import json
import logging
import os
import signal
import socket
import sqlite3
import subprocess
import sys
import threading
import time
from contextlib import closing
from dataclasses import dataclass
from datetime import datetime
from logging.handlers import RotatingFileHandler
from pathlib import Path
from tempfile import NamedTemporaryFile
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from database import event, open_database, prune_history, read_state, record_poll, set_state
from haproxy_stats import read_stats
from reports import (ReportOutput, export_month, last_poll_speed, list_backends, local_time, period, print_backend,
                     print_daily, print_recent, print_title, print_totals, size)


ROOT = Path(__file__).resolve().parents[1]
REPORT_COMMANDS = {'today', 'yesterday', 'month', 'daily', 'total', 'recent', 'status', 'backends', 'backend'}


def default_settings(root):
    return {'socket': str(root / 'run/admin.sock'), 'interval': 60,
            'database': str(root / 'database/traffic.sqlite3'), 'timezone': 'Europe/Moscow',
            'retention_days': 365, 'log_level': 'INFO'}


@dataclass(frozen=True)
class Settings:
    socket: Path
    database: Path
    interval: int
    zone: ZoneInfo
    retention_days: int
    log_level: str


def module_path(value, directory, root):
    path = Path(value)
    parent = root / directory
    if not path.is_absolute():
        path = root / path
    if not path.resolve().is_relative_to(parent) or path.resolve() == parent:
        raise ValueError(f'Путь должен находиться в {parent}')
    return path


def load_settings(root=ROOT):
    values = default_settings(root) | json.loads((root / 'config/config.json').read_text(encoding='utf-8'))
    for key in ('interval', 'retention_days'):
        if type(values[key]) is not int or values[key] < 1:
            raise ValueError(f'{key} должен быть положительным целым числом')
    if values['log_level'] not in ('DEBUG', 'INFO', 'WARNING', 'ERROR', 'CRITICAL'):
        raise ValueError('Недопустимый уровень логирования')
    return Settings(module_path(values['socket'], 'run', root), module_path(values['database'], 'database', root),
                    values['interval'], ZoneInfo(values['timezone']), values['retention_days'], values['log_level'])


def init_settings():
    config = ROOT / 'config/config.json'
    if config.exists():
        return
    with NamedTemporaryFile(mode='w', dir=config.parent, encoding='utf-8', delete=False) as temporary:
        candidate = Path(temporary.name)
        try:
            json.dump(default_settings(ROOT), temporary, indent=4)
            temporary.write('\n')
            temporary.close()
            try:
                os.link(candidate, config)
            except FileExistsError:
                pass
        finally:
            candidate.unlink(missing_ok=True)


def setup_log(settings):
    log = logging.getLogger('haproxy-traffic')
    log.setLevel(settings.log_level)
    handler = RotatingFileHandler(ROOT / 'logs/collector.log', maxBytes=1024**2, backupCount=5, encoding='utf-8')
    formatter = logging.Formatter('%(asctime)s UTC %(levelname)s %(message)s')
    formatter.converter = time.gmtime
    handler.setFormatter(formatter)
    rotate_logs(handler, int(time.time()))
    log.addHandler(handler)
    return log, handler


def rotate_logs(handler, timestamp):
    active = Path(handler.baseFilename).stat()
    if active.st_size and int(active.st_mtime) // 86400 < timestamp // 86400:
        handler.doRollover()
    cutoff = timestamp - 30 * 86400
    for sequence in range(1, 6):
        path = ROOT / f'logs/collector.log.{sequence}'
        try:
            if path.stat().st_mtime < cutoff:
                path.unlink()
        except FileNotFoundError:
            pass


def record_failure(database, timestamp, kind, detail):
    with database:
        if read_state(database).get('current_error') != detail:
            event(database, timestamp, kind, detail)
            set_state(database, 'last_error', detail)
            set_state(database, 'last_error_at', timestamp)
            set_state(database, 'current_error', detail)


def run_daemon(settings):
    import fcntl

    descriptor = os.open(settings.database.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        collect_traffic(settings)
    finally:
        os.close(descriptor)


def collect_traffic(settings):
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    log, handler = setup_log(settings)
    log.info('Сборщик запущен. Интервал %s с', settings.interval)
    try:
        database = open_database(settings.database, write=True)
    except sqlite3.Error as exc:
        log.error('Не удалось открыть SQLite: %s', exc)
        raise

    failure = None
    pending_sqlite_error = None
    last_cleanup = None
    with closing(database):
        with database:
            event(database, int(time.time()), 'started')
        try:
            notify = os.environ.get('NOTIFY_SOCKET')
            if notify:
                address = '\0' + notify[1:] if notify.startswith('@') else notify
                with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as connection:
                    connection.sendto(b'READY=1', address)
            while not stop.is_set():
                started = time.monotonic()
                timestamp = int(time.time())
                try:
                    worker, backends = read_stats(settings.socket)
                    if pending_sqlite_error is not None:
                        with database:
                            event(database, timestamp, 'sqlite_error', pending_sqlite_error)
                            set_state(database, 'last_error', pending_sqlite_error)
                            set_state(database, 'last_error_at', timestamp)
                        pending_sqlite_error = None
                    record_poll(database, int(time.time()), worker, backends, settings.zone)
                    if failure is not None:
                        log.info('Опрос HAProxy возобновлён')
                        failure = None
                except (OSError, ValueError, csv.Error, sqlite3.Error) as exc:
                    if isinstance(exc, sqlite3.Error):
                        kind, label = 'sqlite_error', 'Ошибка SQLite'
                    elif isinstance(exc, OSError):
                        kind, label = 'socket_unavailable', 'Stats Socket недоступен'
                    else:
                        kind, label = 'stats_error', 'Ошибка чтения статистики HAProxy'
                    detail = f'{label}: {exc}'
                    if detail != failure:
                        log.error('%s', detail)
                        failure = detail
                    try:
                        record_failure(database, timestamp, kind, detail)
                    except sqlite3.Error as database_error:
                        if pending_sqlite_error is None:
                            pending_sqlite_error = f'Ошибка SQLite: {database_error}'
                            log.error('%s', pending_sqlite_error)
                utc_day = timestamp // 86400
                if last_cleanup != utc_day:
                    try:
                        prune_history(database, timestamp, settings.retention_days)
                        rotate_logs(handler, timestamp)
                    except (OSError, sqlite3.Error) as exc:
                        log.error('Не удалось очистить старые данные: %s', exc)
                    last_cleanup = utc_day
                stop.wait(max(0, settings.interval - (time.monotonic() - started)))
        finally:
            try:
                with database:
                    event(database, int(time.time()), 'stopped')
            except sqlite3.Error as exc:
                log.error('Не удалось записать остановку сборщика: %s', exc)
            log.info('Сборщик остановлен')


def print_status(settings, database=None, output=None):
    output = output or ReportOutput()
    service = subprocess.run(['systemctl', 'is-active', 'haproxy-traffic.service'],
                             capture_output=True, text=True, timeout=5, check=False)
    state = service.stdout.strip() or 'не удалось получить состояние'
    output.text(f'Служба haproxy-traffic.service: {state}')
    output.text('Collector работает.' if state == 'active' else 'Collector не работает.')
    output.text(f'Интервал опроса: {settings.interval} с\nStats Socket: {settings.socket}\nБаза: {settings.database}')
    if output.structured:
        output.text(f'Хранение: {settings.retention_days} дней')
    if database is None:
        output.text('Сбор статистики ещё не начинался.')
        return
    total, active = database.execute('SELECT COUNT(*), COALESCE(SUM(is_active), 0) FROM backends').fetchone()
    state = read_state(database)
    zone = settings.zone
    output.text(f'Backend: {total}, в конфигурации: {active}, удалено: {total - active}')
    files = (settings.database, Path(f'{settings.database}-wal'), Path(f'{settings.database}-shm'))
    disk_size = 0
    for path in files:
        try:
            disk_size += path.stat().st_size
        except FileNotFoundError:
            pass
    output.text(f'Размер базы с WAL: {size(disk_size)}')
    output.text(f"Первое измерение: {local_time(state.get('first_poll'), zone)}")
    output.text(f"Последний успешный опрос: {local_time(state.get('last_poll'), zone)}")
    if 'last_poll' not in state:
        output.text('Сбор статистики ещё не начинался.')
    else:
        speed = last_poll_speed(database, int(state['last_poll']))
        output.text(f'Средняя скорость за последний интервал, Мбит/с: {speed}')
    if state.get('current_error'):
        output.text(f"Текущая ошибка: {state['current_error']}")
    if state.get('last_error'):
        output.text(f"Последняя ошибка ({local_time(state.get('last_error_at'), zone)}): {state['last_error']}")


def backup_database(database):
    stamp = datetime.now().strftime('%Y%m%d-%H%M%S')
    with NamedTemporaryFile(dir=ROOT / 'backups', prefix=f'traffic-{stamp}-', suffix='.tmp', delete=False) as file:
        candidate = Path(file.name)
    path = candidate.with_suffix('.sqlite3')
    try:
        with closing(sqlite3.connect(candidate)) as backup:
            database.backup(backup)
        candidate.replace(path)
    finally:
        candidate.unlink(missing_ok=True)
    print(f'Резервная копия SQLite: {path}')


def command_line():
    parser = argparse.ArgumentParser(description='Статистика HAProxy в RemnaSuper')
    parser.add_argument('--format', choices=('text', 'json'), default='text')
    parser.add_argument('--data-root', type=Path)
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ('init', 'daemon', 'today', 'yesterday', 'total', 'recent', 'status', 'backup', 'database', 'socket-path'):
        commands.add_parser(name)
    commands.add_parser('probe').add_argument('--worker', action='store_true')
    commands.add_parser('backends').add_argument('--names', action='store_true')
    for name in ('month', 'daily'):
        commands.add_parser(name).add_argument('month')
    commands.add_parser('export').add_argument('--month', required=True)
    backend = commands.add_parser('backend')
    backend.add_argument('name')
    backend.add_argument('--month')
    return parser.parse_args()


def run_report(args, settings, database, output):
    command = args.command
    zone = settings.zone
    today = datetime.now(zone).date()
    first, last = period(command, getattr(args, 'month', None), today)
    if command == 'status':
        print_status(settings, database, output)
    elif command == 'backends':
        list_backends(database, zone, args.names, output)
    elif command == 'recent':
        print_recent(database, zone, output)
    elif command == 'backend':
        print_backend(database, args.name, args.month, today, zone, output)
    elif command == 'backup':
        backup_database(database)
    elif command == 'export':
        export_month(database, ROOT / 'exports', first, last)
    else:
        print_title('Весь период хранения' if command == 'total' else f'{first:%d.%m.%Y} — {last:%d.%m.%Y}', zone, output)
        if command == 'daily':
            print_daily(database, first, last, output=output)
        else:
            print_totals(database, first, last, output)


def main():
    args = command_line()
    output = ReportOutput(args.format == 'json')
    try:
        if (output.structured or args.data_root is not None) and args.command not in REPORT_COMMANDS:
            raise ValueError('Формат JSON и выбор каталога доступны для отчётов чтения.')
        if args.command == 'init':
            init_settings()
        settings = load_settings(args.data_root or ROOT)
        if args.command == 'init':
            return 0
        if args.command == 'socket-path':
            print(settings.socket)
        elif args.command == 'database':
            print(settings.database)
        elif args.command == 'daemon':
            run_daemon(settings)
        elif args.command == 'probe':
            worker, backends = read_stats(settings.socket)
            print(worker if args.worker else f'Stats Socket доступен. Найдено Backend: {len(backends)}.')
        elif settings.database.is_file():
            with closing(open_database(settings.database)) as database:
                run_report(args, settings, database, output)
        elif args.command == 'status':
            print_status(settings, output=output)
        elif args.command != 'backends' or not args.names:
            output.text('Сбор статистики ещё не начинался. Нет данных для отчёта.')
        if output.structured:
            print(json.dumps({'v': 1, 'sections': output.sections}, ensure_ascii=False))
        sys.stdout.flush()
    except BrokenPipeError:
        with open(os.devnull, 'w') as output:
            os.dup2(output.fileno(), sys.stdout.fileno())
        return 0
    except (OSError, ValueError, TypeError, sqlite3.Error, csv.Error, ZoneInfoNotFoundError,
            subprocess.SubprocessError) as exc:
        print(f'Ошибка HAProxy Traffic: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    os.umask(0o077)
    sys.exit(main())
