#!/bin/bash
# Скрипт установки зависимостей и команд для бэкапа WordPress
# Версия: 1.0

set -e

echo "=========================================="
echo "Установка зависимостей для бэкапа WordPress"
echo "=========================================="
echo ""

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
    echo "ОШИБКА: Скрипт должен быть запущен от root"
    exit 1
fi

# Установка jq
echo "[1/5] Установка jq..."
if command -v jq &> /dev/null; then
    echo "  jq уже установлен (версия $(jq --version))"
else
    apt install -y jq
    echo "  jq успешно установлен"
fi

# Установка unzip (нужен для AWS CLI)
echo "[2/5] Проверка unzip..."
if command -v unzip &> /dev/null; then
    echo "  unzip уже установлен"
else
    apt install -y unzip
    echo "  unzip успешно установлен"
fi

# Установка AWS CLI v2
echo "[3/5] Установка AWS CLI v2..."
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

# Установка curl (если не установлен)
echo "[4/5] Проверка curl..."
if command -v curl &> /dev/null; then
    echo "  curl уже установлен"
else
    apt install -y curl
    echo "  curl успешно установлен"
fi

# Копирование скриптов
echo "[5/5] Копирование скриптов..."

# Возврат в исходную директорию
cd - > /dev/null

# Проверка существования файлов
if [ ! -f "v-wp-backup-s3" ]; then
    echo "ОШИБКА: Файл v-wp-backup-s3 не найден в текущей директории"
    exit 1
fi

if [ ! -f "v-check-file-exists" ]; then
    echo "ОШИБКА: Файл v-check-file-exists не найден в текущей директории"
    exit 1
fi

if [ ! -f "v-wp-restore-s3" ]; then
    echo "ОШИБКА: Файл v-wp-restore-s3 не найден в текущей директории"
    exit 1
fi

if [ ! -f "wp-backup-s3.sh" ]; then
    echo "ОШИБКА: Файл wp-backup-s3.sh не найден в текущей директории"
    exit 1
fi

if [ ! -f "wp-restore-s3.sh" ]; then
    echo "ОШИБКА: Файл wp-restore-s3.sh не найден в текущей директории"
    exit 1
fi

# Копирование команды Hestia
if [ -f "/usr/local/hestia/bin/v-wp-backup-s3" ]; then
    echo "  v-wp-backup-s3 уже существует, перезаписываем..."
fi
cp v-wp-backup-s3 /usr/local/hestia/bin/
chmod +x /usr/local/hestia/bin/v-wp-backup-s3
echo "  v-wp-backup-s3 установлен в /usr/local/hestia/bin/"

# Копирование команды Hestia
if [ -f "/usr/local/hestia/bin/v-check-file-exists" ]; then
    echo "  v-check-file-exists уже существует, перезаписываем..."
fi
cp v-check-file-exists /usr/local/hestia/bin/
chmod +x /usr/local/hestia/bin/v-check-file-exists
echo "  v-check-file-exists установлен в /usr/local/hestia/bin/"

# Копирование команды Hestia
if [ -f "/usr/local/hestia/bin/v-wp-restore-s3" ]; then
    echo "  v-wp-restore-s3 уже существует, перезаписываем..."
fi
cp v-wp-restore-s3 /usr/local/hestia/bin/
chmod +x /usr/local/hestia/bin/v-wp-restore-s3
echo "  v-wp-restore-s3 установлен в /usr/local/hestia/bin/"

# Копирование основного скрипта
if [ -f "/usr/local/bin/wp-backup-s3.sh" ]; then
    echo "  wp-backup-s3.sh уже существует, перезаписываем..."
fi
cp wp-backup-s3.sh /usr/local/bin/
chmod +x /usr/local/bin/wp-backup-s3.sh
echo "  wp-backup-s3.sh установлен в /usr/local/bin/"

# Копирование основного скрипта
if [ -f "/usr/local/bin/wp-restore-s3.sh" ]; then
    echo "  wp-restore-s3.sh уже существует, перезаписываем..."
fi
cp wp-restore-s3.sh /usr/local/bin/
chmod +x /usr/local/bin/wp-restore-s3.sh
echo "  wp-restore-s3.sh установлен в /usr/local/bin/"

# Создание директории для бэкапов
mkdir -p /backup
echo "  Создана директория /backup"

echo ""
echo "=========================================="
echo "Установка завершена успешно!"
echo "=========================================="
echo ""
echo "Установленные зависимости:"
echo "  - jq: $(jq --version)"
echo "  - AWS CLI: $(aws --version)"
echo "  - curl: $(curl --version | head -n1)"
echo ""
echo "Установленные команды:"
echo "  - /usr/local/hestia/bin/v-wp-backup-s3"
echo "  - /usr/local/hestia/bin/v-wp-restore-s3"
echo "  - /usr/local/hestia/bin/v-check-file-exists"
echo "  - /usr/local/bin/wp-backup-s3.sh"
echo "  - /usr/local/bin/wp-restore-s3.sh"
echo ""
echo "Следующий шаг - настройка AWS CLI:"
echo "  aws configure"
echo ""
echo "Тестирование:"
echo "  /usr/local/bin/wp-backup-s3.sh example.com"
echo ""