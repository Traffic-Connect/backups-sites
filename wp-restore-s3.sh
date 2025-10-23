#!/bin/bash
# ==============================================
# Восстановление сайта (WordPress или HTML) из S3 Backblaze B2 архива
# ==============================================

set -euo pipefail
IFS=$'\n\t'

VERSION="v4"

export PATH=$PATH:/usr/local/hestia/bin

# === Проверка аргументов ===
if [ $# -lt 5 ]; then
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
echo "=== Start restore $DOMAIN at $(date '+%F %T') ===" > "$LOG_FILE"

echo "→ DOMAIN: $DOMAIN"
echo "→ BACKUP_ID: $BACKUP_ID"
echo "→ SITE_ID: $SITE_ID"
echo "→ IS_DONOR: $IS_DONOR"

# === Функция отправки webhook ===
send_webhook() {
    local WEBHOOK_URL="https://49b9eacd3b7d.ngrok-free.app/api/b2-webhooks/restore"
    echo "Отправляю webhook со статусом '$RESTORE_STATUS'..." | tee -a "$LOG_FILE"

    curl -s --max-time 15 -X POST "$WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d @<(cat <<JSON
{
    "domain": "$DOMAIN",
    "restore_status": "$RESTORE_STATUS",
    "restore_message": "$RESTORE_MESSAGE",
    "backup_id": "$BACKUP_ID",
    "archive": "$FULL_S3_PATH",
    "site_id": "$SITE_ID",
    "is_donor": "$IS_DONOR",
    "service": "s3"
}
JSON
) >> "$LOG_FILE" 2>&1 || true
}

# === Определяем пользователя ===
USER=$(v-search-domain-owner "$DOMAIN" plain 2>/dev/null | awk '{print $2}') || true
REMOVE_SCRIPT="/usr/local/bin/remove-domain.sh"

if [ -z "$USER" ]; then
    USER=$(v-list-users json | jq -r 'keys[0]')
    echo "Домен $DOMAIN не найден. Создаю для пользователя $USER..." | tee -a "$LOG_FILE"

    # --- Удаляем старый домен, если остался ---
    if [ -f "$REMOVE_SCRIPT" ]; then
        echo "Проверка и удаление старого домена (если есть)..." | tee -a "$LOG_FILE"
        bash "$REMOVE_SCRIPT" "$DOMAIN" >> "$LOG_FILE" 2>&1 || true
    fi

    # --- Создаём домен ---
    if ! v-add-domain "$USER" "$DOMAIN" >/dev/null 2>&1; then
        if [ ! -f "/usr/local/hestia/data/users/$USER/domains/$DOMAIN.conf" ]; then
            RESTORE_STATUS="error"
            RESTORE_MESSAGE="Ошибка: не удалось создать домен $DOMAIN"
            send_webhook
            exit 1
        fi
    else
        echo "Домен $DOMAIN успешно создан." | tee -a "$LOG_FILE"
        PHP_VERSION=$(v-list-sys-php plain | head -n 1 | awk '{print $1}')
        v-add-letsencrypt-domain "$USER" "$DOMAIN" "www.$DOMAIN" >/dev/null 2>&1 || true
    fi
else
    echo "Домен $DOMAIN найден, пользователь: $USER" | tee -a "$LOG_FILE"
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
    send_webhook
    exit 1
}

# === Определяем способ скачивания ===
if [[ "$FULL_S3_PATH" == s3://* ]]; then
    echo "Тип ссылки: S3 (через AWS CLI)" | tee -a "$LOG_FILE"
    if ! aws --endpoint-url "$AWS_ENDPOINT" s3 cp "$FULL_S3_PATH" . --no-progress --only-show-errors >> "$LOG_FILE" 2>&1; then
        RESTORE_STATUS="error"
        RESTORE_MESSAGE="Ошибка: архив не найден в S3 ($FULL_S3_PATH)"
        echo "$RESTORE_MESSAGE" | tee -a "$LOG_FILE"
        send_webhook
        exit 1
    fi
else
    echo "Тип ссылки: HTTPS (прямая загрузка)" | tee -a "$LOG_FILE"
    BACKUP_FILE=$(basename "$FULL_S3_PATH")
    if ! curl -L -o "$BACKUP_FILE" "$FULL_S3_PATH" >> "$LOG_FILE" 2>&1; then
        RESTORE_STATUS="error"
        RESTORE_MESSAGE="Ошибка: не удалось скачать архив по ссылке"
        send_webhook
        exit 1
    fi
fi

# === Проверка результата скачивания ===
if [ ! -f "$RESTORE_DIR/$BACKUP_FILE" ]; then
    RESTORE_STATUS="error"
    RESTORE_MESSAGE="Ошибка: архив не скачан"
    echo "$RESTORE_MESSAGE" | tee -a "$LOG_FILE"
    send_webhook
    exit 1
fi

# === Очистка и подготовка каталога ===
if [ -d "$WP_PATH" ]; then
    rm -rf "$WP_PATH"/* || true
else
    mkdir -p "$WP_PATH"
fi

# === Определяем тип архива и распаковываем ===
echo "Распаковка архива: $BACKUP_FILE" | tee -a "$LOG_FILE"
if [[ "$BACKUP_FILE" == *.tar.gz ]]; then
    tar -xzf "$BACKUP_FILE" -C "$WP_PATH" --overwrite >> "$LOG_FILE" 2>&1 || {
        RESTORE_STATUS="error"
        RESTORE_MESSAGE="Ошибка при распаковке архива (tar.gz)"
        send_webhook
        exit 1
    }
elif [[ "$BACKUP_FILE" == *.zip ]]; then
    unzip -o "$BACKUP_FILE" -d "$WP_PATH" >> "$LOG_FILE" 2>&1 || {
        RESTORE_STATUS="error"
        RESTORE_MESSAGE="Ошибка при распаковке архива (zip)"
        send_webhook
        exit 1
    }
else
    RESTORE_STATUS="error"
    RESTORE_MESSAGE="Неизвестный формат архива: $BACKUP_FILE"
    send_webhook
    exit 1
fi

# === Если это WordPress-сайт ===
if [[ "${IS_DONOR,,}" == "true" || "$IS_DONOR" == "1" ]]; then
    echo "Режим: WordPress (донор)" | tee -a "$LOG_FILE"
    CONFIG="$WP_PATH/wp-config.php"

    if [ ! -f "$CONFIG" ]; then
        RESTORE_STATUS="error"
        RESTORE_MESSAGE="Ошибка: отсутствует wp-config.php"
        send_webhook
        exit 1
    fi

    DB_NAME=$(grep -E "DB_NAME" "$CONFIG" | sed -E "s/.*['\"]DB_NAME['\"].*['\"]([^'\"]+)['\"].*/\1/")
    DB_USER=$(grep -E "DB_USER" "$CONFIG" | sed -E "s/.*['\"]DB_USER['\"].*['\"]([^'\"]+)['\"].*/\1/")
    DB_PASS=$(grep -E "DB_PASSWORD" "$CONFIG" | sed -E "s/.*['\"]DB_PASSWORD['\"].*['\"]([^'\"]+)['\"].*/\1/")

    if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ]; then
        RESTORE_STATUS="error"
        RESTORE_MESSAGE="Ошибка: не удалось прочитать настройки БД"
        send_webhook
        exit 1
    fi

    echo "Импорт базы данных..." | tee -a "$LOG_FILE"
    mariadb -e "DROP DATABASE IF EXISTS \`$DB_NAME\`; CREATE DATABASE \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" >/dev/null 2>&1
    mariadb -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS'; GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost'; FLUSH PRIVILEGES;" >/dev/null 2>&1

    SQL_DUMP=$(find "$WP_PATH" -type f -name "*.sql" | head -n 1 || true)
    if [ -f "$SQL_DUMP" ]; then
        if ! mariadb -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$SQL_DUMP" >> "$LOG_FILE" 2>&1; then
            RESTORE_STATUS="error"
            RESTORE_MESSAGE="Ошибка при импорте SQL-дампа"
            send_webhook
            exit 1
        fi
    else
        RESTORE_STATUS="error"
        RESTORE_MESSAGE="SQL-дамп не найден"
        send_webhook
        exit 1
    fi
else
    echo "Режим: HTML-сайт (не донор) — база данных не восстанавливается." | tee -a "$LOG_FILE"
fi

# === Пересборка Hestia и отправка webhook ===
v-rebuild-web-domains "$USER" >/dev/null 2>&1 || true
v-update-user-stats "$USER" >/dev/null 2>&1 || true

send_webhook
echo "=== End restore $DOMAIN at $(date '+%F %T') ===" | tee -a "$LOG_FILE"
exit 0
