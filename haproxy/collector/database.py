import sqlite3
from datetime import datetime, timezone


SCHEMA = '''
CREATE TABLE IF NOT EXISTS backends (
    name TEXT PRIMARY KEY, first_seen INTEGER NOT NULL, last_seen INTEGER NOT NULL,
    last_status TEXT NOT NULL, is_active INTEGER NOT NULL CHECK (is_active IN (0, 1))
);
CREATE TABLE IF NOT EXISTS backend_counters (
    backend TEXT PRIMARY KEY REFERENCES backends(name), worker TEXT NOT NULL,
    upload_bytes INTEGER NOT NULL, download_bytes INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS traffic_intervals (
    timestamp_start INTEGER NOT NULL, timestamp_end INTEGER NOT NULL, report_date TEXT NOT NULL,
    backend TEXT NOT NULL REFERENCES backends(name), upload_bytes INTEGER NOT NULL CHECK (upload_bytes >= 0),
    download_bytes INTEGER NOT NULL CHECK (download_bytes >= 0), PRIMARY KEY (timestamp_end, backend)
);
CREATE INDEX IF NOT EXISTS traffic_by_backend ON traffic_intervals (backend, report_date);
CREATE INDEX IF NOT EXISTS traffic_by_date ON traffic_intervals (report_date, backend);
CREATE TABLE IF NOT EXISTS collector_events (
    id INTEGER PRIMARY KEY, timestamp INTEGER NOT NULL, kind TEXT NOT NULL, detail TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS events_by_time ON collector_events (timestamp);
CREATE TABLE IF NOT EXISTS collector_state (
    key TEXT PRIMARY KEY, value TEXT NOT NULL
);
'''


def open_database(path, write=False):
    if write:
        database = sqlite3.connect(path, timeout=5)
    else:
        database = sqlite3.connect(f'{path.as_uri()}?mode=ro', uri=True, timeout=5)
    database.row_factory = sqlite3.Row
    try:
        database.execute('PRAGMA foreign_keys = ON')
        if write:
            if database.execute('PRAGMA journal_mode = WAL').fetchone()[0] != 'wal':
                raise sqlite3.OperationalError('Не удалось включить WAL')
            database.executescript(SCHEMA)
    except sqlite3.Error:
        database.close()
        raise
    return database


def read_state(database):
    return dict(database.execute('SELECT key, value FROM collector_state'))


def set_state(database, key, value):
    database.execute('INSERT OR REPLACE INTO collector_state VALUES (?, ?)', (key, str(value)))


def event(database, timestamp, kind, detail=''):
    database.execute('INSERT INTO collector_events (timestamp, kind, detail) VALUES (?, ?, ?)',
                     (timestamp, kind, detail))


def record_poll(database, timestamp, worker, backends, zone):
    local_day = datetime.fromtimestamp(timestamp, zone).date()
    with database:
        database.execute('BEGIN IMMEDIATE')
        state = read_state(database)
        previous_poll = int(state.get('last_poll', timestamp))
        if 'last_poll' in state and timestamp <= previous_poll:
            raise ValueError('Время измерения должно быть позже последнего успешного опроса')
        previous = {row['name']: row for row in database.execute('''
            SELECT b.name, b.is_active, b.last_status, c.worker, c.upload_bytes, c.download_bytes
            FROM backends b LEFT JOIN backend_counters c ON c.backend = b.name
        ''')}
        counters, registry, intervals = [], [], []
        for name, (upload, download, status) in backends.items():
            old = previous.get(name)
            delta_upload = delta_download = 0
            if old is None or not old['is_active']:
                event(database, timestamp, 'backend_added', name)
            if old is not None and old['worker'] is not None:
                if (not old['is_active'] or old['worker'] != worker or
                        upload < old['upload_bytes'] or download < old['download_bytes']):
                    event(database, timestamp, 'counter_reset', name)
                else:
                    delta_upload = upload - old['upload_bytes']
                    delta_download = download - old['download_bytes']
                if status != old['last_status']:
                    event(database, timestamp, 'backend_status', f"{name}: {old['last_status']} → {status}")
            registry.append((name, timestamp, timestamp, status, 1))
            counters.append((name, worker, upload, download))
            intervals.append((previous_poll, timestamp, local_day.isoformat(), name, delta_upload, delta_download))

        database.executemany('''
            INSERT INTO backends VALUES (?, ?, ?, ?, ?) ON CONFLICT(name) DO UPDATE SET
            last_seen=excluded.last_seen, last_status=excluded.last_status, is_active=1
        ''', registry)
        database.executemany('INSERT OR REPLACE INTO backend_counters VALUES (?, ?, ?, ?)', counters)
        database.executemany('INSERT INTO traffic_intervals VALUES (?, ?, ?, ?, ?, ?)', intervals)
        removed = [(name,) for name, old in previous.items() if old['is_active'] and name not in backends]
        database.executemany('UPDATE backends SET is_active=0 WHERE name=?', removed)
        for (name,) in removed:
            event(database, timestamp, 'backend_removed', name)

        if 'first_poll' not in state:
            set_state(database, 'first_poll', timestamp)
        set_state(database, 'last_poll', timestamp)
        set_state(database, 'current_error', '')


def prune_history(database, timestamp, retention_days):
    utc_day = datetime.fromtimestamp(timestamp, timezone.utc).date().isoformat()
    if read_state(database).get('last_cleanup') == utc_day:
        return
    cutoff = timestamp - retention_days * 86400
    with database:
        deleted = database.execute('DELETE FROM traffic_intervals WHERE timestamp_end < ?', (cutoff,)).rowcount
        database.execute('DELETE FROM collector_events WHERE timestamp < ?', (cutoff,))
        event(database, timestamp, 'cleanup', str(deleted))
        set_state(database, 'last_cleanup', utc_day)
