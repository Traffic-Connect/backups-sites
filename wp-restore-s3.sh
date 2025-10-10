#!/bin/bash
# ==============================================
# Восстановление WordPress-сайта из S3 Backblaze B2 архива
# Работает как для существующих доменов, так и для новых.
# ==============================================

export PATH=$PATH:/usr/local/hestia/bin

# === Проверка аргументов ===
if [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
    echo "Использование: $0 domain.tld s3://bucket/backups/domain/file.tar.gz backup_id"
    exit 1
fi

DOMAIN="$1"
FULL_S3_PATH="$2"
BACKUP_ID="$3"
BACKUP_FILE=$(basename "$FULL_S3_PATH")
RESTORE_STATUS="done"
RESTORE_MESSAGE="Восстановление выполнено успешно"

# === Определяем пользователя ===
USER=$(v-search-domain-owner "$DOMAIN" plain 2>/dev/null | awk '{print $2}')

if [ -z "$USER" ]; then
    USER=$(v-list-users json | jq -r 'keys[0]')
    echo "Домен $DOMAIN не найден. Создаю для пользователя $USER..."

    # Проверяем, не остались ли следы старого домена
    if [ -f "/usr/local/hestia/data/users/$USER/domains/$DOMAIN.conf" ]; then
        echo "Найден старый конфиг домена — удаляю остатки..." | tee -a "$LOG_FILE"
        v-delete-domain "$USER" "$DOMAIN" >/dev/null 2>&1
        rm -f "/usr/local/hestia/data/users/$USER/domains/$DOMAIN.conf"
        rm -rf "/home/$USER/web/$DOMAIN"
        rm -rf "/home/$USER/conf/web/$DOMAIN"
    fi

    v-add-domain "$USER" "$DOMAIN" >/dev/null 2>&1
    EXIT_CODE=$?
    if [ $EXIT_CODE -ne 0 ]; then
        if [ -f "/usr/local/hestia/data/users/$USER/domains/$DOMAIN.conf" ]; then
            echo "Домен $DOMAIN уже существует — продолжаю восстановление."
        else
            RESTORE_STATUS="error"
            RESTORE_MESSAGE="Ошибка: не удалось создать домен $DOMAIN (код $EXIT_CODE)"
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
RESTORE_DIR="/backup_restore/$DOMAIN"
mkdir -p "$RESTORE_DIR"
LOG_FILE="$RESTORE_DIR/restore.log"
echo "=== Start restore $DOMAIN at $(date) ===" > "$LOG_FILE"

# === Получаем креды к Backblaze B2 ===
CREDS=$(curl -s https://manager.tcnct.com/api/get-aws-creditnails)
AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r '.data.B2_KEY_ID')
AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r '.data.B2_APPLICATION_KEY')
AWS_REGION=$(echo "$CREDS" | jq -r '.data.B2_REGION')
AWS_ENDPOINT=$(echo "$CREDS" | jq -r '.data.B2_ENDPOINT')
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION="$AWS_REGION"

echo "Восстановление из архива: $FULL_S3_PATH" | tee -a "$LOG_FILE"

# === Скачиваем архив ===
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
if [ ! -f "$WP_PATH/wp-config.php" ]; then
    RESTORE_STATUS="error"
    RESTORE_MESSAGE="Ошибка: после распаковки отсутствует wp-config.php"
fi

# === Восстанавливаем базу данных ===
CONFIG="$WP_PATH/wp-config.php"
if [ -f "$CONFIG" ]; then
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
else
    RESTORE_STATUS="error"
    RESTORE_MESSAGE="Ошибка: wp-config.php не найден"
fi

# === Финальная проверка ===
if [ "$RESTORE_STATUS" == "done" ]; then
    if [ ! -d "$WP_PATH" ] || [ ! -f "$WP_PATH/wp-config.php" ]; then
        RESTORE_STATUS="error"
        RESTORE_MESSAGE="Ошибка: структура сайта повреждена после распаковки"
    fi
fi

# === Пересборка Hestia (не критичная) ===
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
        \"service\": \"s3\"
    }" 2>&1)

echo "Webhook response: $WEBHOOK_RESPONSE" | tee -a "$LOG_FILE"
echo "=== End restore $DOMAIN at $(date) ===" | tee -a "$LOG_FILE"
exit 0
