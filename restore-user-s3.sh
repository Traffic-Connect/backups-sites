#!/bin/bash
# ==============================================
# Восстановление полного бэкапа пользователя из S3 Backblaze B2 архива
# ==============================================

set -euo pipefail
IFS=$'\n\t'

VERSION="v1"

export PATH=$PATH:/usr/local/hestia/bin

# === Проверка аргументов ===
if [ $# -lt 4 ]; then
    echo "Использование: $0 backup_url backup_id environment schema_id"
    # Example:
    # /usr/local/bin/restore-user-s3.sh "https://s3.eu-central-003.backblazeb2.com/T2-PFEU-backup/team2/team2.2025-12-10_05-10-40.tar?X-Amz-Content-Sha256=UNSIGNED-PAYLOAD&X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=00319641d3410660000000050%2F20251210%2Feu-central-003%2Fs3%2Faws4_request&X-Amz-Date=20251210T172010Z&X-Amz-SignedHeaders=host&X-Amz-Expires=3600&X-Amz-Signature=2bbdaf2b9e0f4ab4874ff8adf1cfc07bd297f5a773796581888988fbf7571aa8" 9 6b8c7090cff9.ngrok-free.app 21
    exit 1
fi

BACKUP_URL="$1"
BACKUP_ID="$2"
ENVIRONMENT="$3"
SCHEMA_ID="$4"
BACKUP_FILE=$(basename "$BACKUP_URL" | cut -d'?' -f1)  # Убираем query параметры из имени файла

RESTORE_STATUS="done"
RESTORE_MESSAGE="Восстановление пользователя выполнено успешно"

LOG_ROOT="/backup_restore"
RESTORE_DIR="$LOG_ROOT/schema_${SCHEMA_ID}"
mkdir -p "$RESTORE_DIR"
LOG_FILE="$RESTORE_DIR/restore-user.log"
echo "=== Start user restore schema_${SCHEMA_ID} at $(date '+%F %T') ===" > "$LOG_FILE"

echo "→ BACKUP_URL: $BACKUP_URL" | tee -a "$LOG_FILE"
echo "→ BACKUP_ID: $BACKUP_ID" | tee -a "$LOG_FILE"
echo "→ ENVIRONMENT: $ENVIRONMENT" | tee -a "$LOG_FILE"
echo "→ SCHEMA_ID: $SCHEMA_ID" | tee -a "$LOG_FILE"
echo "→ BACKUP_FILE: $BACKUP_FILE" | tee -a "$LOG_FILE"

# === Функция отправки webhook ===
send_webhook() {
    local WEBHOOK_URL="https://${ENVIRONMENT}/api/b2-webhooks/restore-user"
    echo "Отправляю webhook со статусом '$RESTORE_STATUS'..." | tee -a "$LOG_FILE"

    curl -s --max-time 15 -X POST "$WEBHOOK_URL" \
        -H "Content-Type: application/json" \
        -d @<(cat <<JSON
{
    "status": "$RESTORE_STATUS",
    "message": "$RESTORE_MESSAGE",
    "backup_id": "$BACKUP_ID",
    "archive": "$BACKUP_URL",
    "schema_id": "$SCHEMA_ID",
    "service": "s3"
}
JSON
) >> "$LOG_FILE" 2>&1 || true
}

# === Определяем пользователя на основе schema_id ===
SCHEMA_USER="schema_${SCHEMA_ID}"

echo "Целевой пользователь для восстановления: $SCHEMA_USER" | tee -a "$LOG_FILE"

# === Скачивание бэкапа ===
echo "Скачивание бэкапа..." | tee -a "$LOG_FILE"

cd "$RESTORE_DIR" || {
    RESTORE_STATUS="error"
    RESTORE_MESSAGE="Ошибка: не удалось перейти в каталог $RESTORE_DIR"
    send_webhook
    exit 1
}

# === Определяем способ скачивания ===
if [[ "$BACKUP_URL" == s3://* ]]; then
    echo "Тип ссылки: S3 (через AWS CLI)" | tee -a "$LOG_FILE"

    # === Получаем креды к Backblaze B2 ===
    CREDS=$(curl -s https://${ENVIRONMENT}/api/get-aws-creditnails)
    AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r '.data.B2_KEY_ID')
    AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r '.data.B2_APPLICATION_KEY')
    AWS_REGION=$(echo "$CREDS" | jq -r '.data.B2_REGION')
    AWS_ENDPOINT=$(echo "$CREDS" | jq -r '.data.B2_ENDPOINT')
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION="$AWS_REGION"

    if ! aws --endpoint-url "$AWS_ENDPOINT" s3 cp "$BACKUP_URL" . --no-progress --only-show-errors >> "$LOG_FILE" 2>&1; then
        RESTORE_STATUS="error"
        RESTORE_MESSAGE="Ошибка: архив не найден в S3 ($BACKUP_URL)"
        echo "$RESTORE_MESSAGE" | tee -a "$LOG_FILE"
        send_webhook
        exit 1
    fi
else
    echo "Тип ссылки: HTTPS (прямая загрузка)" | tee -a "$LOG_FILE"
    if ! curl -L -o "$BACKUP_FILE" "$BACKUP_URL" >> "$LOG_FILE" 2>&1; then
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

echo "Бэкап успешно скачан: $BACKUP_FILE" | tee -a "$LOG_FILE"

# === Проверка целостности скачанного файла ===
echo "Проверка целостности скачанного файла..." | tee -a "$LOG_FILE"
FILE_TYPE=$(file -b "$RESTORE_DIR/$BACKUP_FILE")
echo "Тип файла: $FILE_TYPE" | tee -a "$LOG_FILE"

if ! echo "$FILE_TYPE" | grep -qi "tar\|compressed"; then
    echo "✗ ОШИБКА: Скачанный файл не является tar архивом!" | tee -a "$LOG_FILE"
    echo "Возможно, URL истек или произошла ошибка при скачивании." | tee -a "$LOG_FILE"
    echo "Первые 500 байт файла:" | tee -a "$LOG_FILE"
    head -c 500 "$RESTORE_DIR/$BACKUP_FILE" | tee -a "$LOG_FILE"

    RESTORE_STATUS="error"
    RESTORE_MESSAGE="Ошибка: Скачанный файл не является tar архивом. Тип: $FILE_TYPE. Возможно, URL истек или файл поврежден."
    send_webhook
    exit 1
fi

echo "✓ Файл прошел проверку целостности" | tee -a "$LOG_FILE"

# === Проверяем, существует ли целевой пользователь ===
if v-list-user "$SCHEMA_USER" >/dev/null 2>&1; then
    echo "Пользователь $SCHEMA_USER уже существует. Удаляю перед восстановлением..." | tee -a "$LOG_FILE"

    # Удаляем существующего пользователя
    if ! v-delete-user "$SCHEMA_USER" yes >> "$LOG_FILE" 2>&1; then
        echo "Предупреждение: не удалось удалить существующего пользователя $SCHEMA_USER" | tee -a "$LOG_FILE"
    else
        echo "Пользователь $SCHEMA_USER успешно удален" | tee -a "$LOG_FILE"
    fi
fi

# === Создаем нового пользователя ===
echo "Создаю пользователя $SCHEMA_USER..." | tee -a "$LOG_FILE"
USER_PASSWORD=$(openssl rand -base64 16)
USER_EMAIL="schema_${SCHEMA_ID}@tcnct.com"

if ! v-add-user "$SCHEMA_USER" "$USER_PASSWORD" "$USER_EMAIL" >> "$LOG_FILE" 2>&1; then
    RESTORE_STATUS="error"
    RESTORE_MESSAGE="Ошибка: не удалось создать пользователя $SCHEMA_USER"
    send_webhook
    exit 1
fi

echo "Пользователь $SCHEMA_USER успешно создан" | tee -a "$LOG_FILE"

# === Проверка содержимого архива ===
echo "Проверка структуры архива..." | tee -a "$LOG_FILE"

# Определяем опции tar в зависимости от типа архива
TAR_OPTS="-tf"
if echo "$FILE_TYPE" | grep -qi "gzip"; then
    TAR_OPTS="-tzf"
    echo "Тип сжатия: gzip" | tee -a "$LOG_FILE"
elif echo "$FILE_TYPE" | grep -qi "bzip2"; then
    TAR_OPTS="-tjf"
    echo "Тип сжатия: bzip2" | tee -a "$LOG_FILE"
elif echo "$FILE_TYPE" | grep -qi "xz"; then
    TAR_OPTS="-tJf"
    echo "Тип сжатия: xz" | tee -a "$LOG_FILE"
else
    echo "Тип сжатия: без сжатия (обычный tar)" | tee -a "$LOG_FILE"
fi

ARCHIVE_CONTENTS=$(tar $TAR_OPTS "$RESTORE_DIR/$BACKUP_FILE" 2>/dev/null | head -20 || true)
echo "Содержимое архива (первые 20 строк):" | tee -a "$LOG_FILE"
echo "$ARCHIVE_CONTENTS" | tee -a "$LOG_FILE"

# Проверяем, является ли это бэкапом пользователя HestiaCP
# Используем уже полученное содержимое архива вместо повторного вызова tar
if echo "$ARCHIVE_CONTENTS" | grep -q "pam"; then
    echo "✓ Обнаружен формат бэкапа пользователя HestiaCP" | tee -a "$LOG_FILE"
else
    echo "✗ ВНИМАНИЕ: Архив не содержит структуру бэкапа пользователя HestiaCP" | tee -a "$LOG_FILE"
    echo "  Ожидается наличие папки ./pam в корне архива" | tee -a "$LOG_FILE"

    RESTORE_STATUS="error"
    RESTORE_MESSAGE="Ошибка: Архив не является бэкапом пользователя HestiaCP. Отсутствует ./pam. Используйте полный бэкап пользователя, созданный через v-backup-user."
    send_webhook
    exit 1
fi

# === Копируем бэкап в директорию бэкапов Hestia ===
HESTIA_BACKUP_DIR="/backup"
mkdir -p "$HESTIA_BACKUP_DIR"

# Формируем правильное имя для Hestia (с текущим пользователем)
HESTIA_BACKUP_FILE="${SCHEMA_USER}.$(date '+%Y-%m-%d_%H-%M-%S').tar"

echo "Копирую бэкап в директорию Hestia: $HESTIA_BACKUP_DIR/$HESTIA_BACKUP_FILE" | tee -a "$LOG_FILE"
cp "$RESTORE_DIR/$BACKUP_FILE" "$HESTIA_BACKUP_DIR/$HESTIA_BACKUP_FILE" >> "$LOG_FILE" 2>&1 || {
    RESTORE_STATUS="error"
    RESTORE_MESSAGE="Ошибка: не удалось скопировать бэкап в директорию Hestia"
    send_webhook
    exit 1
}

# === Восстанавливаем пользователя через v-restore-user ===
echo "Запуск v-restore-user для восстановления пользователя $SCHEMA_USER..." | tee -a "$LOG_FILE"

# v-restore-user принимает: USER BACKUP [NOTIFY]
# Запускаем восстановление
RESTORE_OUTPUT=$(v-restore-user "$SCHEMA_USER" "$HESTIA_BACKUP_FILE" "no" 2>&1) || RESTORE_FAILED=$?

if [ "${RESTORE_FAILED:-0}" -ne 0 ]; then
    echo "v-restore-user вернул код ошибки: $RESTORE_FAILED" | tee -a "$LOG_FILE"
    echo "Вывод команды: $RESTORE_OUTPUT" | tee -a "$LOG_FILE"
    RESTORE_STATUS="error"
    RESTORE_MESSAGE="Ошибка восстановления пользователя: $RESTORE_OUTPUT"

    # Удаляем файл бэкапа из директории Hestia
    rm -f "$HESTIA_BACKUP_DIR/$HESTIA_BACKUP_FILE" >> "$LOG_FILE" 2>&1 || true

    send_webhook
    exit 1
else
    echo "Пользователь $SCHEMA_USER успешно восстановлен" | tee -a "$LOG_FILE"
    echo "Вывод v-restore-user: $RESTORE_OUTPUT" | tee -a "$LOG_FILE"
fi

# === Пересборка и обновление статистики ===
echo "Обновление конфигурации и статистики..." | tee -a "$LOG_FILE"
v-rebuild-web-domains "$SCHEMA_USER" >> "$LOG_FILE" 2>&1 || true
v-update-user-stats "$SCHEMA_USER" >> "$LOG_FILE" 2>&1 || true

# === Удаляем временные файлы ===
echo "Очистка временных файлов..." | tee -a "$LOG_FILE"

# Удаляем скачанный файл
if [ -f "$RESTORE_DIR/$BACKUP_FILE" ]; then
    rm -f "$RESTORE_DIR/$BACKUP_FILE"
    echo "Удален временный файл: $RESTORE_DIR/$BACKUP_FILE" | tee -a "$LOG_FILE"
fi

# Удаляем файл из директории Hestia
if [ -f "$HESTIA_BACKUP_DIR/$HESTIA_BACKUP_FILE" ]; then
    rm -f "$HESTIA_BACKUP_DIR/$HESTIA_BACKUP_FILE"
    echo "Удален файл бэкапа из Hestia: $HESTIA_BACKUP_DIR/$HESTIA_BACKUP_FILE" | tee -a "$LOG_FILE"
fi

# === Получаем информацию о восстановленных доменах ===
RESTORED_DOMAINS=$(v-list-web-domains "$SCHEMA_USER" plain 2>/dev/null | awk '{print $1}' | tr '\n' ',' | sed 's/,$//' || echo "нет доменов")
echo "Восстановленные домены: $RESTORED_DOMAINS" | tee -a "$LOG_FILE"

RESTORE_MESSAGE="Пользователь schema_${SCHEMA_ID} успешно восстановлен. Домены: $RESTORED_DOMAINS"

# === Отправка webhook ===
send_webhook

echo "=== End user restore schema_${SCHEMA_ID} at $(date '+%F %T') ===" | tee -a "$LOG_FILE"
exit 0
