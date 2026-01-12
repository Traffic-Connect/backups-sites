#!/bin/bash
# ==============================================
# Восстановление полного бэкапа пользователя из S3 Backblaze B2 архива
# ==============================================

set -euo pipefail
IFS=$'\n\t'

VERSION="v2"

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

# Директории
LOG_ROOT="/backup_restore"
LOG_DIR="$LOG_ROOT/schema_${SCHEMA_ID}"
BACKUP_DIR="/backup"

# Создаем директории
mkdir -p "$LOG_DIR"
mkdir -p "$BACKUP_DIR"

# Файлы
LOG_FILE="$LOG_DIR/restore-user.log"
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

# === Функция логирования с отправкой webhook о прогрессе ===
log_progress() {
    local message="$1"
    echo "$message" | tee -a "$LOG_FILE"

    # Отправляем webhook о прогрессе
    RESTORE_STATUS="progress"
    RESTORE_MESSAGE="$message"
    send_webhook
}

# === Определяем пользователя на основе schema_id ===
SCHEMA_USER="schema_${SCHEMA_ID}"

echo "Целевой пользователь для восстановления: $SCHEMA_USER" | tee -a "$LOG_FILE"

# Формируем имя файла для Hestia (с текущим пользователем и временной меткой)
HESTIA_BACKUP_FILE="${SCHEMA_USER}.$(date '+%Y-%m-%d_%H-%M-%S').tar"
BACKUP_FILE_PATH="$BACKUP_DIR/$HESTIA_BACKUP_FILE"

echo "→ BACKUP_FILE_PATH: $BACKUP_FILE_PATH" | tee -a "$LOG_FILE"

# === Скачивание бэкапа ===
log_progress "Скачивание бэкапа в $BACKUP_FILE_PATH..."

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

    if ! aws --endpoint-url "$AWS_ENDPOINT" s3 cp "$BACKUP_URL" "$BACKUP_FILE_PATH" --no-progress --only-show-errors >> "$LOG_FILE" 2>&1; then
        RESTORE_STATUS="error"
        RESTORE_MESSAGE="Ошибка: архив не найден в S3 ($BACKUP_URL)"
        echo "$RESTORE_MESSAGE" | tee -a "$LOG_FILE"
        send_webhook
        exit 1
    fi
else
    echo "Тип ссылки: HTTPS (прямая загрузка)" | tee -a "$LOG_FILE"
    if ! curl -L -o "$BACKUP_FILE_PATH" "$BACKUP_URL" >> "$LOG_FILE" 2>&1; then
        RESTORE_STATUS="error"
        RESTORE_MESSAGE="Ошибка: не удалось скачать архив по ссылке"
        send_webhook
        exit 1
    fi
fi

# === Проверка результата скачивания ===
if [ ! -f "$BACKUP_FILE_PATH" ]; then
    RESTORE_STATUS="error"
    RESTORE_MESSAGE="Ошибка: архив не скачан"
    echo "$RESTORE_MESSAGE" | tee -a "$LOG_FILE"
    send_webhook
    exit 1
fi

log_progress "Бэкап успешно скачан: $BACKUP_FILE_PATH"

# === Проверка целостности скачанного файла ===
log_progress "Проверка целостности скачанного файла..."
FILE_TYPE=$(file -b "$BACKUP_FILE_PATH")
echo "Тип файла: $FILE_TYPE" | tee -a "$LOG_FILE"

if ! echo "$FILE_TYPE" | grep -qi "tar\|compressed"; then
    echo "✗ ОШИБКА: Скачанный файл не является tar архивом!" | tee -a "$LOG_FILE"
    echo "Возможно, URL истек или произошла ошибка при скачивании." | tee -a "$LOG_FILE"
    echo "Первые 500 байт файла:" | tee -a "$LOG_FILE"
    head -c 500 "$BACKUP_FILE_PATH" | tee -a "$LOG_FILE"

    RESTORE_STATUS="error"
    RESTORE_MESSAGE="Ошибка: Скачанный файл не является tar архивом. Тип: $FILE_TYPE. Возможно, URL истек или файл поврежден."
    send_webhook
    exit 1
fi

log_progress "✓ Файл прошел проверку целостности"

## === Проверяем, существует ли целевой пользователь ===
#if v-list-user "$SCHEMA_USER" >/dev/null 2>&1; then
#    log_progress "Пользователь $SCHEMA_USER уже существует. Удаляю перед восстановлением..."
#
#    # Удаляем существующего пользователя
#    if ! v-delete-user "$SCHEMA_USER" yes >> "$LOG_FILE" 2>&1; then
#        echo "Предупреждение: не удалось удалить существующего пользователя $SCHEMA_USER" | tee -a "$LOG_FILE"
#    else
#        log_progress "Пользователь $SCHEMA_USER успешно удален"
#    fi
#fi
#
## === Создаем нового пользователя ===
#log_progress "Создаю пользователя $SCHEMA_USER..."
#USER_PASSWORD=$(openssl rand -base64 16)
#USER_EMAIL="schema_${SCHEMA_ID}@tcnct.com"
#
#if ! v-add-user "$SCHEMA_USER" "$USER_PASSWORD" "$USER_EMAIL" >> "$LOG_FILE" 2>&1; then
#    RESTORE_STATUS="error"
#    RESTORE_MESSAGE="Ошибка: не удалось создать пользователя $SCHEMA_USER"
#    send_webhook
#    exit 1
#fi
#
#log_progress "Пользователь $SCHEMA_USER успешно создан"

# === Проверка содержимого архива ===
log_progress "Проверка структуры архива..."

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

ARCHIVE_CONTENTS=$(tar $TAR_OPTS "$BACKUP_FILE_PATH" 2>/dev/null | head -20 || true)
echo "Содержимое архива (первые 20 строк):" | tee -a "$LOG_FILE"
echo "$ARCHIVE_CONTENTS" | tee -a "$LOG_FILE"

# Проверяем, является ли это бэкапом пользователя HestiaCP
# Ищем директорию pam/ во всем архиве, а не только в первых 20 строках
if tar $TAR_OPTS "$BACKUP_FILE_PATH" 2>/dev/null | grep -q "/pam/\|^pam/\|^\./pam/"; then
    log_progress "✓ Обнаружен формат бэкапа пользователя HestiaCP"
else
    echo "✗ ВНИМАНИЕ: Архив не содержит структуру бэкапа пользователя HestiaCP" | tee -a "$LOG_FILE"
    echo "  Ожидается наличие папки ./pam в корне архива" | tee -a "$LOG_FILE"
    echo "  Содержимое архива (первые 30 строк):" | tee -a "$LOG_FILE"
    tar $TAR_OPTS "$BACKUP_FILE_PATH" 2>/dev/null | head -30 | tee -a "$LOG_FILE"

    RESTORE_STATUS="error"
    RESTORE_MESSAGE="Ошибка: Архив не является бэкапом пользователя HestiaCP. Отсутствует ./pam. Используйте полный бэкап пользователя, созданный через v-backup-user."
    send_webhook
    exit 1
fi

# === Бэкап уже находится в /backup, готов к использованию ===
log_progress "Бэкап готов к восстановлению: $BACKUP_FILE_PATH"

# === Восстанавливаем пользователя через v-restore-user ===
log_progress "Запуск v-restore-user для восстановления пользователя $SCHEMA_USER..."

# v-restore-user принимает: USER BACKUP [NOTIFY]
# Запускаем восстановление с повторными попытками при высоком Load Average
MAX_RETRIES=10
RETRY_DELAY=300  # 5 минут между попытками
RETRY_COUNT=0
RESTORE_FAILED=1

while [ $RETRY_COUNT -lt $MAX_RETRIES ] && [ ${RESTORE_FAILED:-1} -ne 0 ]; do
    if [ $RETRY_COUNT -gt 0 ]; then
        echo "Попытка $((RETRY_COUNT + 1)) из $MAX_RETRIES после ожидания ${RETRY_DELAY}с..." | tee -a "$LOG_FILE"
    fi

    # Создаем временный файл для вывода команды
    RESTORE_OUTPUT_FILE=$(mktemp)

    # Запускаем v-restore-user с таймаутом 20 минут и выводом в реальном времени
    echo "$(date '+%F %T') Выполняю v-restore-user (таймаут 20 минут)..." | tee -a "$LOG_FILE"

    # Запускаем команду с tee для вывода в реальном времени
    set +e
    timeout 1200 v-restore-user "$SCHEMA_USER" "$HESTIA_BACKUP_FILE" "no" 2>&1 | tee -a "$LOG_FILE" > "$RESTORE_OUTPUT_FILE"
    RESTORE_FAILED=${PIPESTATUS[0]}
    set -e

    # Читаем вывод команды
    RESTORE_OUTPUT=$(cat "$RESTORE_OUTPUT_FILE")
    rm -f "$RESTORE_OUTPUT_FILE"

    echo "$(date '+%F %T') v-restore-user завершился с кодом: $RESTORE_FAILED" | tee -a "$LOG_FILE"

    # Проверяем, не связана ли ошибка с Load Average или таймаутом
    if [ "${RESTORE_FAILED:-0}" -eq 124 ]; then
        # Таймаут команды (124 = код возврата timeout при превышении лимита)
        echo "Команда v-restore-user превысила таймаут 20 минут" | tee -a "$LOG_FILE"
        RETRY_COUNT=$((RETRY_COUNT + 1))

        # Отправляем webhook о каждой повторной попытке
        RESTORE_STATUS="progress"
        RESTORE_MESSAGE="v-restore-user превысила таймаут (возможно из-за высокого Load Average). Попытка $RETRY_COUNT из $MAX_RETRIES. Следующая попытка через $((RETRY_DELAY / 60)) минут"
        send_webhook

        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
            echo "Ожидание ${RETRY_DELAY}с перед повторной попыткой..." | tee -a "$LOG_FILE"
            sleep $RETRY_DELAY
        else
            echo "Достигнуто максимальное количество попыток ($MAX_RETRIES)" | tee -a "$LOG_FILE"
        fi
    elif [ "${RESTORE_FAILED:-0}" -ne 0 ] && echo "$RESTORE_OUTPUT" | grep -qi "LoadAverage.*above threshold"; then
        # Ошибка Load Average
        RETRY_COUNT=$((RETRY_COUNT + 1))

        # Отправляем webhook о каждой повторной попытке
        RESTORE_STATUS="progress"
        RESTORE_MESSAGE="Load Average выше порога. Попытка $RETRY_COUNT из $MAX_RETRIES. Следующая попытка через $((RETRY_DELAY / 60)) минут"
        send_webhook

        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
            echo "Load Average выше порога. Ожидание ${RETRY_DELAY}с перед повторной попыткой..." | tee -a "$LOG_FILE"
            sleep $RETRY_DELAY
        else
            echo "Достигнуто максимальное количество попыток ($MAX_RETRIES)" | tee -a "$LOG_FILE"
        fi
    else
        # Другая ошибка или успех - прерываем цикл
        break
    fi
done

if [ "${RESTORE_FAILED:-0}" -ne 0 ]; then
    echo "v-restore-user вернул код ошибки: $RESTORE_FAILED после $RETRY_COUNT попыток" | tee -a "$LOG_FILE"
    echo "Вывод команды: $RESTORE_OUTPUT" | tee -a "$LOG_FILE"
    RESTORE_STATUS="error"
    RESTORE_MESSAGE="Ошибка восстановления пользователя после $RETRY_COUNT попыток: $RESTORE_OUTPUT"

    # Удаляем файл бэкапа
    rm -f "$BACKUP_FILE_PATH" >> "$LOG_FILE" 2>&1 || true

    send_webhook
    exit 1
else
    log_progress "Пользователь $SCHEMA_USER успешно восстановлен"
    echo "Вывод v-restore-user: $RESTORE_OUTPUT" | tee -a "$LOG_FILE"
fi

# === Пересборка и обновление статистики ===
log_progress "Обновление конфигурации и статистики..."
v-rebuild-web-domains "$SCHEMA_USER" >> "$LOG_FILE" 2>&1 || true
v-update-user-stats "$SCHEMA_USER" >> "$LOG_FILE" 2>&1 || true

# === Удаляем временные файлы ===
log_progress "Очистка временных файлов..."

# Удаляем файл бэкапа
if [ -f "$BACKUP_FILE_PATH" ]; then
    rm -f "$BACKUP_FILE_PATH"
    echo "Удален файл бэкапа: $BACKUP_FILE_PATH" | tee -a "$LOG_FILE"
fi

# === Получаем информацию о восстановленных доменах ===
RESTORED_DOMAINS=$(v-list-web-domains "$SCHEMA_USER" plain 2>/dev/null | awk '{print $1}' | tr '\n' ',' | sed 's/,$//' || echo "нет доменов")
echo "Восстановленные домены: $RESTORED_DOMAINS" | tee -a "$LOG_FILE"

# Устанавливаем статус успеха (может быть перезаписан, если был "retrying")
RESTORE_STATUS="done"
if [ $RETRY_COUNT -gt 0 ]; then
    RESTORE_MESSAGE="Пользователь schema_${SCHEMA_ID} успешно восстановлен после $RETRY_COUNT повторных попыток из-за высокого Load Average. Домены: $RESTORED_DOMAINS"
else
    RESTORE_MESSAGE="Пользователь schema_${SCHEMA_ID} успешно восстановлен. Домены: $RESTORED_DOMAINS"
fi

# === Отправка webhook ===
send_webhook

echo "=== End user restore schema_${SCHEMA_ID} at $(date '+%F %T') ===" | tee -a "$LOG_FILE"
exit 0
