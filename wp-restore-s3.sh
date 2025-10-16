#!/bin/bash
# ==============================================
# Восстановление сайта (WordPress или HTML) из S3 Backblaze B2 архива
# ==============================================

VERSION="v2"

export PATH=$PATH:/usr/local/hestia/bin

# === Проверка аргументов ===
if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ] || [ -z "$5" ]; then
    echo "Использование: $0 domain.tld s3://bucket/backups/domain/file.tar.gz backup_id site_id is_donor"
    exit 1
fi

DOMAIN="$1"
FULL_S3_PATH="$2"
BACKUP_ID="$3"
SITE_ID="$4"
IS_DONOR="$5" # true / false
BACKUP_FILE=$(basename "$FULL_S3_PATH")

RESTORE_STATUS="done"
RESTORE_MESSAGE="Восстановление выполнено успешно"

LOG_ROOT="/backup_restore"
RESTORE_DIR="$LOG_ROOT/$DOMAIN"
mkdir -p "$RESTORE_DIR"
LOG_FILE="$RESTORE_DIR/restore.log"
echo "=== Start restore $DOMAIN at $(date) ===" > "$LOG_FILE"

echo "→ DOMAIN: $DOMAIN"
echo "→ BACKUP_ID: $BACKUP_ID"
echo "→ SITE_ID: $SITE_ID"
echo "→ IS_DONOR: $IS_DONOR"

# === Определяем пользователя ===
USER=$(v-search-domain-owner "$DOMAIN" plain 2>/dev/null | awk '{print $2}')
REMOVE_SCRIPT="/usr/local/bin/remove-domain.sh"

if [ -z "$USER" ]; then
    USER=$(v-list-users json | jq -r 'keys[0]')
    echo "Домен $DOMAIN не найден. Создаю для пользователя $USER..."

    # --- Удаляем старый домен, если остался ---
    if [ -f "$REMOVE_SCRIPT" ]; then
        echo "Проверка и удаление старого домена (если есть)..." | tee -a "$LOG_FILE"
        bash "$REMOVE_SCRIPT" "$DOMAIN"
    fi

    # --- Создаём домен ---
    v-add-domain "$USER" "$DOMAIN" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        if [ ! -f "/usr/local/hestia/data/users/$USER/domains/$DOMAIN.conf" ]; then
            RESTORE_STATUS="error"
            RESTORE_MESSAGE="Ошибка: не удалось создать домен $DOMAIN"
        fi
    else
        echo "Домен $DOMAIN успешно создан."
        PHP_VERSION=$(v-list-sys-php plain | head -n 1 | awk '{print $1}')
        v-add-letsencrypt-domain "$USER" "$DOMAIN" "www.$DOMAIN" >/dev/null 2>&1
    fi
else
    echo "Домен $DOMAIN найден, пользователь: $USER"
fi

WP_PATH="/home/$USER/web/$DOMAIN/public_html"

# === Получаем креды к Backblaze B2 ===
CREDS=$(curl -s https://manager.tcnct.com/api/get-aws-creditnails)
AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r '.data.B2_KEY_ID')
AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r '.data.B2_APPLICATION_KEY')
AWS_REGION=$(echo "$CREDS" | jq -r '.data.B2_REGION')
AWS_ENDPOINT=$(echo "$CREDS" | jq -r '.data.B2_ENDPOINT')
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION="$AWS_REGION"

echo "Восстановление из архива: $FULL_S3_PATH" | tee -a "$LOG_FILE"

cd "$RESTORE_DIR" || {
    RESTORE_STATUS="error"
    RESTORE_MESSAGE="Ошибка: не удалось перейти в каталог $RESTORE_DIR"
}

aws --endpoint-url "$AWS_ENDPOINT" s3 cp "$FULL_S3_PATH" . 2>&1 | tee -a "$LOG_FILE"
if [ ! -f "$RESTORE_DIR/$BACKUP_FILE" ]; then
    RESTORE_STATUS="error"
    RESTORE_MESSAGE="Ошибка: архив не скачан"
fi

# === Очистка и распаковка ===
if [ -d "$WP_PATH" ]; then
    rm -rf "$WP_PATH"/*
else
    mkdir -p "$WP_PATH"
fi

tar -xzf "$BACKUP_FILE" -C "$WP_PATH" --overwrite 2>&1 | tee -a "$LOG_FILE"

# === Если это WordPress-сайт ===
if [ "$IS_DONOR" == "true" ] || [ "$IS_DONOR" == "1" ]; then
    echo "Режим: WordPress (донор)" | tee -a "$LOG_FILE"
    CONFIG="$WP_PATH/wp-config.php"

    if [ ! -f "$CONFIG" ]; then
        RESTORE_STATUS="error"
        RESTORE_MESSAGE="Ошибка: после распаковки отсутствует wp-config.php"
    else
        DB_NAME=$(grep -E "DB_NAME" "$CONFIG" | sed -E "s/.*['\"]DB_NAME['\"][[:space:]]*,[[:space:]]*['\"]([^'\"]+)['\"].*/\1/")
        DB_USER=$(grep -E "DB_USER" "$CONFIG" | sed -E "s/.*['\"]DB_USER['\"][[:space:]]*,[[:space:]]*['\"]([^'\"]+)['\"].*/\1/")
        DB_PASS=$(grep -E "DB_PASSWORD" "$CONFIG" | sed -E "s/.*['\"]DB_PASSWORD['\"][[:space:]]*,[[:space:]]*['\"]([^'\"]+)['\"].*/\1/")

        if [ -n "$DB_NAME" ] && [ -n "$DB_USER" ]; then
            DB_EXISTS=$(mariadb -Nse "SHOW DATABASES LIKE '$DB_NAME'" 2>/dev/null)
            [ "$DB_EXISTS" == "$DB_NAME" ] && mariadb -e "DROP DATABASE \`$DB_NAME\`"
            mariadb -e "CREATE DATABASE \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
            mariadb -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
            mariadb -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost'; FLUSH PRIVILEGES;"

            SQL_DUMP=$(find "$WP_PATH" -type f -name "*.sql" | head -n 1)
            if [ -f "$SQL_DUMP" ]; then
                mariadb -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$SQL_DUMP" 2>&1 | tee -a "$LOG_FILE"
                [ $? -ne 0 ] && RESTORE_STATUS="error" && RESTORE_MESSAGE="Ошибка при импорте SQL-дампа"
            else
                RESTORE_STATUS="error"
                RESTORE_MESSAGE="Ошибка: SQL-дамп не найден"
            fi
        else
            RESTORE_STATUS="error"
            RESTORE_MESSAGE="Ошибка: не удалось прочитать настройки базы данных"
        fi
    fi
else
    echo "Режим: HTML-сайт (не донор) — база данных не восстанавливается." | tee -a "$LOG_FILE"
fi

# === Пересборка Hestia ===
v-rebuild-web-domains "$USER" >/dev/null 2>&1
v-update-user-stats "$USER" >/dev/null 2>&1

# === Webhook ===
WEBHOOK_URL="https://9d8f99d4eaf7.ngrok-free.app/api/b2-webhooks/restore"
echo "Отправляю webhook со статусом '$RESTORE_STATUS'..." | tee -a "$LOG_FILE"

WEBHOOK_RESPONSE=$(curl -s --max-time 10 -X POST "$WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "{
        \"domain\": \"$DOMAIN\",
        \"restore_status\": \"$RESTORE_STATUS\",
        \"restore_message\": \"$RESTORE_MESSAGE\",
        \"backup_id\": \"$BACKUP_ID\",
        \"archive\": \"$FULL_S3_PATH\",
        \"site_id\": \"$SITE_ID\",
        \"is_donor\": \"$IS_DONOR\",
        \"service\": \"s3\"
    }" 2>&1)

echo "Webhook response: $WEBHOOK_RESPONSE" | tee -a "$LOG_FILE"
echo "=== End restore $DOMAIN at $(date) ===" | tee -a "$LOG_FILE"
exit 0
