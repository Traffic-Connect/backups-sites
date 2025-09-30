#!/bin/bash
# Скрипт установки зависимостей и команд для бэкапа WordPress

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

# Обновление списка пакетов
echo "[1/5] Обновление списка пакетов..."
apt update -qq

# Установка jq
echo "[2/5] Установка jq..."
if command -v jq &> /dev/null; then
    echo "  jq уже установлен (версия $(jq --version))"
else
    apt install -y jq
    echo "  jq успешно установлен"
fi

# Установка AWS CLI
echo "[3/5] Установка AWS CLI..."
if command -v aws &> /dev/null; then
    echo "  AWS CLI уже установлен (версия $(aws --version))"
else
    apt install -y awscli
    echo "  AWS CLI успешно установлен"
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

# Проверка существования файлов
if [ ! -f "v-wp-backup-s3" ]; then
    echo "ОШИБКА: Файл v-wp-backup-s3 не найден в текущей директории"
    exit 1
fi

if [ ! -f "wp-backup-s3.sh" ]; then
    echo "ОШИБКА: Файл wp-backup-s3.sh не найден в текущей директории"
    exit 1
fi

# Копирование команды Hestia
cp v-wp-backup-s3 /usr/local/hestia/bin/
chmod +x /usr/local/hestia/bin/v-wp-backup-s3
echo "  v-wp-backup-s3 скопирован в /usr/local/hestia/bin/"

# Копирование основного скрипта
cp wp-backup-s3.sh /usr/local/bin/
chmod +x /usr/local/bin/wp-backup-s3.sh
echo "  wp-backup-s3.sh скопирован в /usr/local/bin/"

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
echo "  - AWS CLI: $(aws --version | cut -d' ' -f1)"
echo "  - curl: $(curl --version | head -n1)"
echo ""
echo "Установленные команды:"
echo "  - /usr/local/hestia/bin/v-wp-backup-s3"
echo "  - /usr/local/bin/wp-backup-s3.sh"
echo ""
echo "Тестирование:"
echo "  /usr/local/bin/wp-backup-s3.sh example.com"
echo ""