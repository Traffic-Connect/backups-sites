#!/bin/bash
# Скрипт установки зависимостей и команд для бэкапа WordPress и восстановления пользователей
# VERSION: 1.9

set -e

echo "=========================================="
echo "Установка системы бэкапа и восстановления"
echo "WordPress сайты + Полные бэкапы пользователей"
echo "=========================================="
echo ""

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
    echo "ОШИБКА: Скрипт должен быть запущен от root"
    exit 1
fi

# Установка jq
echo "[1/6] Установка jq..."
if command -v jq &> /dev/null; then
    echo "  jq уже установлен (версия $(jq --version))"
else
    apt install -y jq
    echo "  jq успешно установлен"
fi

# Установка unzip (нужен для AWS CLI)
echo "[2/6] Проверка unzip..."
if command -v unzip &> /dev/null; then
    echo "  unzip уже установлен"
else
    apt install -y unzip
    echo "  unzip успешно установлен"
fi

# Установка AWS CLI v2
echo "[3/6] Установка AWS CLI v2..."
if command -v aws &> /dev/null; then
    echo "  AWS CLI уже установлен (версия $(aws --version))"
else
    echo "  Скачивание AWS CLI v2..."
    cd /tmp
    curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip -q awscliv2.zip
    sudo ./aws/install
    rm -rf awscliv2.zip aws
    echo "  AWS CLI v2 успешно установлен"
fi

# Установка curl и git
echo "[4/6] Проверка curl и git..."
if command -v curl &> /dev/null; then
    echo "  curl уже установлен"
else
    apt install -y curl
    echo "  curl успешно установлен"
fi

if command -v git &> /dev/null; then
    echo "  git уже установлен"
else
    apt install -y git
    echo "  git успешно установлен"
fi

# Копирование скриптов
echo "[5/6] Копирование скриптов..."

# Сохраняем текущую директорию
CURRENT_DIR=$(pwd)

# Проверка существования файлов
if [ ! -f "$CURRENT_DIR/v-wp-backup-s3" ]; then
    echo "ОШИБКА: Файл v-wp-backup-s3 не найден в текущей директории"
    exit 1
fi

if [ ! -f "$CURRENT_DIR/v-check-file-exists" ]; then
    echo "ОШИБКА: Файл v-check-file-exists не найден в текущей директории"
    exit 1
fi

if [ ! -f "$CURRENT_DIR/v-wp-restore-s3" ]; then
    echo "ОШИБКА: Файл v-wp-restore-s3 не найден в текущей директории"
    exit 1
fi

if [ ! -f "$CURRENT_DIR/wp-backup-s3.sh" ]; then
    echo "ОШИБКА: Файл wp-backup-s3.sh не найден в текущей директории"
    exit 1
fi

if [ ! -f "$CURRENT_DIR/wp-restore-s3.sh" ]; then
    echo "ОШИБКА: Файл wp-restore-s3.sh не найден в текущей директории"
    exit 1
fi

if [ ! -f "$CURRENT_DIR/v-restore-user-s3" ]; then
    echo "ОШИБКА: Файл v-restore-user-s3 не найден в текущей директории"
    exit 1
fi

if [ ! -f "$CURRENT_DIR/restore-user-s3.sh" ]; then
    echo "ОШИБКА: Файл restore-user-s3.sh не найден в текущей директории"
    exit 1
fi

if [ ! -f "remove-domain.sh" ]; then
    echo "ОШИБКА: Файл remove-domain.sh не найден в текущей директории"
    exit 1
fi

# Копирование команды Hestia
if [ -f "/usr/local/hestia/bin/v-wp-backup-s3" ]; then
    echo "  v-wp-backup-s3 уже существует, перезаписываем..."
fi
cp "$CURRENT_DIR/v-wp-backup-s3" /usr/local/hestia/bin/
chmod +x /usr/local/hestia/bin/v-wp-backup-s3
echo "  v-wp-backup-s3 установлен в /usr/local/hestia/bin/"

# Копирование команды Hestia
if [ -f "/usr/local/hestia/bin/v-check-file-exists" ]; then
    echo "  v-check-file-exists уже существует, перезаписываем..."
fi
cp "$CURRENT_DIR/v-check-file-exists" /usr/local/hestia/bin/
chmod +x /usr/local/hestia/bin/v-check-file-exists
echo "  v-check-file-exists установлен в /usr/local/hestia/bin/"

# Копирование команды Hestia
if [ -f "/usr/local/hestia/bin/v-wp-restore-s3" ]; then
    echo "  v-wp-restore-s3 уже существует, перезаписываем..."
fi
cp "$CURRENT_DIR/v-wp-restore-s3" /usr/local/hestia/bin/
chmod +x /usr/local/hestia/bin/v-wp-restore-s3
echo "  v-wp-restore-s3 установлен в /usr/local/hestia/bin/"

# Копирование основного скрипта
if [ -f "/usr/local/bin/wp-backup-s3.sh" ]; then
    echo "  wp-backup-s3.sh уже существует, перезаписываем..."
fi
cp "$CURRENT_DIR/wp-backup-s3.sh" /usr/local/bin/
chmod +x /usr/local/bin/wp-backup-s3.sh
echo "  wp-backup-s3.sh установлен в /usr/local/bin/"

# Копирование основного скрипта
if [ -f "/usr/local/bin/wp-restore-s3.sh" ]; then
    echo "  wp-restore-s3.sh уже существует, перезаписываем..."
fi
cp "$CURRENT_DIR/wp-restore-s3.sh" /usr/local/bin/
chmod +x /usr/local/bin/wp-restore-s3.sh
echo "  wp-restore-s3.sh установлен в /usr/local/bin/"

# Копирование основного скрипта
if [ -f "/usr/local/bin/remove-domain.sh" ]; then
    echo "  remove-domain.sh уже существует, перезаписываем..."
fi
cp remove-domain.sh /usr/local/bin/
chmod +x /usr/local/bin/remove-domain.sh
echo "  remove-domain.sh установлен в /usr/local/bin/"

# Копирование команды Hestia для восстановления пользователя
if [ -f "/usr/local/hestia/bin/v-restore-user-s3" ]; then
    echo "  v-restore-user-s3 уже существует, перезаписываем..."
fi
cp "$CURRENT_DIR/v-restore-user-s3" /usr/local/hestia/bin/
chmod +x /usr/local/hestia/bin/v-restore-user-s3
echo "  v-restore-user-s3 установлен в /usr/local/hestia/bin/"

# Копирование основного скрипта восстановления пользователя
if [ -f "/usr/local/bin/restore-user-s3.sh" ]; then
    echo "  restore-user-s3.sh уже существует, перезаписываем..."
fi
cp "$CURRENT_DIR/restore-user-s3.sh" /usr/local/bin/
chmod +x /usr/local/bin/restore-user-s3.sh
echo "  restore-user-s3.sh установлен в /usr/local/bin/"

# Создание директории для бэкапов
mkdir -p /backup
echo "  Создана директория /backup"

# Настройка автоматического обновления
echo ""
echo "[6/6] Настройка автоматического обновления..."

AUTO_UPDATE_SCRIPT="/usr/local/bin/wp-backup-auto-update.sh"
REPO_URL="https://github.com/Traffic-Connect/backups-sites.git"
INSTALL_DIR="/root/backups"
VERSION_FILE="$INSTALL_DIR/.installed_version"
CRON_TIME="0 2 * * *"

# Создание скрипта автоматического обновления
cat > "$AUTO_UPDATE_SCRIPT" << 'SCRIPT_EOF'
#!/bin/bash
# Скрипт автоматического обновления системы бэкапа WordPress

set -e

REPO_URL="https://github.com/Traffic-Connect/backups-sites.git"
INSTALL_DIR="/root/backups"
VERSION_FILE="$INSTALL_DIR/.installed_version"
LOG_FILE="/var/log/wp-backup-auto-update.log"

# Функция логирования
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Функция получения версии из файла
get_version_from_file() {
    local file="$1"
    grep -oP '(?<=# Версия: )[0-9.]+' "$file" 2>/dev/null | head -1
}

# Функция установки
install_system() {
    log "Начало переустановки системы бэкапа..."

    cd "$INSTALL_DIR"

    if [ -f "install.sh" ]; then
        chmod +x install.sh
        # Запускаем установку без рекурсивного запуска автообновления
        SKIP_AUTO_UPDATE=1 ./install.sh >> "$LOG_FILE" 2>&1
        log "Установка завершена успешно"
    else
        log "ОШИБКА: Файл install.sh не найден"
        exit 1
    fi
}

# Основная логика
main() {
    log "=========================================="
    log "Проверка обновлений системы бэкапа WordPress"
    log "=========================================="

    # Создание директории если не существует
    if [ ! -d "$INSTALL_DIR" ]; then
        log "Создание директории $INSTALL_DIR"
        mkdir -p "$INSTALL_DIR"
        cd "$INSTALL_DIR"

        log "Клонирование репозитория..."
        git clone "$REPO_URL" .

        CURRENT_VERSION=$(get_version_from_file "install.sh")
        log "Клонирована версия: $CURRENT_VERSION"

        echo "$CURRENT_VERSION" > "$VERSION_FILE"

        install_system

        log "Первичная установка завершена"
        exit 0
    fi

    cd "$INSTALL_DIR"

    # Получаем текущую установленную версию
    if [ -f "$VERSION_FILE" ]; then
        INSTALLED_VERSION=$(cat "$VERSION_FILE")
        log "Установленная версия: $INSTALLED_VERSION"
    else
        INSTALLED_VERSION="0.0"
        log "Версия не определена, считаем 0.0"
    fi

    # Обновляем репозиторий
    log "Получение обновлений из репозитория..."
    git fetch origin
    git reset --hard origin/main

    # Получаем версию из обновленного install.sh
    REPO_VERSION=$(get_version_from_file "install.sh")
    log "Версия в репозитории: $REPO_VERSION"

    # Сравниваем версии
    if [ "$INSTALLED_VERSION" != "$REPO_VERSION" ]; then
        log "Обнаружена новая версия: $REPO_VERSION"
        log "Запуск обновления..."

        install_system

        echo "$REPO_VERSION" > "$VERSION_FILE"

        log "Обновление до версии $REPO_VERSION завершено"
    else
        log "Установлена актуальная версия $INSTALLED_VERSION"
    fi

    log "=========================================="
    log "Проверка завершена"
    log "=========================================="
}

# Запуск основной функции
main
SCRIPT_EOF

chmod +x "$AUTO_UPDATE_SCRIPT"
echo "  Скрипт автообновления создан: $AUTO_UPDATE_SCRIPT"

# Добавление задачи в cron (только если переменная SKIP_AUTO_UPDATE не установлена)
if [ -z "$SKIP_AUTO_UPDATE" ]; then
    CRON_JOB="$CRON_TIME $AUTO_UPDATE_SCRIPT"

    if crontab -l 2>/dev/null | grep -q "$AUTO_UPDATE_SCRIPT"; then
        echo "  Задача cron уже существует"
    else
        (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
        echo "  Задача cron добавлена: каждую ночь в 2:00"
    fi

    # Сохраняем текущую версию
    mkdir -p "$INSTALL_DIR"
    CURRENT_VERSION=$(grep -oP '(?<=# Версия: )[0-9.]+' "$0" | head -1)
    echo "$CURRENT_VERSION" > "$VERSION_FILE"
    echo "  Текущая версия сохранена: $CURRENT_VERSION"
fi

echo ""
echo "=========================================="
echo "Установка завершена успешно!"
echo "=========================================="
echo ""
echo "Установленные зависимости:"
echo "  - jq: $(jq --version)"
echo "  - AWS CLI: $(aws --version)"
echo "  - curl: $(curl --version | head -n1)"
echo "  - git: $(git --version)"
echo ""
echo "Установленные команды:"
echo "  - /usr/local/hestia/bin/v-wp-backup-s3"
echo "  - /usr/local/hestia/bin/v-wp-restore-s3"
echo "  - /usr/local/hestia/bin/v-restore-user-s3"
echo "  - /usr/local/hestia/bin/v-check-file-exists"
echo "  - /usr/local/bin/wp-backup-s3.sh"
echo "  - /usr/local/bin/wp-restore-s3.sh"
echo "  - /usr/local/bin/restore-user-s3.sh"
echo "  - /usr/local/bin/remove-domain.sh"
echo "  - /usr/local/bin/wp-backup-auto-update.sh"
echo ""
echo "Автоматическое обновление:"
echo "  - Скрипт: $AUTO_UPDATE_SCRIPT"
echo "  - Расписание: каждую ночь в 2:00"
echo "  - Лог: /var/log/wp-backup-auto-update.log"
echo ""
echo "Следующий шаг - настройка AWS CLI:"
echo "  aws configure"
echo ""
echo "Тестирование WordPress бэкапа:"
echo "  /usr/local/bin/wp-backup-s3.sh example.com"
echo ""
echo "Восстановление WordPress сайта:"
echo "  v-wp-restore-s3 example.com \"https://s3.example.com/backup.tar\" 42 17 true manager.example.com 24"
echo ""
echo "Восстановление полного бэкапа пользователя:"
echo "  v-restore-user-s3 \"https://s3.example.com/user.tar\" 42 manager.example.com 24"
echo ""
echo "Ручная проверка обновлений:"
echo "  /usr/local/bin/wp-backup-auto-update.sh"
echo ""
echo "Просмотр логов:"
echo "  tail -f /var/log/wp-backup-auto-update.log"
echo "  tail -f /backup_restore/schema_21/restore-user.log"
echo ""
