# Server Auto-Deploy Script
Scripts for basic server setup for your projects

Универсальный Bash-скрипт для быстрой базовой настройки нового VPS/VDS сервера (Debian/Ubuntu/RHEL). Автоматизирует рутину: от настройки SSH и безопасности до установки Docker и Nginx.

## Основные возможности

* **Security**: Смена порта SSH, установка Fail2Ban, универсальная настройка Firewall (UFW или Firewalld).
* **System**: Смена Hostname, настройка Timezone, отключение IPv6 (sysctl + GRUB), оптимизация логов `journald`.
* **Memory**: Интерактивная настройка Swap с выбором агрессивности (`swappiness`).
* **Basic software**: Интерактивная установка Docker, Nginx (с шаблонизацией конфигов), NVM, Certbot.

## Требования
1. **OS**: Debian 11+, Ubuntu 20.04+, RHEL 8+.
3. **Files**: Скрипт ищет рядом `firewall.conf` и `nginx_base.conf`.

## Как использовать

### 1. Подготовка файлов конфигурации

Отредактируйте `firewall.conf` для нужных вам правил.

```text
# формат: действие|направление|порт/протокол
allow|in|80/tcp
allow|in|443/tcp
a|in|3000/tcp

```

## Как пользоваться (с управляющей машины)
Если вы на **Windows**, используйте **Git Bash** (поставляется с Git) или PowerShell.

Чтобы не зависеть от имен папок, используйте команду, которая копирует только необходимые файлы
(`deploy.sh`, `firewall.conf`, `nginx_base.conf`) в корень пользователя root.

Мы скопируем файлы в папку `~/config/` на сервере.

```bash
# 1. Создаем папку на сервере и копируем файлы
ssh -p 22 root@IP_СЕРВЕРА "mkdir -p ~/config"
scp -P 22 deploy.sh firewall.conf nginx_base.conf root@IP_СЕРВЕРА:~/config/

# 2. Заходим на сервер и запускаем
ssh -p 22 root@IP_СЕРВЕРА
cd ~/config
chmod +x deploy.sh
./deploy.sh
```

## Структура файлов

* `deploy.sh` — основной исполняемый файл.
* `firewall.conf` — список правил доступа.
* `nginx_base.conf` — шаблон для создания новых сайтов.

---

**Внимание:** После работы скрипта и смены порта SSH, не забудьте подключаться по новому порту: `ssh -p 2222 root@ip`.
