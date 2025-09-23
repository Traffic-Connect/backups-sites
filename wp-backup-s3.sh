#!/bin/bash
# Бэкап WordPress-сайта (по домену) + загрузка в S3

# === ПРОВЕРКА АРГУМЕНТА ===
if [ -z "$1" ]; then
    echo "❌ Использование: $0 domain.tld"
    exit 1
fi

DOMAIN="$1"

# Сначала пытаемся через Hestia
USER=$(v-search-domain "$DOMAIN" plain 2>/dev/null | awk '{print $2}')

# Если не нашли, пробуем по каталогам
if [ -z "$USER" ]; then
    for user_dir in /home/*/; do
        if [ -d "${user_dir}web/${DOMAIN}/public_html" ]; then
            USER=$(basename "$user_dir")
            break
        fi
    done
fi

if [ -z "$USER" ]; then
    echo "❌ Не удалось определить пользователя для домена $DOMAIN"
    exit 1
fi

# === НАСТРОЙКИ ===
WP_PATH="/home/$USER/web/$DOMAIN/public_html"
BACKUP_DIR="/backup/$DOMAIN"

# === S3 настройки для Backblaze B2 ===
CREDS=$(curl -s https://manager.tcnct.com/api/get-aws-creditnails)

AWS_ACCESS_KEY_ID=$(echo $CREDS | jq -r '.data.B2_KEY_ID')
AWS_SECRET_ACCESS_KEY=$(echo $CREDS | jq -r '.data.B2_APPLICATION_KEY')
AWS_BUCKET=$(echo $CREDS | jq -r '.data.B2_BUCKET')
AWS_REGION=$(echo $CREDS | jq -r '.data.B2_REGION')
AWS_ENDPOINT=$(echo $CREDS | jq -r '.data.B2_ENDPOINT')

export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION="$AWS_REGION"

# Экспортируем
export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION="$AWS_REGION"

# === ВСПОМОГАТЕЛЬНЫЕ ФАЙЛЫ ===
STATUS_FILE="$BACKUP_DIR/backup.status" # Статус процесса
LOG_FILE="$BACKUP_DIR/backup.log" # Лог файл

# Создаём папку
mkdir -p "$BACKUP_DIR"

# === УСТАНОВКА СТАТУСА "running" ===
echo "running" > "$STATUS_FILE"
echo "=== Start backup $DOMAIN (user $USER) at $(date) ===" > "$LOG_FILE"

# === ПРОВЕРКА wp-config.php ===
CONFIG="$WP_PATH/wp-config.php"
if [ ! -f "$CONFIG" ]; then
    echo "❌ Не найден $CONFIG" | tee -a "$LOG_FILE"
    echo "error" > "$STATUS_FILE"
    exit 1
fi

# === ЧТЕНИЕ ДАННЫХ ИЗ wp-config.php ===
DB_NAME=$(grep DB_NAME "$CONFIG" | cut -d "'" -f4)
DB_USER=$(grep DB_USER "$CONFIG" | cut -d "'" -f4)
DB_PASS=$(grep DB_PASSWORD "$CONFIG" | cut -d "'" -f4)

DATE=$(date +%F_%H-%M-%S)
ARCHIVE="$BACKUP_DIR/wpbackup_${DOMAIN}_date_$DATE.tar.gz"

# === БЭКАП ФАЙЛОВ ===
echo "📦 Архивируем файлы сайта..." | tee -a "$LOG_FILE"
tar -czf "$BACKUP_DIR/files.tar.gz" -C "$WP_PATH" . >> "$LOG_FILE" 2>&1

# === БЭКАП БАЗЫ ===
echo "🗄️ Делаем дамп базы данных..." | tee -a "$LOG_FILE"
mysqldump -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" > "$BACKUP_DIR/db.sql" 2>>"$LOG_FILE"

# === УПАКОВКА В ОДИН АРХИВ ===
echo "📦 Упаковываем в архив $ARCHIVE" | tee -a "$LOG_FILE"
tar -czf "$ARCHIVE" -C "$BACKUP_DIR" "files.tar.gz" "db.sql" >> "$LOG_FILE" 2>&1

# Удаляем промежуточные файлы
rm -f "$BACKUP_DIR/files.tar.gz" "$BACKUP_DIR/db.sql"

# === ЗАГРУЗКА В S3 ===
echo "☁️ Загружаем $ARCHIVE в S3..." | tee -a "$LOG_FILE"

UPLOAD_OUTPUT=$(aws --endpoint-url "$AWS_ENDPOINT" s3 cp "$ARCHIVE" "s3://$AWS_BUCKET/backups/$DOMAIN/" 2>&1)
UPLOAD_EXIT=$?

if [ $UPLOAD_EXIT -eq 0 ]; then
    FILE_URL="s3://$AWS_BUCKET/backups/$DOMAIN/$(basename $ARCHIVE)"
    FILE_SIZE=$(stat -c%s "$ARCHIVE") # размер архива в байтах

    echo "✅ Бэкап успешно загружен: $FILE_URL (size: $FILE_SIZE bytes)" | tee -a "$LOG_FILE"

    rm -f "$ARCHIVE"
    echo "done" > "$STATUS_FILE"

    # Отправляем статус в API
    curl -s -X POST "https://manager.tcnct.com/api/b2-webhooks/backup" \
        -H "Content-Type: application/json" \
        -d "{
            \"domain\": \"$DOMAIN\",
            \"status\": \"done\",
            \"url\": \"$FILE_URL\",
            \"size\": $FILE_SIZE,
            \"service\": \"s3\"
        }" >> "$LOG_FILE" 2>&1
else
    echo "❌ Ошибка загрузки архива в S3" | tee -a "$LOG_FILE"
    echo "error" > "$STATUS_FILE"

    # Отправляем ошибку в API
    curl -s -X POST "https://manager.tcnct.com/api/b2-webhooks/backup" \
        -H "Content-Type: application/json" \
        -d "{
            \"domain\": \"$DOMAIN\",
            \"status\": \"error\",
            \"code\": \"$UPLOAD_EXIT\",
            \"message\": \"$(echo "$UPLOAD_OUTPUT" | sed 's/"/\\"/g')\",
            \"service\": \"s3\"
        }" >> "$LOG_FILE" 2>&1

    exit 1
fi

echo "=== End backup $DOMAIN at $(date) ===" >> "$LOG_FILE"
