# RemnaSuper

Интерактивная Bash-утилита для установки, обслуживания и диагностики
`RemnaNode` на Linux-сервере. RemnaSuper объединяет часто используемые
операции администратора в одном меню: управление Docker Compose, логами,
сетевыми обходами, geofiles, сертификатами, защитой SSH и диагностикой
доступности сервисов.

Утилита рассчитана на сервер, где уже установлен
[RemnaNode](https://github.com/remnawave/node). Она работает от `root` и
изменяет системные настройки, Docker Compose, systemd, cron и файлы
конфигурации. Перед изменяющими действиями меню показывает описание операции,
а перед изменением `docker-compose.yml` создаётся резервная копия.

> Текущая версия: `3.7`

## Содержание

- [Возможности](#возможности)
- [Требования](#требования)
- [Установка](#установка)
- [Запуск](#запуск)
- [Главное меню](#главное-меню)
- [Сетевые интеграции](#сетевые-интеграции)
- [Geofiles](#geofiles)
- [Логи и диагностика](#логи-и-диагностика)
- [Автообновление](#автообновление)
- [Пути и файлы](#пути-и-файлы)
- [Структура проекта](#структура-проекта)
- [Проверка изменений](#проверка-изменений)
- [Безопасность и ограничения](#безопасность-и-ограничения)

## Возможности

- Первичная настройка Debian/Ubuntu-подобного сервера:
  `apt update`, `apt upgrade`, установка `cron`, `mc` и `wget`.
- Установка официального `remnawave-reverse-proxy`.
- Смена порта взаимодействия RemnaNode с панелью с обновлением UFW-правила.
- Подключение сертификатов из `remnawave-nginx` к `RemnaNode`.
- Установка и настройка `fail2ban` для SSH.
- Исправление и подключение логов RemnaNode с настройкой `logrotate`.
- Управление [ss-zapret2](https://github.com/vernette/ss-zapret2):
  установка, поиск стратегии через `blockcheck2`, ручная настройка и удаление.
- Управление Tor:
  локальный SOCKS5, смена цепочки через `NEWNYM` и готовый Xray outbound.
- Управление Psiphon через
  [vps-psiphon](https://github.com/Chara-Freedom/vps-psiphon):
  установка, регионы, ротация выхода, watchdog, логи и outbound.
- Установка geosite/geoip-файлов из наборов Loyalsoldier и xray-routing
  с ежедневным обновлением через cron.
- Управление [Node Accelerator](https://github.com/jestivald/node-accelerator):
  оптимизация, защита, диагностика и CLI-отчёты.
- Встроенная проверка доступности Discord, YouTube, Telegram и Instagram.
- Просмотр ошибок и access-логов Xray.
- Дополнительные диагностические команды `ipregion`, `IP Check Place` и
  `bench.sh`.
- Автоматическое обновление самой RemnaSuper из GitHub.

## Требования

### Базовые

- Linux-сервер Debian/Ubuntu или совместимый дистрибутив.
- Bash.
- Доступ `root` или возможность запускать команды через `sudo`.
- Для установки RemnaSuper: `curl` и `tar`.
- Доступ к GitHub и внешним URL, которые используются выбранными модулями.

### Для управления RemnaNode

- Установленный RemnaNode в `/opt/remnanode`.
- Файл Compose: `/opt/remnanode/docker-compose.yml`.
- Docker с Compose plugin (`docker compose`).
- Для агента RemnaNode: `/opt/remnawave-node-agent`.
- Для системных операций: `systemd`, `apt-get`, `cron`.

Не все зависимости нужны одновременно. Например, Docker необходим для
перезапуска RemnaNode, geofiles, ss-zapret2 и Psiphon, а `systemd` нужен для
Tor, Psiphon и fail2ban.

## Установка

### Быстрая установка

Команда скачивает актуальную ветку `main`, устанавливает RemnaSuper в
`/opt/RemnaSuper`, создаёт ссылку `/usr/local/bin/rs` и запускает меню:

```bash
curl -fsSL https://raw.githubusercontent.com/SP1K33/RemnaSuper/main/install.sh \
  | sudo bash && sudo rs
```

После установки запуск из любой директории:

```bash
sudo rs
```

### Установка отдельными шагами

Если нужно сначала посмотреть установщик, используйте раздельный запуск:

```bash
curl -fsSL https://raw.githubusercontent.com/SP1K33/RemnaSuper/main/install.sh \
  -o /tmp/remnasuper-install.sh
sudo bash /tmp/remnasuper-install.sh
sudo rs
```

Установщик проверяет обязательные файлы архива, сохраняет нестандартный объект
по пути `/opt/RemnaSuper` с суффиксом `.legacy.*`, если он не является
каталогом, и устанавливает:

- `/opt/RemnaSuper/RemnaSuper`;
- `/opt/RemnaSuper/VERSION`;
- `/opt/RemnaSuper/lib`;
- `/opt/RemnaSuper/install.sh`;
- `/opt/RemnaSuper/README.md`;
- симлинк `/usr/local/bin/rs`.

### Установка из другой ветки

И установщик, и автообновление поддерживают ветку через
`REMNASUPER_BRANCH`:

```bash
curl -fsSL https://raw.githubusercontent.com/SP1K33/RemnaSuper/main/install.sh \
  | sudo REMNASUPER_BRANCH=dev bash
```

## Запуск

RemnaSuper должна запускаться от `root`:

```bash
sudo rs
```

Для локальной отладки без проверки обновлений:

```bash
sudo REMNASUPER_SKIP_UPDATE=1 rs
```

Значение `REMNASUPER_SKIP_UPDATE=1` отключает только проверку версии
RemnaSuper. Действия самого меню по-прежнему могут менять систему.

## Главное меню

### Первоначальная настройка

| Пункт | Действие |
| --- | --- |
| `1` | `apt-get update`, `apt-get upgrade`, установка `cron`, `mc`, `wget` |
| `2` | Установка `remnawave-reverse-proxy` из `eGamesAPI/remnawave-reverse-proxy` |
| `3` | Подключение сертификатов из `remnawave-nginx` к RemnaNode |
| `4` | Подменю Node Accelerator |
| `5` | Установка `fail2ban` с защитой SSH |
| `6` | Создание и подключение `access.log`/`error.log`, перезапуск сервисов и `logrotate` |
| `7` | Смена порта взаимодействия с панелью; пустой ввод выбирает свободный случайный порт |

### Управление

| Пункт | Действие |
| --- | --- |
| `8` | Подменю ss-zapret2 |
| `9` | Подменю Tor |
| `10` | Подменю Psiphon |
| `11` | Проверка доступности Discord, YouTube, Telegram и Instagram |
| `12` | Установка и удаление geofiles |
| `13` | Перезапуск контейнеров RemnaNode |
| `14` | Перезапуск контейнеров node-agent |

### Диагностика

| Пункт | Действие |
| --- | --- |
| `15` | Запуск внешнего скрипта `ipregion` |
| `16` | Запуск `IP Check Place` |
| `17` | Проверка канала через `bench.sh` |
| `18` | Просмотр `/var/log/supervisor/xray.out.log` в контейнере `remnanode` |
| `19` | Просмотр `/var/log/remnanode/access.log` в реальном времени |

Во всех подменю `0` возвращает на предыдущий уровень, а в главном меню
завершает работу программы.

## Сетевые интеграции

### ss-zapret2

Меню ss-zapret2 устанавливает и обновляет репозиторий
`vernette/ss-zapret2` в `/opt/ss-zapret2`, создаёт защищённый `.env` и
запускает Docker-контейнер `zapret2-proxy`.

Доступны следующие операции:

- установка и проверка локального SOCKS5;
- интерактивный поиск стратегии через `blockcheck2`;
- автоматическая запись найденных параметров в `NFQWS2_OPT`;
- просмотр текущей стратегии;
- ручное редактирование стратегии с проверкой и резервной копией;
- автоматический откат предыдущей конфигурации, если новая стратегия не
  запускается;
- полное удаление контейнера, образа, настроек и outbound.

По умолчанию SOCKS5 создаётся на `127.0.0.1:1080`, Shadowsocks-сервис
использует порт `8388`, а готовый outbound сохраняется в:

```text
/opt/ss-zapret2/xray-outbound.json
```

Его тег: `zapret`.

Для работы локального прокси из контейнера RemnaNode нода должна использовать
`network_mode: host`. Установка проверяет это требование и останавливается,
если оно не выполнено.

### Tor

Меню Tor:

- устанавливает Tor и необходимые системные пакеты;
- настраивает SOCKS5 только на `127.0.0.1:9050`;
- включает ControlPort только на `127.0.0.1:9051` с cookie-аутентификацией;
- проверяет выходной IP через Tor;
- создаёт JSON outbound для Xray;
- отправляет `SIGNAL NEWNYM` для запроса новой цепочки;
- удаляет только настройки и пакеты, которыми управляла RemnaSuper.

Outbound сохраняется в:

```text
/opt/remnasuper-tor/xray-outbound.json
```

Его тег: `tor`.

Важно:

- RemnaNode должна работать с `network_mode: host`, чтобы контейнер видел
  SOCKS5 на localhost.
- Этот outbound рассчитан на TCP-трафик. UDP через SOCKS5 Tor не
  поддерживается.
- `NEWNYM` не гарантирует новый IP при каждом запросе: Tor может выбрать тот
  же выходной узел.

### Psiphon

Psiphon устанавливается через актуальный установщик проекта
`Chara-Freedom/vps-psiphon` с флагом `--no-http`. В результате используются
Docker, systemd-сервис и watchdog, а наружу публикуется только SOCKS5 на
приватном адресе хоста.

Меню поддерживает:

- установку, переустановку и полное удаление выбранного подключения;
- несколько одновременных подключений на одной VPS: для каждого создаются отдельные
  контейнер, сервис systemd, watchdog, настройки, SOCKS5-порт и Xray outbound;
- выбор экземпляра для просмотра состояния, ротации, изменения регионов, проверки
  скорости и просмотра логов;
- просмотр состояния контейнера, systemd, watchdog, региона и выходного IP;
- ротацию туннеля;
- выбор фиксированного региона или `auto`;
- настройку пула регионов для последовательной ротации;
- настройку допустимых стран для watchdog;
- тест скорости;
- просмотр логов клиента и watchdog;
- генерацию актуального Xray outbound.

Первый outbound сохраняется в:

```text
/opt/vps-psiphon/xray-outbound.json
```

Его тег: `psiphon-out`.

Подключения устанавливаются через пункт **Добавить подключение**; установщик
поддерживает номера 1–99. Для дополнительных экземпляров используется тег вида
`psiphon-out-2` и далее, а файлы сохраняются в `/opt/vps-psiphon-N/`. После установки
добавьте outbound каждого нужного подключения в конфигурацию Xray и настройте
маршрутизацию на его тег. Удаление из меню затрагивает только выбранный экземпляр.

Как и Tor, Psiphon-outbound предназначен для TCP-трафика. Ротация или смена
региона может прервать текущие соединения примерно на 45 секунд. Проверка
скорости скачивает около 250 МБ тестовых данных.

## Geofiles

В меню **Geofiles** доступны два источника:

- `Loyalsoldier/v2ray-rules-dat`;
- `Davoyan/xray-routing`.

Для каждого источника скачиваются `geosite.dat` и `geoip.dat`, файлы
сохраняются в `/opt/remnanode/geofiles` и подключаются в контейнер RemnaNode
через volumes:

```text
/usr/local/bin/<provider>-geosite.dat
/usr/local/bin/<provider>-geoip.dat
```

После установки для каждого файла создаётся безопасное ежедневное обновление
через cron в `00:00`. Новый файл скачивается во временный путь, проверяется на
непустое содержимое и только затем заменяет текущий. При ошибке существующий
файл сохраняется.

Перед изменением `docker-compose.yml` создаётся файл вида:

```text
/opt/remnanode/docker-compose.yml.bak.YYYY-MM-DD_HHMMSS
```

При удалении набора RemnaSuper удаляет его файлы, volumes и связанные задания
cron.

## Логи и диагностика

### Логи RemnaNode

Пункт **Исправить логи RemnaNode**:

1. создаёт `/var/log/remnanode/access.log` и `error.log`;
2. подключает каталог к сервису `remnanode`;
3. перезапускает RemnaNode и node-agent;
4. проверяет, начал ли заполняться `access.log`;
5. предлагает профиль `logrotate`.

Доступны профили ротации:

- малая нода: ежедневно, хранить 7 дней;
- средняя нода: ежедневно, хранить 3 дня;
- высокая нагрузка: ротация `access.log` после 100 МБ, хранить 5 архивов;
- ручное редактирование конфига через `nano`.

Конфигурация хранится в:

```text
/etc/logrotate.d/remnanode
```

### Встроенная проверка доступности

Проверка выполняется без скачивания сторонних скриптов и показывает для
Discord, YouTube, Telegram и Instagram:

- DNS IPv4 и IPv6;
- ICMP-пинг и потери пакетов;
- HTTP-код и версию HTTP;
- результат проверки TLS-сертификата;
- локальный и удалённый IP/порт;
- конечный URL после перенаправлений;
- задержки DNS, TCP, TLS, TTFB и общее время;
- объём полученных данных и скорость загрузки.

Проверка намеренно игнорирует переменные HTTP-прокси и выполняет запросы
напрямую. Отсутствие ICMP-ответа само по себе не означает, что HTTPS
недоступен.

### Node Accelerator

RemnaSuper запускает upstream-установщик
[Node Accelerator](https://github.com/jestivald/node-accelerator) и не
дублирует его код.

Доступны модули:

- `optimize`: XanMod, BBRv3, sysctl, лимиты, RPS/RFS/XPS, swap и настройка
  сетевого интерфейса;
- `protect`: nftables, защита от сканирования и флуда, CrowdSec и
  автоопределение порта node-agent;
- `diagnose`: read-only проверка ядра, BBR, sysctl, лимитов, conntrack, NIC,
  firewall, CrowdSec, портов и RemnaNode;
- `persist`: установка/обновление read-only CLI `na-diagnose` и `na-report`.

Модули `optimize` и `protect` меняют системные настройки. После установки
XanMod может потребоваться перезагрузка. Перед применением firewall проверьте
порты и whitelist, чтобы не потерять SSH-доступ.

## Автообновление

При запуске RemnaSuper:

1. читает локальную версию из `VERSION`;
2. получает `VERSION` из выбранной ветки GitHub;
3. сравнивает версии через `sort -V`;
4. при наличии более новой версии скачивает архив и обновляет
   `/opt/RemnaSuper`;
5. автоматически перезапускает `rs`.

Если GitHub временно недоступен, RemnaSuper сообщает об ошибке проверки и
продолжает запуск. Проверку можно отключить на один запуск:

```bash
sudo REMNASUPER_SKIP_UPDATE=1 rs
```

Автообновление изменяет только файлы самой RemnaSuper. Конфигурации
RemnaNode, Docker, Tor, Psiphon и ss-zapret2 находятся за пределами каталога
`/opt/RemnaSuper` и не заменяются механизмом обновления.

## Пути и файлы

| Назначение | Путь |
| --- | --- |
| Установка RemnaSuper | `/opt/RemnaSuper` |
| Команда запуска | `/usr/local/bin/rs` |
| RemnaNode | `/opt/remnanode` |
| Compose RemnaNode | `/opt/remnanode/docker-compose.yml` |
| Node-agent | `/opt/remnawave-node-agent` |
| Логи RemnaNode | `/var/log/remnanode` |
| Конфигурация logrotate | `/etc/logrotate.d/remnanode` |
| ss-zapret2 | `/opt/ss-zapret2` |
| Tor-интеграция | `/opt/remnasuper-tor` |
| Psiphon | `/opt/vps-psiphon` |
| Geofiles | `/opt/remnanode/geofiles` |

## Структура проекта

```text
RemnaSuper
├── RemnaSuper             # точка входа и порядок загрузки модулей
├── install.sh             # установка из архива GitHub
├── VERSION                # версия для автообновления
├── lib
│   ├── config.sh          # пути, версии и URL
│   ├── common.sh          # общие проверки, Compose и бэкапы
│   ├── ui.sh              # вывод и элементы меню
│   ├── update.sh          # проверка и установка обновлений
│   ├── logs.sh            # загрузчик модулей логов
│   ├── system.sh          # загрузчик системных модулей
│   ├── geofiles.sh        # загрузчик geofiles
│   ├── menu.sh            # загрузчик меню
│   ├── logs/              # логи, logrotate и очистка
│   ├── system/            # сервисы, диагностика, Tor, Psiphon и zapret
│   ├── geofiles/          # скачивание, cron и volumes
│   └── menu/              # главное меню и подменю
└── icons/                 # графические материалы проекта
```

Все модули из `lib/` подключаются через `source` из одной точки входа. Их
не следует запускать как отдельные программы.

## Проверка изменений

В репозитории нет автоматических тестов и CI. Перед отправкой изменений
проверьте синтаксис всех отслеживаемых Bash-файлов:

```bash
set -e
while IFS= read -r -d '' file; do
  case "$file" in
    RemnaSuper|*.sh) bash -n "$file" ;;
  esac
done < <(git ls-files -z)
```

Если установлен ShellCheck:

```bash
find lib -type f -name '*.sh' -print0 \
  | xargs -0 shellcheck RemnaSuper install.sh
```

Полный запуск `sudo ./RemnaSuper` не является безопасным smoke-тестом:
программа проверяет обновления, а пункты меню изменяют реальный сервер. Для
интеграционных проверок используйте одноразовую Debian/Ubuntu VM или
тестовый сервер.

## Безопасность и ограничения

- Запускайте RemnaSuper только на сервере, которым вы управляете.
- Перед изменением Compose сохраняйте и просматривайте созданный `.bak`.
- Установка `remnawave-reverse-proxy`, Node Accelerator, `ipregion`,
  `IP Check Place`, `bench.sh`, Psiphon и ss-zapret2 скачивает код из
  внешних репозиториев или URL. Ознакомьтесь с upstream-проектами перед
  запуском.
- `Node Accelerator` может изменить ядро, sysctl, firewall, лимиты и
  сетевые параметры.
- Установка `fail2ban` записывает `/etc/fail2ban/jail.d/local.conf` с
  параметрами SSH: 4 попытки за 10 минут и бан на 1 час.
- Перезапуск RemnaNode обычно прерывает подключения примерно на 5–10 секунд.
- Ротация или смена региона Psiphon может прервать соединения примерно на
  45 секунд.
- Tor и Psiphon outbound используют локальный SOCKS5 и предназначены только
  для TCP-трафика; UDP через эти outbound не поддерживается.
- Для локальных конфигураций с секретами применяются ограниченные права,
  например `/opt/ss-zapret2/.env` имеет режим `0600`.
- Не запускайте `lib/*.sh` напрямую и не используйте рабочий сервер для
  экспериментов с сетевыми стратегиями или firewall.

## Связанные проекты

- [RemnaNode](https://github.com/remnawave/node)
- [ss-zapret2](https://github.com/vernette/ss-zapret2)
- [vps-psiphon](https://github.com/Chara-Freedom/vps-psiphon)
- [Node Accelerator](https://github.com/jestivald/node-accelerator)
- [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat)
- [xray-routing](https://github.com/Davoyan/xray-routing)
