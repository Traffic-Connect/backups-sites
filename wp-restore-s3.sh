#!/bin/bash
# ==============================================
# Восстановление WordPress-сайта из S3 Backblaze B2 архива
# Работает как для существующих доменов, так и для новых.
# ==============================================

# Добавляем путь к Hestia CLI
export PATH=$PATH:/usr/local/hestia/bin

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Использование: $0 domain.tld s3://bucket/backups/domain/file.tar.gz"
    exit 1
fi

DOMAIN="$1"
FULL_S3_PATH="$2"
BACKUP_FILE=$(basename "$FULL_S3_PATH")

# === Проверяем, существует ли домен в Hestia ===
USER=$(v-search-domain-owner "$DOMAIN" plain 2>/dev/null | awk '{print $2}')

if [ -z "$USER" ]; then
    USER=$(v-list-users json | jq -r 'keys[0]')
    echo "Домен $DOMAIN не найден. Создаю для пользователя $USER..."

    echo "Пробую создать домен $DOMAIN для пользователя $USER..." | tee -a "$LOG_FILE"
    v-add-domain "$USER" "$DOMAIN" >/dev/null 2>&1
    EXIT_CODE=$?

    if [ $EXIT_CODE -ne 0 ]; then
        if [ -f "/usr/local/hestia/data/users/$USER/domains/$DOMAIN.conf" ]; then
            echo "Домен $DOMAIN уже существует — продолжаю восстановление." | tee -a "$LOG_FILE"
        else
            echo "Ошибка: не удалось создать домен $DOMAIN (код $EXIT_CODE)" | tee -a "$LOG_FILE"
            exit 1
        fi
    else
        echo "Домен $DOMAIN успешно создан." | tee -a "$LOG_FILE"
    fi

    echo "Пересобираю веб-домены и обновляю статистику..."
    v-update-user-stats "$USER" >/dev/null 2>&1
    v-rebuild-web-domains "$USER" >/dev/null 2>&1

    # === Настраиваем PHP и SSL ===
    PHP_VERSION=$(v-list-sys-php plain | head -n 1 | awk '{print $1}')
    echo "Настраиваю PHP ($PHP_VERSION) и SSL для $DOMAIN..."
    v-change-web-domain-tpl "$USER" "$DOMAIN" "php-fpm"
    v-add-letsencrypt-domain "$USER" "$DOMAIN" "www.$DOMAIN" >/dev/null 2>&1
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
cd "$RESTORE_DIR" || exit
aws --endpoint-url "$AWS_ENDPOINT" s3 cp "$FULL_S3_PATH" . 2>&1 | tee -a "$LOG_FILE"

if [ ! -f "$RESTORE_DIR/$BACKUP_FILE" ]; then
    echo "Ошибка: архив не скачан" | tee -a "$LOG_FILE"
    exit 1
fi

# === Если сайт уже существует — очищаем старые файлы ===
if [ -d "$WP_PATH" ]; then
    echo "Очищаю старый сайт..." | tee -a "$LOG_FILE"
    rm -rf "$WP_PATH"/*
else
    mkdir -p "$WP_PATH"
fi

# === Распаковываем архив ===
echo "Распаковываю архив..." | tee -a "$LOG_FILE"
tar -xzf "$BACKUP_FILE" -C "$WP_PATH" --overwrite 2>&1 | tee -a "$LOG_FILE"

# === Восстанавливаем базу данных ===
CONFIG="$WP_PATH/wp-config.php"
if [ ! -f "$CONFIG" ]; then
    echo "Файл wp-config.php не найден, база не восстановлена" | tee -a "$LOG_FILE"
else
    DB_NAME=$(grep "define.*DB_NAME" "$CONFIG" | sed -E "s/.*['\"]DB_NAME['\"].*,[[:space:]]*['\"]([^'\"]+)['\"].*/\1/")
    DB_USER=$(grep "define.*DB_USER" "$CONFIG" | sed -E "s/.*['\"]DB_USER['\"].*,[[:space:]]*['\"]([^'\"]+)['\"].*/\1/")
    DB_PASS=$(grep "define.*DB_PASSWORD" "$CONFIG" | sed -E "s/.*['\"]DB_PASSWORD['\"].*,[[:space:]]*['\"]([^'\"]+)['\"].*/\1/")

    if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ]; then
        echo "Ошибка: не удалось прочитать параметры БД из wp-config.php" | tee -a "$LOG_FILE"
    else
        echo "Проверяю наличие БД $DB_NAME..." | tee -a "$LOG_FILE"
        DB_EXISTS=$(mysql -Nse "SHOW DATABASES LIKE '$DB_NAME'" 2>/dev/null)

        if [ "$DB_EXISTS" == "$DB_NAME" ]; then
            echo "Удаляю старую базу $DB_NAME..." | tee -a "$LOG_FILE"
            mysql -e "DROP DATABASE \`$DB_NAME\`" 2>/dev/null
        fi

        echo "Создаю базу $DB_NAME..." | tee -a "$LOG_FILE"
        mysql -e "CREATE DATABASE \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>&1 | tee -a "$LOG_FILE"
        mysql -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';" 2>&1 | tee -a "$LOG_FILE"
        mysql -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost'; FLUSH PRIVILEGES;" 2>&1 | tee -a "$LOG_FILE"

        SQL_DUMP=$(find "$WP_PATH" -type f -name "*.sql" | head -n 1)
        if [ -z "$SQL_DUMP" ]; then
            echo "SQL-дамп не найден, база не восстановлена" | tee -a "$LOG_FILE"
        else
            echo "Импортирую дамп в базу $DB_NAME..." | tee -a "$LOG_FILE"
            mysql -u"$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$SQL_DUMP" 2>&1 | tee -a "$LOG_FILE"
            RESTORE_DB_EXIT=$?

            if [ $RESTORE_DB_EXIT -eq 0 ]; then
                echo "База данных успешно восстановлена" | tee -a "$LOG_FILE"
                rm -f "$SQL_DUMP"
            else
                echo "Ошибка восстановления базы ($RESTORE_DB_EXIT)" | tee -a "$LOG_FILE"
            fi
        fi
    fi
fi

# === Финальная пересборка, чтобы панель точно видела сайт ===
v-rebuild-web-domains "$USER" >/dev/null 2>&1
v-update-user-stats "$USER" >/dev/null 2>&1

# === Отправляем вебхук ===
WEBHOOK_RESPONSE=$(curl -s --max-time 10 -X POST "https://manager.tcnct.com/api/b2-webhooks/restore" \
    -H "Content-Type: application/json" \
    -d "{
        \"domain\": \"$DOMAIN\",
        \"status\": \"done\",
        \"archive\": \"$FULL_S3_PATH\",
        \"service\": \"s3\"
    }" 2>&1)

echo "Webhook response: $WEBHOOK_RESPONSE" | tee -a "$LOG_FILE"
echo "=== End restore $DOMAIN at $(date) ===" | tee -a "$LOG_FILE"

exit 0
