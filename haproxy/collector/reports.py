import calendar
import csv
import re
from datetime import date, datetime, timedelta
from pathlib import Path
from tempfile import NamedTemporaryFile


NO_DATA = 'Нет данных для отчёта за выбранный период.'
SPEED_HEADER = 'СР. Мбит/с'
TRAFFIC_HEADERS = ('UPLOAD', 'DOWNLOAD', 'TOTAL', SPEED_HEADER)


class ReportOutput:
    def __init__(self, structured=False):
        self.structured = structured
        self.sections = []

    def text(self, value=''):
        if self.structured:
            if value:
                self.sections.append({'text': value})
        else:
            print(value)

    def table(self, headers, rows, right_from):
        if self.structured:
            self.sections.append({'headers': headers, 'rows': list(rows), 'right_from': right_from})
        else:
            print_table(headers, rows, right_from)


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


def average_speed(upload, download, seconds):
    if not seconds:
        return '—'
    return f'{(upload + download) * 8 / (seconds * 1_000_000):.2f}'


def data_columns(upload, download, seconds):
    return size(upload), size(download), size(upload + download), average_speed(upload, download, seconds)


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


def print_title(label, zone, output=None):
    (output or ReportOutput()).text(f'Статистика трафика\n{label}\nЧасовой пояс: {zone}\n')


def traffic_rows(database, first, last, *, name=None, daily=False, include_total=False):
    columns = 'report_date, backend' if daily else 'backend'
    where = 'report_date BETWEEN ? AND ?'
    params = [first.isoformat(), last.isoformat()]
    if name is not None:
        where += ' AND backend=?'
        params.append(name)
    query = f'''SELECT {columns}, SUM(upload_bytes), SUM(download_bytes),
                       SUM(timestamp_end - timestamp_start)
                FROM traffic_intervals WHERE {where} GROUP BY {columns}'''
    if include_total:
        day_column = 'report_date, ' if daily else ''
        grouping = 'GROUP BY report_date' if daily else 'HAVING COUNT(*) > 0'
        query += f'''
            UNION ALL
            SELECT {day_column}NULL AS backend, SUM(upload), SUM(download), SUM(seconds)
            FROM (
                SELECT report_date, SUM(upload_bytes) AS upload, SUM(download_bytes) AS download,
                       MAX(timestamp_end - timestamp_start) AS seconds
                FROM traffic_intervals WHERE {where}
                GROUP BY report_date, timestamp_end
            ) {grouping}'''
        params *= 2
    return list(database.execute(query + f' ORDER BY {columns}', params))


def print_totals(database, first, last, output=None):
    output = output or ReportOutput()
    rows = traffic_rows(database, first, last, include_total=True)
    if not rows:
        output.text(NO_DATA)
        return
    total, *backends = rows
    report = [(name, *data_columns(*values)) for name, *values in backends]
    report.append(('ИТОГО', *data_columns(*total[1:])))
    output.table(('BACKEND', *TRAFFIC_HEADERS), report, 1)


def print_daily(database, first, last, name=None, output=None):
    output = output or ReportOutput()
    samples = traffic_rows(database, first, last, name=name, daily=True, include_total=name is None)
    if not samples:
        output.text(NO_DATA)
        return
    names = sorted({row[1] for row in samples if row[1] is not None})
    data = {(day, backend): values for day, backend, *values in samples}
    rows = []
    for offset in range((last - first).days + 1):
        day = first + timedelta(days=offset)
        key = day.isoformat()
        values = [data.get((key, backend)) for backend in names]
        cells = [' / '.join(data_columns(*value)) if value is not None else '—' for value in values]
        rows.append((day.strftime('%d.%m.%Y'), *cells, *data_columns(*data.get((key, name), (0, 0, 0)))))
    output.text('Значения по Backend: Upload / Download / Total / средняя скорость в Мбит/с\n')
    output.table(('ДАТА', *names, *TRAFFIC_HEADERS), rows, 1)


def list_backends(database, zone, names_only=False, output=None):
    output = output or ReportOutput()
    if names_only:
        for (name,) in database.execute('SELECT name FROM backends ORDER BY name'):
            output.text(name)
        return
    rows = list(database.execute('''
        SELECT b.*, t.upload_bytes, t.download_bytes, t.timestamp_end - t.timestamp_start AS seconds
        FROM backends b LEFT JOIN traffic_intervals t ON t.backend = b.name AND t.timestamp_end = b.last_seen
        ORDER BY b.name
    '''))
    if rows:
        output.table(('BACKEND', 'СОСТОЯНИЕ', 'В КОНФИГЕ', 'ВПЕРВЫЕ', 'ПОСЛЕДНИЙ ОПРОС', SPEED_HEADER),
                    [(row['name'], row['last_status'], 'да' if row['is_active'] else 'нет',
                      local_time(row['first_seen'], zone), local_time(row['last_seen'], zone),
                      average_speed(row['upload_bytes'], row['download_bytes'], row['seconds'])) for row in rows], 5)
    else:
        output.text('Сборщик ещё не обнаружил ни одного Backend.')


def print_backend(database, name, month, today, zone, output=None):
    output = output or ReportOutput()
    row = database.execute('SELECT * FROM backends WHERE name=?', (name,)).fetchone()
    if row is None:
        raise ValueError(f'Backend {name} ещё не обнаружен')
    first, last = month_dates(month or today.strftime('%Y-%m'))
    print_title(name, zone, output)
    output.text(f"Впервые: {local_time(row['first_seen'], zone)} · Состояние: {row['last_status']} · "
                f"В конфигурации: {'да' if row['is_active'] else 'нет'}\n")
    yesterday = today - timedelta(days=1)
    rows = []
    for label, start, end in (('Сегодня', today, today), ('Вчера', yesterday, yesterday),
                              (first.strftime('%Y-%m'), first, last), ('Вся история', date.min, date.max)):
        values = traffic_rows(database, start, end, name=name)
        rows.append((label, *(data_columns(*values[0][1:]) if values else ('—',) * len(TRAFFIC_HEADERS))))
    output.table(('ПЕРИОД', *TRAFFIC_HEADERS), rows, 1)
    output.text()
    print_daily(database, first, last, name, output)


def print_recent(database, zone, output=None):
    output = output or ReportOutput()
    rows = database.execute('''
        SELECT timestamp_end, backend, upload_bytes, download_bytes, timestamp_end - timestamp_start
        FROM traffic_intervals
        ORDER BY timestamp_end DESC, backend DESC LIMIT 50
    ''').fetchall()
    if rows:
        output.table(('КОНЕЦ ИНТЕРВАЛА', 'BACKEND', *TRAFFIC_HEADERS),
                    [(local_time(end, zone), name, *data_columns(*values)) for end, name, *values in rows], 2)
    else:
        output.text(NO_DATA)


def last_poll_speed(database, timestamp):
    values = database.execute('''
        SELECT SUM(upload_bytes), SUM(download_bytes), MAX(timestamp_end - timestamp_start)
        FROM traffic_intervals WHERE timestamp_end = ?
    ''', (timestamp,)).fetchone()
    return average_speed(*values)


def export_month(database, directory, first, last):
    rows = traffic_rows(database, first, last, daily=True)
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
            writer.writerows((day, name, upload, download, upload + download)
                             for day, name, upload, download, _ in rows)
            output.close()
            candidate.replace(path)
        finally:
            output.close()
            candidate.unlink(missing_ok=True)
    print(f'Отчёт сохранён: {path}')
