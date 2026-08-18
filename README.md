# RemnaSuper

Интерактивное меню для обслуживания RemnaNode: логи, logrotate, geofiles, перезапуск сервисов и вспомогательные команды.

В меню Tor доступны установка локального SOCKS5-прокси, быстрая смена выходного IP командой `NEWNYM`, готовый outbound с тегом `tor` для Xray и безопасное удаление интеграции. Tor слушает только `127.0.0.1`, поэтому для использования outbound контейнер RemnaNode должен работать с `network_mode: host`. Через Tor передаётся только TCP-трафик; UDP этим outbound не поддерживается.

Встроенная диагностика доступности проверяет Discord, YouTube, Telegram и Instagram без сторонних скриптов: показывает DNS-адреса, ICMP-пинг, HTTP-статус, сетевой маршрут запроса и задержки DNS/TCP/TLS/TTFB.

## Установка и запуск

Одна команда скачает актуальную версию из GitHub, установит файлы в `/opt/RemnaSuper`, создаст команду `/usr/local/bin/rs` и сразу запустит меню:

```bash
curl -fsSL https://raw.githubusercontent.com/SP1K33/RemnaSuper/main/install.sh | sudo bash && sudo rs
```

После установки запуск доступен из любой директории:

```bash
sudo rs
```

## Версия и автообновление

Текущая версия хранится в файле `VERSION`. При каждом запуске RemnaSuper проверяет `VERSION` в репозитории `https://github.com/SP1K33/RemnaSuper`. Если в GitHub версия новее, скрипт автоматически обновляет файлы в `/opt/RemnaSuper`, сообщает об этом и перезапускается.

Для временного отключения проверки:

```bash
sudo REMNASUPER_SKIP_UPDATE=1 rs
```
