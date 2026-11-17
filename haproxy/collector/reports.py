import calendar
import csv
import re
from datetime import date, datetime, timedelta
from pathlib import Path
from tempfile import NamedTemporaryFile


NO_DATA = 'Нет данных для отчёта за выбранный период.'


def month_dates(month):
    if not re.fullmatch(r'[0-9]{4}-(0[1-9]|1[0-2])', month):
        raise ValueError('Укажите месяц в формате ГГГГ-ММ')
    first = date.fromisoformat(f'{month}-01')
    return first, first.replace(day=calendar.monthrange(first.year, first.month)[1])


def period(command, month, today):
    if command in ('month', 'daily', 'export') or (command == 'backend' and month):
        return month_dates(month or today.strftime('%Y-%m'))
    if command == 'today':
        return today, today
    if command == 'yesterday':
        yesterday = today - timedelta(days=1)
        return yesterday, yesterday
    return date.min, date.max


def local_time(timestamp, zone):
    if timestamp is None:
        return '—'
    return datetime.fromtimestamp(int(timestamp), zone).strftime('%d.%m.%Y %H:%M:%S')


def size(value):
    if value == 0:
        return '0 B'
    if value < 1024**2:
        return f'{value} B' if value < 1024 else f'{value / 1024:.2f} KiB'
    if value < 1024**3:
        return f'{value / 1024**2:.2f} MiB'
    return f'{value / 1024**3:.2f} GiB'


def data_columns(upload, download):
    return size(upload), size(download), size(upload + download)


def print_table(headers, rows, right_from):
    rows = [tuple(str(value) for value in row) for row in rows]
    widths = [max(map(len, column)) for column in zip(headers, *rows)]

    def render(row):
        return '  '.join(value.ljust(width) if index < right_from else value.rjust(width)
                        for index, (value, width) in enumerate(zip(row, widths)))

    print(render(headers))
    print('-' * (sum(widths) + 2 * (len(widths) - 1)))
    for row in rows:
        print(render(row))


def print_title(label, zone):
    print(f'BITWIRE VPN — СТАТИСТИКА ТРАФИКА\n{label}\nЧасовой пояс: {zone}\n')


def totals(database, first, last, name=None):
    query = '''SELECT backend, SUM(upload_bytes), SUM(download_bytes)
               FROM traffic_intervals WHERE report_date BETWEEN ? AND ?'''
    params = [first.isoformat(), last.isoformat()]
    if name is not None:
        query += ' AND backend=?'
        params.append(name)
    return list(database.execute(query + ' GROUP BY backend ORDER BY backend', params))


def print_totals(rows):
    if not rows:
        print(NO_DATA)
        return
    report = [(name, *data_columns(upload, download)) for name, upload, download in rows]
    upload = sum(row[1] for row in rows)
    download = sum(row[2] for row in rows)
    report.append(('ИТОГО', *data_columns(upload, download)))
    print_table(('BACKEND', 'UPLOAD', 'DOWNLOAD', 'TOTAL'), report, 1)


def daily_rows(database, first, last, name=None):
    query = '''SELECT report_date, backend, SUM(upload_bytes), SUM(download_bytes)
               FROM traffic_intervals WHERE report_date BETWEEN ? AND ?'''
    params = [first.isoformat(), last.isoformat()]
    if name is not None:
        query += ' AND backend=?'
        params.append(name)
    return list(database.execute(query + ' GROUP BY report_date, backend ORDER BY report_date, backend', params))


def print_daily(database, first, last, name=None):
    samples = daily_rows(database, first, last, name)
    if not samples:
        print(NO_DATA)
        return
    names = sorted({row[1] for row in samples})
    data = {(day, backend): (upload, download) for day, backend, upload, download in samples}
    rows = []
    for offset in range((last - first).days + 1):
        day = first + timedelta(days=offset)
        values = [data.get((day.isoformat(), backend)) for backend in names]
        cells = [' / '.join(data_columns(*value)) if value is not None else '—' for value in values]
        upload = sum(value[0] for value in values if value is not None)
        download = sum(value[1] for value in values if value is not None)
        rows.append((day.strftime('%d.%m.%Y'), *cells, *data_columns(upload, download)))
    print('Значения по Backend: Upload / Download / Total\n')
    print_table(('ДАТА', *names, 'UPLOAD', 'DOWNLOAD', 'TOTAL'), rows, 1)


def list_backends(database, zone, names_only=False):
    rows = list(database.execute('SELECT * FROM backends ORDER BY name'))
    if names_only:
        for row in rows:
            print(row['name'])
    elif rows:
        print_table(('BACKEND', 'СОСТОЯНИЕ', 'В КОНФИГЕ', 'ВПЕРВЫЕ', 'ПОСЛЕДНИЙ ОПРОС'),
                    [(row['name'], row['last_status'], 'да' if row['is_active'] else 'нет',
                      local_time(row['first_seen'], zone), local_time(row['last_seen'], zone)) for row in rows], 5)
    else:
        print('Сборщик ещё не обнаружил ни одного Backend.')


def print_backend(database, name, month, today, zone):
    row = database.execute('SELECT * FROM backends WHERE name=?', (name,)).fetchone()
    if row is None:
        raise ValueError(f'Backend {name} ещё не обнаружен')
    first, last = month_dates(month or today.strftime('%Y-%m'))
    print_title(name, zone)
    print(f"Впервые: {local_time(row['first_seen'], zone)} · Состояние: {row['last_status']} · "
          f"В конфигурации: {'да' if row['is_active'] else 'нет'}\n")
    yesterday = today - timedelta(days=1)
    rows = []
    for label, start, end in (('Сегодня', today, today), ('Вчера', yesterday, yesterday),
                              (first.strftime('%Y-%m'), first, last), ('Вся история', date.min, date.max)):
        values = totals(database, start, end, name)
        rows.append((label, *(data_columns(*values[0][1:]) if values else ('—', '—', '—'))))
    print_table(('ПЕРИОД', 'UPLOAD', 'DOWNLOAD', 'TOTAL'), rows, 1)
    print()
    print_daily(database, first, last, name)


def print_recent(database, zone):
    rows = database.execute('''
        SELECT timestamp_end, backend, upload_bytes, download_bytes FROM traffic_intervals
        ORDER BY timestamp_end DESC, backend DESC LIMIT 50
    ''').fetchall()
    if rows:
        print_table(('КОНЕЦ ИНТЕРВАЛА', 'BACKEND', 'UPLOAD', 'DOWNLOAD', 'TOTAL'),
                    [(local_time(end, zone), name, *data_columns(upload, download))
                     for end, name, upload, download in rows], 2)
    else:
        print(NO_DATA)


def export_month(database, directory, first, last):
    rows = daily_rows(database, first, last)
    if not rows:
        print(NO_DATA)
        return
    with NamedTemporaryFile(mode='w', encoding='utf-8', newline='', delete=False, dir=directory,
                            prefix=f'traffic-{first:%Y-%m}-', suffix='.tmp') as output:
        candidate = Path(output.name)
        path = candidate.with_suffix('.csv')
        try:
            writer = csv.writer(output)
            writer.writerow(('date', 'backend', 'upload_bytes', 'download_bytes', 'total_bytes'))
            writer.writerows((day, name, upload, download, upload + download) for day, name, upload, download in rows)
            output.close()
            candidate.replace(path)
        finally:
            output.close()
            candidate.unlink(missing_ok=True)
    print(f'Отчёт сохранён: {path}')
