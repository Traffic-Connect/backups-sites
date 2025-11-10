#!/bin/bash
# Бэкап WordPress-сайта (по домену) + загрузка в S3

VERSION="v4"

# === ПРОВЕРКА АРГУМЕНТОВ ===
if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
    echo "Использование: $0 domain.tld environment"
    echo "Пример: $0 example.com manager.tcnct.com 1"
    exit 1
fi

DOMAIN="$1"
ENVIRONMENT="$2"
BACKUP_ID="$3"

# === ПРОВЕРКА НАЛИЧИЯ ДОМЕНА ===
# Ищем папку домена во всех пользовательских директориях
DOMAIN_FOUND=0
shopt -s nullglob  # Если нет совпадений, glob вернёт пустой список

for user_dir in /home/*/web/$DOMAIN/public_html; do
    if [ -d "$user_dir" ]; then
        DOMAIN_FOUND=1
        break
    fi
done

shopt -u nullglob  # Отключаем nullglob

if [ $DOMAIN_FOUND -eq 0 ]; then
    echo "Ошибка: домен $DOMAIN не найден на сервере"
    shopt -u nullglob
    exit 1
fi

# === ПОЛЬЗОВАТЕЛЬ ===
USER=$(v-search-domain-owner "$DOMAIN" plain 2>/dev/null | awk '{print $2}')
if [ -z "$USER" ]; then
    for user_dir in /home/*/; do
        if [ -d "${user_dir}web/${DOMAIN}/public_html" ]; then
            USER=$(basename "$user_dir")
            break
        fi
    done
fi

if [ -z "$USER" ]; then
    echo "Не удалось определить пользователя для домена $DOMAIN"
    exit 1
fi

# === НАСТРОЙКИ ===
PUBLIC_HTML="/home/$USER/web/$DOMAIN/public_html"
BACKUP_DIR="/backup/$DOMAIN"
STATUS_FILE="$BACKUP_DIR/backup.status"
LOG_FILE="$BACKUP_DIR/backup.log"

# === S3 настройки для Backblaze B2 ===
CREDS=$(curl -s "https://${ENVIRONMENT}/api/get-aws-creditnails")

AWS_ACCESS_KEY_ID=$(echo $CREDS | jq -r '.data.B2_KEY_ID')
AWS_SECRET_ACCESS_KEY=$(echo $CREDS | jq -r '.data.B2_APPLICATION_KEY')
AWS_BUCKET=$(echo $CREDS | jq -r '.data.B2_BUCKET')
AWS_REGION=$(echo $CREDS | jq -r '.data.B2_REGION')
AWS_ENDPOINT=$(echo $CREDS | jq -r '.data.B2_ENDPOINT')

export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_DEFAULT_REGION="$AWS_REGION"

mkdir -p "$BACKUP_DIR"
echo "running" > "$STATUS_FILE"
echo "=== Start backup $DOMAIN (user $USER) at $(date) ===" > "$LOG_FILE"

# === ПОИСК wp-config.php (может быть в public_html или public_html/wp) ===
CONFIG="$PUBLIC_HTML/wp-config.php"
if [ ! -f "$CONFIG" ]; then
    CONFIG="$PUBLIC_HTML/wp/wp-config.php"
    if [ ! -f "$CONFIG" ]; then
        echo "Не найден wp-config.php ни в $PUBLIC_HTML ни в $PUBLIC_HTML/wp" | tee -a "$LOG_FILE"
        echo "error" > "$STATUS_FILE"
        exit 1
    fi
fi

# WP_PATH - это путь где находится wp-config.php (для поиска БД и других данных)
WP_PATH=$(dirname "$CONFIG")

# === ИМЯ БАЗЫ ===
DB_NAME=$(grep "define.*DB_NAME" "$CONFIG" | sed -E "s/.*['\"]DB_NAME['\"][[:space:]]*,[[:space:]]*['\"]([^'\"]+)['\"].*/\1/")
if [ -z "$DB_NAME" ]; then
    echo "Не удалось извлечь имя базы данных" | tee -a "$LOG_FILE"
    echo "error" > "$STATUS_FILE"
    exit 1
fi
echo "Имя базы данных: $DB_NAME" | tee -a "$LOG_FILE"

# === СОЗДАНИЕ АРХИВА ===
DATE=$(date +%F_%H-%M-%S)
ARCHIVE="$BACKUP_DIR/wpbackup_${DOMAIN}_date_$DATE.tar.gz"

echo "Создаём дамп базы..." | tee -a "$LOG_FILE"
mysqldump -uroot "$DB_NAME" --skip-comments --compact > "$PUBLIC_HTML/${DOMAIN}.sql" 2>>"$LOG_FILE"

if [ ! -s "$PUBLIC_HTML/${DOMAIN}.sql" ]; then
    echo "ОШИБКА: дамп пуст" | tee -a "$LOG_FILE"
    echo "error" > "$STATUS_FILE"
    rm -f "$PUBLIC_HTML/${DOMAIN}.sql"
    exit 1
fi

echo "Создаём архив из $PUBLIC_HTML..." | tee -a "$LOG_FILE"
cd "$PUBLIC_HTML"
tar -czf "$ARCHIVE" --exclude='./.??*' * >> "$LOG_FILE" 2>&1
rm -f "$PUBLIC_HTML/${DOMAIN}.sql"

# === ЗАГРУЗКА В S3 ===
echo "Загружаем $ARCHIVE в S3..." | tee -a "$LOG_FILE"
UPLOAD_OUTPUT=$(aws --endpoint-url "$AWS_ENDPOINT" s3 cp "$ARCHIVE" "s3://$AWS_BUCKET/backups/$DOMAIN/" 2>&1)
UPLOAD_EXIT=$?

if [ $UPLOAD_EXIT -eq 0 ]; then
    FILE_URL="s3://$AWS_BUCKET/backups/$DOMAIN/$(basename $ARCHIVE)"
    FILE_SIZE=$(stat -c%s "$ARCHIVE")

    echo "Бэкап успешно загружен: $FILE_URL ($FILE_SIZE bytes)" | tee -a "$LOG_FILE"

    WEBHOOK_URL="https://${ENVIRONMENT}/api/b2-webhooks/backup"

    WEBHOOK_RESPONSE=$(curl -s --max-time 10 -X POST "$WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "{
            \"domain\": \"$DOMAIN\",
            \"status\": \"done\",
            \"url\": \"$FILE_URL\",
            \"size\": $FILE_SIZE,
            \"backup_id\": $BACKUP_ID,
            \"service\": \"s3\"
        }" 2>&1)

    echo "Webhook отправлен на $WEBHOOK_URL" | tee -a "$LOG_FILE"
    echo "Ответ: $WEBHOOK_RESPONSE" | tee -a "$LOG_FILE"

    rm -f "$ARCHIVE"
else
    echo "Ошибка загрузки архива в S3" | tee -a "$LOG_FILE"
    echo "error" > "$STATUS_FILE"

    WEBHOOK_URL="https://${ENVIRONMENT}/api/b2-webhooks/backup"
    WEBHOOK_RESPONSE=$(curl -s --max-time 10 -X POST "$WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d "{
            \"domain\": \"$DOMAIN\",
            \"status\": \"error\",
            \"code\": $UPLOAD_EXIT,
            \"message\": \"$(echo "$UPLOAD_OUTPUT" | sed 's/"/\\"/g')\",
            \"backup_id\": $BACKUP_ID,
            \"service\": \"s3\"
        }" 2>&1)

    echo "Webhook error response: $WEBHOOK_RESPONSE" | tee -a "$LOG_FILE"
    exit 1
fi

echo "=== End backup $DOMAIN at $(date) ===" | tee -a "$LOG_FILE"
echo "Backup for $DOMAIN completed successfully"
exit 0
