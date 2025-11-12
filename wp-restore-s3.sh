#!/bin/bash
# ==============================================
# Восстановление сайта (WordPress или HTML) из S3 Backblaze B2 архива
# ==============================================

set -euo pipefail
IFS=$'\n\t'

VERSION="v7"

export PATH=$PATH:/usr/local/hestia/bin

# === Проверка аргументов ===
if [ $# -lt 7 ]; then
    echo "Использование: $0 domain.tld s3://bucket/backups/domain/file.tar.gz backup_id site_id is_donor environment scheme_id"
    #Example
    #./usr/local/bin/wp-restore-s3.sh restore-test.com s3://artem-test-bucket/backups/midora.cyou/wpbackup_midora.cyou_date_2025-11-12_07-08-07.tar.gz 38 481 true manager-stg.tcnct.com 24
    #./usr/local/bin/wp-restore-s3.sh movano.cyou s3://artem-test-bucket/schema-zips/24/d5869273-f110-4250-8780-41dd95484937-midora.cyou.zip 38 481 false manager-stg.tcnct.com 24
    exit 1
fi

DOMAIN="$1"
FULL_S3_PATH="$2"
BACKUP_ID="$3"
SITE_ID="$4"
IS_DONOR="$5" # true / false
ENVIRONMENT="$6"
SCHEME_ID="$7"
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
echo "→ ENVIRONMENT: $ENVIRONMENT"
echo "→ SCHEME_ID: $SCHEME_ID"

# === Функция отправки webhook ===
send_webhook() {
    local WEBHOOK_URL="https://${ENVIRONMENT}/api/b2-webhooks/restore"
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
    "scheme_id": "$SCHEME_ID",
    "service": "s3"
}
JSON
) >> "$LOG_FILE" 2>&1 || true
}

# === Определяем пользователя на основе scheme_id ===
SCHEMA_USER="schema_${SCHEME_ID}"
REMOVE_SCRIPT="/usr/local/bin/remove-domain.sh"

# Проверяем существование пользователя schema_{scheme_id}
if v-list-user "$SCHEMA_USER" >/dev/null 2>&1; then
    echo "Пользователь $SCHEMA_USER уже существует" | tee -a "$LOG_FILE"
    USER="$SCHEMA_USER"
else
    echo "Пользователь $SCHEMA_USER не найден. Создаю..." | tee -a "$LOG_FILE"

    # Генерируем случайный пароль для нового пользователя
    USER_PASSWORD=$(openssl rand -base64 16)
    USER_EMAIL="schema_${SCHEME_ID}@tcnct.com"

    # Создаём пользователя
    echo "Выполняю: v-add-user $SCHEMA_USER ******** $USER_EMAIL" | tee -a "$LOG_FILE"
    USER_CREATE_OUTPUT=$(v-add-user "$SCHEMA_USER" "$USER_PASSWORD" "$USER_EMAIL" 2>&1) || USER_CREATE_FAILED=$?

    if [ "${USER_CREATE_FAILED:-0}" -ne 0 ]; then
        echo "v-add-user вернул код ошибки: $USER_CREATE_FAILED" | tee -a "$LOG_FILE"
        echo "Вывод команды: $USER_CREATE_OUTPUT" | tee -a "$LOG_FILE"
        RESTORE_STATUS="error"
        RESTORE_MESSAGE="Ошибка: не удалось создать пользователя $SCHEMA_USER. Детали: $USER_CREATE_OUTPUT"
        send_webhook
        exit 1
    else
        echo "Пользователь $SCHEMA_USER успешно создан" | tee -a "$LOG_FILE"
        USER="$SCHEMA_USER"
    fi
fi

# Проверяем, существует ли домен у этого пользователя
EXISTING_OWNER=$(v-search-domain-owner "$DOMAIN" plain 2>/dev/null | awk '{print $2}') || true

if [ -n "$EXISTING_OWNER" ]; then
    if [ "$EXISTING_OWNER" != "$USER" ]; then
        echo "Домен $DOMAIN найден у другого пользователя ($EXISTING_OWNER). Удаляю..." | tee -a "$LOG_FILE"
    else
        echo "Домен $DOMAIN уже существует у пользователя $USER. Пересоздаю..." | tee -a "$LOG_FILE"
    fi

    # --- Удаляем старый домен ---
    if [ -f "$REMOVE_SCRIPT" ]; then
        bash "$REMOVE_SCRIPT" "$DOMAIN" >> "$LOG_FILE" 2>&1 || true
    fi

    # Пробуем удалить через v-delete-domain у найденного владельца
    v-delete-domain "$EXISTING_OWNER" "$DOMAIN" >> "$LOG_FILE" 2>&1 || true
else
    echo "Домен $DOMAIN не найден через v-search-domain-owner. Проверяю наличие домена в системе..." | tee -a "$LOG_FILE"

    # Ищем домен у всех пользователей
    ALL_USERS=$(v-list-users plain | awk '{print $1}')
    for CHECK_USER in $ALL_USERS; do
        if v-list-web-domain "$CHECK_USER" "$DOMAIN" >/dev/null 2>&1; then
            echo "Найден домен $DOMAIN у пользователя $CHECK_USER. Удаляю..." | tee -a "$LOG_FILE"
            v-delete-domain "$CHECK_USER" "$DOMAIN" >> "$LOG_FILE" 2>&1 || true
            break
        fi
    done

    echo "Создаю домен для пользователя $USER..." | tee -a "$LOG_FILE"
fi

# --- Проверяем и удаляем папку домена, если она существует ---
DOMAIN_WEB_PATH="/home/$USER/web/$DOMAIN"
if [ -d "$DOMAIN_WEB_PATH" ]; then
    echo "Найдена существующая папка домена: $DOMAIN_WEB_PATH - удаляю..." | tee -a "$LOG_FILE"
    rm -rf "$DOMAIN_WEB_PATH" >> "$LOG_FILE" 2>&1 || true
fi

# --- Проверяем и удаляем DNS-зону, если она существует ---
if v-list-dns-domain "$USER" "$DOMAIN" >/dev/null 2>&1; then
    echo "Найдена существующая DNS-зона для домена: $DOMAIN - удаляю..." | tee -a "$LOG_FILE"
    v-delete-dns-domain "$USER" "$DOMAIN" >> "$LOG_FILE" 2>&1 || true
fi

# --- Проверяем и удаляем остатки конфигурации домена в HestiaCP ---
HESTIA_DOMAIN_CONF="/usr/local/hestia/data/users/$USER/web/$DOMAIN.conf"
if [ -f "$HESTIA_DOMAIN_CONF" ]; then
    echo "Найден конфигурационный файл домена в HestiaCP: $HESTIA_DOMAIN_CONF - удаляю..." | tee -a "$LOG_FILE"
    rm -f "$HESTIA_DOMAIN_CONF" >> "$LOG_FILE" 2>&1 || true
    rm -f "/usr/local/hestia/data/users/$USER/web/$DOMAIN."* >> "$LOG_FILE" 2>&1 || true
fi

# --- Создаём домен (только WEB, без DNS и MAIL) ---
echo "Попытка создать домен $DOMAIN для пользователя $USER..." | tee -a "$LOG_FILE"
DOMAIN_CREATE_OUTPUT=$(v-add-web-domain "$USER" "$DOMAIN" 2>&1) || DOMAIN_CREATE_FAILED=$?

if [ "${DOMAIN_CREATE_FAILED:-0}" -ne 0 ]; then
    echo "v-add-domain вернул код ошибки: $DOMAIN_CREATE_FAILED" | tee -a "$LOG_FILE"
    echo "Вывод команды: $DOMAIN_CREATE_OUTPUT" | tee -a "$LOG_FILE"

    if [ ! -f "/usr/local/hestia/data/users/$USER/domains/$DOMAIN.conf" ]; then
        RESTORE_STATUS="error"
        RESTORE_MESSAGE="Ошибка: не удалось создать домен $DOMAIN. Детали: $DOMAIN_CREATE_OUTPUT"
        send_webhook
        exit 1
    fi
else
    echo "Домен $DOMAIN успешно создан." | tee -a "$LOG_FILE"

    # Меняем шаблон прокси на tc-nginx-only
    echo "Изменяю прокси шаблон на tc-nginx-only..." | tee -a "$LOG_FILE"
    v-change-web-domain-proxy-tpl "$USER" "$DOMAIN" "tc-nginx-only" >> "$LOG_FILE" 2>&1 || {
        echo "Предупреждение: не удалось изменить прокси шаблон" | tee -a "$LOG_FILE"
    }

    # Добавляем SSL сертификат Let's Encrypt
    v-add-letsencrypt-domain "$USER" "$DOMAIN" "www.$DOMAIN" >/dev/null 2>&1 || true
fi

WP_PATH="/home/$USER/web/$DOMAIN/public_html"

# === Получаем креды к Backblaze B2 ===
CREDS=$(curl -s https://${ENVIRONMENT}/api/get-aws-creditnails)
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
EXTRACT_ERROR=0

if [[ "$BACKUP_FILE" == *.tar.gz ]]; then
    if ! tar -xzf "$BACKUP_FILE" -C "$WP_PATH" --overwrite >> "$LOG_FILE" 2>&1; then
        RESTORE_STATUS="error"
        RESTORE_MESSAGE="Ошибка при распаковке архива (tar.gz)"
        echo "$RESTORE_MESSAGE" | tee -a "$LOG_FILE"
        EXTRACT_ERROR=1
    else
        echo "Архив успешно распакован (tar.gz)" | tee -a "$LOG_FILE"
    fi
elif [[ "$BACKUP_FILE" == *.zip ]]; then
    if ! unzip -q -o "$BACKUP_FILE" -d "$WP_PATH" >> "$LOG_FILE" 2>&1; then
        RESTORE_STATUS="error"
        RESTORE_MESSAGE="Ошибка при распаковке архива (zip)"
        echo "$RESTORE_MESSAGE" | tee -a "$LOG_FILE"
        echo "Подробности: $(tail -20 "$LOG_FILE")" | tee -a "$LOG_FILE"
        EXTRACT_ERROR=1
    else
        echo "Архив успешно распакован (zip)" | tee -a "$LOG_FILE"
    fi
else
    RESTORE_STATUS="error"
    RESTORE_MESSAGE="Неизвестный формат архива: $BACKUP_FILE"
    echo "$RESTORE_MESSAGE" | tee -a "$LOG_FILE"
    EXTRACT_ERROR=1
fi

# === Если была ошибка при распаковке - выходим ===
if [ $EXTRACT_ERROR -eq 1 ]; then
    # Удаляем архив даже при ошибке распаковки
    if [ -f "$RESTORE_DIR/$BACKUP_FILE" ]; then
        rm -f "$RESTORE_DIR/$BACKUP_FILE"
        echo "Архив удалён: $BACKUP_FILE" | tee -a "$LOG_FILE"
    fi
    send_webhook
    exit 1
fi

# === Устанавливаем правильного владельца файлов ===
echo "Устанавливаю владельца файлов для текущего домена: $USER:$USER..." | tee -a "$LOG_FILE"
chown -R "$USER":"$USER" "$WP_PATH" >> "$LOG_FILE" 2>&1 || {
    echo "Предупреждение: не удалось установить владельца файлов" | tee -a "$LOG_FILE"
}

# === Исправляем права для всех остальных доменов этого пользователя ===
echo "Проверяю и исправляю права для всех доменов пользователя $USER..." | tee -a "$LOG_FILE"
USER_WEB_PATH="/home/$USER/web"
if [ -d "$USER_WEB_PATH" ]; then
    for DOMAIN_DIR in "$USER_WEB_PATH"/*/ ; do
        if [ -d "$DOMAIN_DIR" ]; then
            DOMAIN_NAME=$(basename "$DOMAIN_DIR")
            echo "  - Исправляю права для домена: $DOMAIN_NAME" | tee -a "$LOG_FILE"
            chown -R "$USER":"$USER" "$DOMAIN_DIR" >> "$LOG_FILE" 2>&1 || true
        fi
    done
    echo "Права для всех доменов пользователя $USER исправлены" | tee -a "$LOG_FILE"
fi

# === Если это WordPress-сайт ===
if [[ "${IS_DONOR,,}" == "true" || "$IS_DONOR" == "1" ]]; then
    echo "Режим: WordPress (донор)" | tee -a "$LOG_FILE"

    # === Автоматическое определение местоположения WordPress ===
    CONFIG="$WP_PATH/wp-config.php"

    # Если wp-config.php не в корне, ищем его в подпапках
    if [ ! -f "$CONFIG" ]; then
        echo "wp-config.php не найден в корне, ищу в подпапках..." | tee -a "$LOG_FILE"

        # Ищем первый найденный wp-config.php
        FOUND_CONFIG=$(find "$WP_PATH" -maxdepth 2 -name "wp-config.php" -type f | head -n 1 || true)

        if [ -f "$FOUND_CONFIG" ]; then
            CONFIG="$FOUND_CONFIG"
            # Определяем папку, где находится WordPress
            WP_SUBDIR=$(dirname "$FOUND_CONFIG" | sed "s|$WP_PATH||" | sed 's|^/||')
            if [ -n "$WP_SUBDIR" ]; then
                echo "WordPress найден в подпапке: $WP_SUBDIR" | tee -a "$LOG_FILE"
                WP_PATH="$WP_PATH/$WP_SUBDIR"

                # Меняем document root для веб-сервера
                # Формат: v-change-web-domain-docroot USER DOMAIN TARGET_DOMAIN [DIRECTORY]
                echo "Изменяю document root на подпапку: $WP_SUBDIR" | tee -a "$LOG_FILE"
                echo "Выполняю: v-change-web-domain-docroot $USER $DOMAIN $DOMAIN $WP_SUBDIR" | tee -a "$LOG_FILE"

                DOCROOT_OUTPUT=$(v-change-web-domain-docroot "$USER" "$DOMAIN" "$DOMAIN" "$WP_SUBDIR" 2>&1) || DOCROOT_FAILED=$?

                if [ "${DOCROOT_FAILED:-0}" -ne 0 ]; then
                    echo "v-change-web-domain-docroot вернул код ошибки: $DOCROOT_FAILED" | tee -a "$LOG_FILE"
                    echo "Вывод команды: $DOCROOT_OUTPUT" | tee -a "$LOG_FILE"
                    echo "Предупреждение: не удалось изменить document root" | tee -a "$LOG_FILE"
                else
                    echo "Document root успешно изменен на подпапку: $WP_SUBDIR" | tee -a "$LOG_FILE"
                    echo "Вывод команды: $DOCROOT_OUTPUT" | tee -a "$LOG_FILE"
                fi
            fi
        else
            RESTORE_STATUS="error"
            RESTORE_MESSAGE="Ошибка: отсутствует wp-config.php в корне и подпапках"
            send_webhook
            exit 1
        fi
    fi

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

    # SQL дамп всегда в корне архива, ищем его рекурсивно в RESTORE_DIR и WP_PATH
    echo "Поиск SQL дампа..." | tee -a "$LOG_FILE"
    SQL_DUMP=$(find "$RESTORE_DIR" -type f \( -name "*.sql" -o -name "*.sql.gz" \) 2>/dev/null | head -n 1 || true)

    # Если не найден в RESTORE_DIR, ищем в WP_PATH (где распакован архив)
    if [ -z "$SQL_DUMP" ] || [ ! -f "$SQL_DUMP" ]; then
        SQL_DUMP=$(find "$WP_PATH" -type f \( -name "*.sql" -o -name "*.sql.gz" \) 2>/dev/null | head -n 1 || true)
    fi

    # Если WordPress в подпапке, SQL дамп может быть в родительской папке (в корне архива)
    if [ -z "$SQL_DUMP" ] || [ ! -f "$SQL_DUMP" ]; then
        PARENT_PATH=$(dirname "$WP_PATH")
        SQL_DUMP=$(find "$PARENT_PATH" -maxdepth 1 -type f \( -name "*.sql" -o -name "*.sql.gz" \) 2>/dev/null | head -n 1 || true)
        echo "Поиск SQL дампа в родительской папке: $PARENT_PATH" | tee -a "$LOG_FILE"
    fi

    echo "Найден SQL дамп: $SQL_DUMP" | tee -a "$LOG_FILE"
    if [ -n "$SQL_DUMP" ] && [ -f "$SQL_DUMP" ]; then
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

# === Удаляем архив при успешном восстановлении ===
if [ -f "$RESTORE_DIR/$BACKUP_FILE" ]; then
    rm -f "$RESTORE_DIR/$BACKUP_FILE"
    echo "Архив удалён: $BACKUP_FILE" | tee -a "$LOG_FILE"
fi

send_webhook
echo "=== End restore $DOMAIN at $(date '+%F %T') ===" | tee -a "$LOG_FILE"
exit 0
