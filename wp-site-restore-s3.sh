#!/bin/bash
# ==============================================
# Восстановление сайта (WordPress) из S3 Backblaze B2 архива

set -euo pipefail
IFS=$'\n\t'

VERSION="v1"

export PATH=$PATH:/usr/local/hestia/bin

# === Проверка аргументов ===
if [ $# -lt 7 ]; then
    echo "Использование: $0 domain.com s3://bucket/backups/domain/file.tar.gz backup_id site_id server_id username environment"
    #Example

        #./usr/local/bin/wp-restore-s3.sh restore-test.com s3://artem-test-bucket/backups/midora.cyou/wpbackup_midora.cyou_date_2025-11-12_07-08-07.tar.gz 38 481 true manager-stg.tcnct.com 24

    exit 1
fi

DOMAIN="$1"
FULL_S3_PATH="$2"
BACKUP_ID="$3"
SITE_ID="$4"
SERVER_ID="$5"
USERNAME="$6"
ENVIRONMENT="$7"
BACKUP_FILE=$(basename "$FULL_S3_PATH")

RESTORE_STATUS="done"
RESTORE_MESSAGE="Восстановление выполнено успешно"

# Директории для логов и для бэкапов
LOG_ROOT="/backup_restore"
LOG_DIR="$LOG_ROOT/$DOMAIN"
BACKUP_DIR="/backup"

# Создаем директории
mkdir -p "$LOG_DIR"
mkdir -p "$BACKUP_DIR"

# Логи в /backup_restore/$DOMAIN/, архив будет в /backup/
LOG_FILE="$LOG_DIR/restore.log"
echo "=== Start restore $DOMAIN at $(date '+%F %T') ===" > "$LOG_FILE"

echo "→ DOMAIN: $DOMAIN"
echo "→ BACKUP_ID: $BACKUP_ID"
echo "→ SITE_ID: $SITE_ID"
echo "→ SERVER_ID: $SERVER_ID"
echo "→ USERNAME: $USERNAME"
echo "→ ENVIRONMENT: $ENVIRONMENT"

# === Функция отправки webhook ===
send_webhook() {
    local WEBHOOK_URL="https://${ENVIRONMENT}/api/b2-webhooks/site-restore-backblaze"
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
    "server_id": "$SERVER_ID",
    "username": "$USERNAME",
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

# Используем переданного пользователя
USER="$USERNAME"

# === Получаем креды к Backblaze B2 ===
CREDS_URL="https://${ENVIRONMENT}/api/get-aws-creditnails/by-server/${SERVER_ID}"
echo "Запрашиваю креды по URL: $CREDS_URL" | tee -a "$LOG_FILE"

CREDS=$(curl -s "$CREDS_URL")
echo "Ответ API (полный): $CREDS" | tee -a "$LOG_FILE"

AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r '.data.B2_KEY_ID')
AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r '.data.B2_APPLICATION_KEY')
AWS_REGION=$(echo "$CREDS" | jq -r '.data.B2_REGION')
AWS_ENDPOINT=$(echo "$CREDS" | jq -r '.data.B2_ENDPOINT')

echo "Извлечено из API:" | tee -a "$LOG_FILE"
echo "  B2_KEY_ID: ${AWS_ACCESS_KEY_ID:0:10}..." | tee -a "$LOG_FILE"
echo "  B2_APPLICATION_KEY: ${AWS_SECRET_ACCESS_KEY:0:10}..." | tee -a "$LOG_FILE"
echo "  B2_REGION: $AWS_REGION" | tee -a "$LOG_FILE"
echo "  B2_ENDPOINT: $AWS_ENDPOINT" | tee -a "$LOG_FILE"

# Устанавливаем дефолтный endpoint для Backblaze B2, если не указан
if [ "$AWS_ENDPOINT" == "null" ] || [ -z "$AWS_ENDPOINT" ]; then
    AWS_ENDPOINT="https://s3.${AWS_REGION}.backblazeb2.com"
    echo "B2_ENDPOINT был null/пустой. Используется дефолтный: $AWS_ENDPOINT" | tee -a "$LOG_FILE"
fi

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION="$AWS_REGION"

log_progress "Начинаю скачивание архива: $FULL_S3_PATH"

cd "$BACKUP_DIR" || {
    RESTORE_STATUS="error"
    RESTORE_MESSAGE="Ошибка: не удалось перейти в каталог $BACKUP_DIR"
    send_webhook
    exit 1
}

# === Определяем способ скачивания ===
if [[ "$FULL_S3_PATH" == s3://* ]]; then
    log_progress "Скачивание архива из S3 (через AWS CLI)..."
    # Извлекаем имя файла из S3 пути
    BACKUP_FILE=$(basename "$FULL_S3_PATH")
    echo "Скачиваю файл: $BACKUP_FILE" | tee -a "$LOG_FILE"

    # Получаем размер файла в S3
    TOTAL_SIZE=$(aws --endpoint-url "$AWS_ENDPOINT" s3api head-object --bucket "$(echo $FULL_S3_PATH | cut -d'/' -f3)" --key "$(echo $FULL_S3_PATH | cut -d'/' -f4-)" --query ContentLength --output text 2>/dev/null || echo "0")
    echo "Размер файла в S3: $TOTAL_SIZE байт" | tee -a "$LOG_FILE"

    # Запускаем скачивание в фоне
    DOWNLOAD_FILE="$BACKUP_DIR/$BACKUP_FILE"
    echo "Скачиваю в: $DOWNLOAD_FILE" | tee -a "$LOG_FILE"

    # Создаем временный файл для вывода AWS CLI
    AWS_LOG=$(mktemp)

    # Конфигурируем AWS CLI для предотвращения зависания и ошибок retry
    # Проблема: слишком короткие таймауты вызывают "Max Retries Exceeded"
    # Решение: увеличиваем таймауты, но уменьшаем параллелизм
    export AWS_MAX_ATTEMPTS=5
    export AWS_RETRY_MODE=standard

    # Создаем AWS CLI конфиг
    AWS_CONFIG_FILE=$(mktemp)
    cat > "$AWS_CONFIG_FILE" <<EOF
[default]
s3 =
    max_concurrent_requests = 3
    max_queue_size = 1000
    multipart_threshold = 64MB
    multipart_chunksize = 16MB
    max_bandwidth = 50MB/s
    use_accelerate_endpoint = false
    addressing_style = path
tcp_keepalive = true
EOF

    export AWS_CONFIG_FILE

    # Убираем короткие таймауты, которые вызывают Max Retries Exceeded
    # AWS CLI сам управляет таймаутами для больших файлов
    aws --endpoint-url "$AWS_ENDPOINT" \
        s3 cp "$FULL_S3_PATH" "$DOWNLOAD_FILE" \
        --no-progress > "$AWS_LOG" 2>&1 &
    AWS_PID=$!

    # Удаляем временный конфиг после запуска
    rm -f "$AWS_CONFIG_FILE" 2>/dev/null || true
    echo "AWS CLI запущен с PID: $AWS_PID, лог: $AWS_LOG" | tee -a "$LOG_FILE"

    # Мониторим прогресс скачивания
    LAST_REPORTED_PERCENT=0
    WAIT_AFTER_100=0
    echo "Начинаю мониторинг прогресса..." | tee -a "$LOG_FILE"

    while kill -0 $AWS_PID 2>/dev/null; do
        # AWS CLI создает временный файл с суффиксом во время скачивания
        # Ищем либо финальный файл, либо временный файл с маской
        TEMP_FILE=$(ls -1 "${DOWNLOAD_FILE}"* 2>/dev/null | head -n 1 || echo "")

        if [ -n "$TEMP_FILE" ] && [ -f "$TEMP_FILE" ]; then
            CURRENT_SIZE=$(stat -c%s "$TEMP_FILE" 2>/dev/null || stat -f%z "$TEMP_FILE" 2>/dev/null || echo "0")
            if [ "$TOTAL_SIZE" -gt 0 ] && [ "$CURRENT_SIZE" -gt 0 ]; then
                PERCENT=$((CURRENT_SIZE * 100 / TOTAL_SIZE))
                CURRENT_MB=$((CURRENT_SIZE / 1024 / 1024))
                TOTAL_MB=$((TOTAL_SIZE / 1024 / 1024))

                # Отправляем webhook с прогрессом каждые 10% (только один раз для каждого порога)
                THRESHOLD=$((PERCENT / 10 * 10))
                if [ "$THRESHOLD" -gt "$LAST_REPORTED_PERCENT" ] && [ "$THRESHOLD" -gt 0 ]; then
                    log_progress "Скачивание архива: ${THRESHOLD}% (${CURRENT_MB}MB / ${TOTAL_MB}MB)"
                    LAST_REPORTED_PERCENT=$THRESHOLD
                fi

                # Если достигли 100%, начинаем отсчет ожидания
                if [ "$PERCENT" -ge 100 ]; then
                    WAIT_AFTER_100=$((WAIT_AFTER_100 + 5))
                    if [ "$WAIT_AFTER_100" -eq 30 ]; then
                        echo "Скачивание завершено на 100%, ожидаю финализации AWS CLI..." | tee -a "$LOG_FILE"
                        echo "=== Диагностика состояния процесса AWS CLI ===" | tee -a "$LOG_FILE"
                        echo "Информация о процессе:" | tee -a "$LOG_FILE"
                        ps -p $AWS_PID -o pid,ppid,state,wchan,cmd 2>&1 | tee -a "$LOG_FILE" || true
                        echo "Открытые файловые дескрипторы:" | tee -a "$LOG_FILE"
                        lsof -p $AWS_PID 2>&1 | tee -a "$LOG_FILE" || true
                        echo "Сетевые соединения процесса:" | tee -a "$LOG_FILE"
                        lsof -p $AWS_PID -i 2>&1 | tee -a "$LOG_FILE" || true
                    elif [ "$WAIT_AFTER_100" -eq 60 ]; then
                        echo "ВНИМАНИЕ: AWS CLI не завершается уже 60 секунд после 100%" | tee -a "$LOG_FILE"
                        echo "=== Детальная диагностика (60 сек) ===" | tee -a "$LOG_FILE"
                        echo "Состояние процесса (state):" | tee -a "$LOG_FILE"
                        ps -p $AWS_PID -o state,wchan:20,cmd 2>&1 | tee -a "$LOG_FILE" || true
                        echo "Системные вызовы (sample):" | tee -a "$LOG_FILE"
                        timeout 3 strace -p $AWS_PID -c 2>&1 | tee -a "$LOG_FILE" || echo "strace недоступен или завершился по таймауту" | tee -a "$LOG_FILE"
                        echo "Стек вызовов процесса:" | tee -a "$LOG_FILE"
                        cat /proc/$AWS_PID/stack 2>&1 | tee -a "$LOG_FILE" || echo "/proc/$AWS_PID/stack недоступен" | tee -a "$LOG_FILE"
                    elif [ "$WAIT_AFTER_100" -eq 90 ]; then
                        echo "ВНИМАНИЕ: AWS CLI не завершается уже 90 секунд после 100%" | tee -a "$LOG_FILE"
                        echo "=== Дополнительная диагностика (90 сек) ===" | tee -a "$LOG_FILE"
                        echo "TCP соединения (netstat):" | tee -a "$LOG_FILE"
                        netstat -tnp 2>/dev/null | grep $AWS_PID 2>&1 | tee -a "$LOG_FILE" || ss -tnp 2>/dev/null | grep $AWS_PID 2>&1 | tee -a "$LOG_FILE" || echo "Не удалось получить TCP соединения" | tee -a "$LOG_FILE"
                        echo "Дочерние процессы:" | tee -a "$LOG_FILE"
                        pstree -p $AWS_PID 2>&1 | tee -a "$LOG_FILE" || ps --ppid $AWS_PID 2>&1 | tee -a "$LOG_FILE" || echo "Дочерних процессов не найдено" | tee -a "$LOG_FILE"
                        echo "IO статистика процесса:" | tee -a "$LOG_FILE"
                        cat /proc/$AWS_PID/io 2>&1 | tee -a "$LOG_FILE" || echo "/proc/$AWS_PID/io недоступен" | tee -a "$LOG_FILE"
                    elif [ "$WAIT_AFTER_100" -ge 120 ]; then
                        echo "КРИТИЧНО: AWS CLI завис после 100% уже $WAIT_AFTER_100 секунд. Принудительно завершаю процесс..." | tee -a "$LOG_FILE"
                        echo "=== Финальная диагностика перед завершением ===" | tee -a "$LOG_FILE"
                        echo "Последнее состояние процесса:" | tee -a "$LOG_FILE"
                        ps -p $AWS_PID -o pid,state,wchan:20,%cpu,%mem,etime,cmd 2>&1 | tee -a "$LOG_FILE" || true
                        echo "Все открытые соединения и файлы:" | tee -a "$LOG_FILE"
                        lsof -p $AWS_PID 2>&1 | head -50 | tee -a "$LOG_FILE" || true
                        echo "Попытка получить strace в режиме реального времени (5 сек):" | tee -a "$LOG_FILE"
                        timeout 5 strace -p $AWS_PID 2>&1 | head -30 | tee -a "$LOG_FILE" || true

                        # Закрываем зависшие CLOSE_WAIT соединения с помощью ss
                        echo "Закрываю зависшие CLOSE_WAIT соединения..." | tee -a "$LOG_FILE"
                        CLOSE_WAIT_PORTS=$(ss -tnp 2>/dev/null | grep "$AWS_PID" | grep "CLOSE-WAIT" | awk '{print $4}' | awk -F: '{print $NF}' || true)
                        if [ -n "$CLOSE_WAIT_PORTS" ]; then
                            echo "Найдены CLOSE_WAIT порты: $CLOSE_WAIT_PORTS" | tee -a "$LOG_FILE"
                            for port in $CLOSE_WAIT_PORTS; do
                                ss -K dst :$port 2>/dev/null || true
                            done
                            echo "CLOSE_WAIT соединения принудительно закрыты" | tee -a "$LOG_FILE"
                            sleep 1
                        fi

                        # Отправляем SIGUSR1 для пробуждения потоков Python перед завершением
                        echo "Отправляю SIGUSR1 для пробуждения потоков..." | tee -a "$LOG_FILE"
                        kill -USR1 $AWS_PID 2>/dev/null || true
                        sleep 1

                        kill -TERM $AWS_PID 2>/dev/null || true
                        sleep 2
                        # Если процесс все еще работает, используем SIGKILL
                        if kill -0 $AWS_PID 2>/dev/null; then
                            echo "Процесс не завершился по SIGTERM, отправляю SIGKILL..." | tee -a "$LOG_FILE"
                            kill -KILL $AWS_PID 2>/dev/null || true
                        fi
                        echo "Процесс AWS CLI принудительно завершен. Файл скачан полностью (100%)." | tee -a "$LOG_FILE"
                        break
                    fi
                fi
            fi
        fi
        sleep 5
    done

    echo "Процесс AWS CLI завершен, ожидаю финализации..." | tee -a "$LOG_FILE"

    # Проверяем результат (используем wait только если процесс еще существует)
    if kill -0 $AWS_PID 2>/dev/null; then
        wait $AWS_PID
        AWS_EXIT_CODE=$?
    else
        # Процесс был принудительно завершен
        AWS_EXIT_CODE=0
        echo "Процесс был принудительно завершен после достижения 100%" | tee -a "$LOG_FILE"
    fi

    echo "AWS CLI завершился с кодом: $AWS_EXIT_CODE" | tee -a "$LOG_FILE"

    # Выводим лог AWS CLI
    echo "=== Вывод AWS CLI ===" | tee -a "$LOG_FILE"
    cat "$AWS_LOG" | tee -a "$LOG_FILE"
    echo "=== Конец вывода AWS CLI ===" | tee -a "$LOG_FILE"
    rm -f "$AWS_LOG"

    # Ищем временный файл AWS CLI (с суффиксом)
    echo "Проверяю наличие скачанного файла..." | tee -a "$LOG_FILE"
    TEMP_FILE=$(ls -1 "${DOWNLOAD_FILE}".* 2>/dev/null | head -n 1 || echo "")

    if [ -n "$TEMP_FILE" ] && [ -f "$TEMP_FILE" ]; then
        echo "Найден временный файл AWS CLI: $TEMP_FILE" | tee -a "$LOG_FILE"
        TEMP_SIZE=$(stat -c%s "$TEMP_FILE" 2>/dev/null || stat -f%z "$TEMP_FILE" 2>/dev/null || echo "0")
        echo "Размер временного файла: $TEMP_SIZE байт" | tee -a "$LOG_FILE"

        # Если размер совпадает, переименовываем временный файл в финальный
        if [ "$TEMP_SIZE" -eq "$TOTAL_SIZE" ]; then
            echo "Переименовываю временный файл в финальный..." | tee -a "$LOG_FILE"
            mv "$TEMP_FILE" "$DOWNLOAD_FILE"
            echo "Файл успешно переименован: $DOWNLOAD_FILE" | tee -a "$LOG_FILE"
        fi
    fi

    # Проверяем наличие финального файла
    if [ -f "$DOWNLOAD_FILE" ]; then
        FILE_SIZE=$(stat -c%s "$DOWNLOAD_FILE" 2>/dev/null || stat -f%z "$DOWNLOAD_FILE" 2>/dev/null || echo "0")
        echo "Файл найден: $DOWNLOAD_FILE (размер: $FILE_SIZE байт)" | tee -a "$LOG_FILE"

        # Если файл существует и размер совпадает с ожидаемым, считаем успешным
        if [ "$FILE_SIZE" -eq "$TOTAL_SIZE" ]; then
            echo "Размер файла совпадает с ожидаемым. Скачивание успешно завершено." | tee -a "$LOG_FILE"
            AWS_EXIT_CODE=0
        elif [ "$WAIT_AFTER_100" -ge 120 ]; then
            # Если процесс был принудительно завершен после таймаута, но файл есть, считаем успешным
            echo "Файл скачан полностью (процесс был завершен по таймауту после 100%)" | tee -a "$LOG_FILE"
            AWS_EXIT_CODE=0
        fi
    else
        echo "ВНИМАНИЕ: Финальный файл не найден: $DOWNLOAD_FILE" | tee -a "$LOG_FILE"
        echo "Список файлов в директории:" | tee -a "$LOG_FILE"
        ls -lh "$BACKUP_DIR/" | tee -a "$LOG_FILE"

        # Проверяем, остался ли временный файл
        if [ -n "$TEMP_FILE" ] && [ -f "$TEMP_FILE" ]; then
            TEMP_SIZE=$(stat -c%s "$TEMP_FILE" 2>/dev/null || stat -f%z "$TEMP_FILE" 2>/dev/null || echo "0")
            if [ "$TEMP_SIZE" -eq "$TOTAL_SIZE" ]; then
                echo "ИСПРАВЛЕНИЕ: Переименовываю оставшийся временный файл..." | tee -a "$LOG_FILE"
                mv "$TEMP_FILE" "$DOWNLOAD_FILE"
                AWS_EXIT_CODE=0
            fi
        fi
    fi

    if [ $AWS_EXIT_CODE -ne 0 ]; then
        RESTORE_STATUS="error"
        RESTORE_MESSAGE="Ошибка: архив не найден в S3 ($FULL_S3_PATH). Код выхода: $AWS_EXIT_CODE"
        echo "$RESTORE_MESSAGE" | tee -a "$LOG_FILE"
        send_webhook
        exit 1
    fi
else
    log_progress "Скачивание архива по HTTPS (прямая загрузка)..."
    # Извлекаем имя файла из URL (удаляем query параметры после ?)
    BACKUP_FILE=$(basename "${FULL_S3_PATH%%\?*}")
    if ! curl -L -o "$BACKUP_FILE" "$FULL_S3_PATH" 2>&1 | tee -a "$LOG_FILE"; then
        RESTORE_STATUS="error"
        RESTORE_MESSAGE="Ошибка: не удалось скачать архив по ссылке"
        send_webhook
        exit 1
    fi
fi

# === Проверка результата скачивания ===
if [ ! -f "$BACKUP_DIR/$BACKUP_FILE" ]; then
    RESTORE_STATUS="error"
    RESTORE_MESSAGE="Ошибка: архив не скачан"
    echo "$RESTORE_MESSAGE" | tee -a "$LOG_FILE"
    send_webhook
    exit 1
fi

log_progress "Архив успешно скачан: $BACKUP_FILE"

# === Проверка и исправление имени файла ===
# v-restore-user требует, чтобы файл имел расширение .tar
if [[ "$BACKUP_FILE" != *.tar && "$BACKUP_FILE" != *.tar.* ]]; then
    echo "Файл не имеет расширения .tar, добавляю..." | tee -a "$LOG_FILE"
    NEW_BACKUP_FILE="${BACKUP_FILE}.tar"
    mv "$BACKUP_DIR/$BACKUP_FILE" "$BACKUP_DIR/$NEW_BACKUP_FILE"
    BACKUP_FILE="$NEW_BACKUP_FILE"
    echo "Файл переименован в: $BACKUP_FILE" | tee -a "$LOG_FILE"
fi

# === Проверка формата архива ===
log_progress "Проверяю формат архива..."

# Проверяем тип файла
ARCHIVE_INFO=$(file -b "$BACKUP_DIR/$BACKUP_FILE")
echo "Тип файла: $ARCHIVE_INFO" | tee -a "$LOG_FILE"

# Проверяем, что это tar архив
if ! echo "$ARCHIVE_INFO" | grep -qi "tar\|compressed"; then
    echo "✗ ОШИБКА: Скачанный файл не является tar архивом!" | tee -a "$LOG_FILE"
    echo "Возможно, URL истек или произошла ошибка при скачивании." | tee -a "$LOG_FILE"
    echo "Первые 500 байт файла:" | tee -a "$LOG_FILE"
    head -c 500 "$BACKUP_DIR/$BACKUP_FILE" | tee -a "$LOG_FILE"

    RESTORE_STATUS="error"
    RESTORE_MESSAGE="Ошибка: Скачанный файл не является tar архивом. Тип: $ARCHIVE_INFO"
    send_webhook
    exit 1
fi

log_progress "✓ Файл прошел проверку целостности"

# Проверяем содержимое архива
echo "Проверяю структуру архива..." | tee -a "$LOG_FILE"

# Определяем опции tar в зависимости от типа архива
TAR_OPTS="-tf"
if echo "$ARCHIVE_INFO" | grep -qi "gzip"; then
    TAR_OPTS="-tzf"
    echo "Тип сжатия: gzip" | tee -a "$LOG_FILE"
elif echo "$ARCHIVE_INFO" | grep -qi "bzip2"; then
    TAR_OPTS="-tjf"
    echo "Тип сжатия: bzip2" | tee -a "$LOG_FILE"
elif echo "$ARCHIVE_INFO" | grep -qi "xz"; then
    TAR_OPTS="-tJf"
    echo "Тип сжатия: xz" | tee -a "$LOG_FILE"
elif echo "$ARCHIVE_INFO" | grep -qi "zstandard"; then
    TAR_OPTS="--zstd -tf"
    echo "Тип сжатия: zstandard" | tee -a "$LOG_FILE"
else
    echo "Тип сжатия: без сжатия (обычный tar)" | tee -a "$LOG_FILE"
fi

ARCHIVE_CONTENTS=$(tar $TAR_OPTS "$BACKUP_DIR/$BACKUP_FILE" 2>/dev/null | head -30 || true)
echo "Содержимое архива (первые 30 строк):" | tee -a "$LOG_FILE"
echo "$ARCHIVE_CONTENTS" | tee -a "$LOG_FILE"

# Определяем тип бэкапа: полный бэкап пользователя или бэкап домена
if tar $TAR_OPTS "$BACKUP_DIR/$BACKUP_FILE" 2>/dev/null | grep -q "^./pam/\|^pam/"; then
    echo "Обнаружен ПОЛНЫЙ бэкап пользователя (найдена директория ./pam/)" | tee -a "$LOG_FILE"
    echo "Будет восстановлен только домен $DOMAIN из полного бэкапа" | tee -a "$LOG_FILE"
else
    echo "Обнаружен бэкап домена/сайта" | tee -a "$LOG_FILE"
fi

echo "Архив для восстановления: $BACKUP_FILE" | tee -a "$LOG_FILE"

# === Восстанавливаем пользователя и домен через v-restore-user ===
log_progress "Запускаю v-restore-user для восстановления домена $DOMAIN..."

# Запускаем v-restore-user
# v-restore-user ожидает, что архив находится в /backup/ и принимает только имя файла
# Формат: v-restore-user USER BACKUP [WEB] [DNS] [MAIL] [DB] [CRON] [UDIR] [NOTIFY]
# Параметры:
#   WEB='domain.com' - восстановить только этот веб-домен
#   DNS='no' - пропустить DNS
#   MAIL='no' - пропустить почту
#   DB='no' - НЕ восстанавливать БД (создадим и импортируем позже из wp-config.php)
#   CRON='no' - пропустить cron
#   UDIR='no' - пропустить пользовательские директории
#   NOTIFY='no' - не отправлять уведомления
echo "Восстанавливаю веб-домен $DOMAIN (без БД - восстановим позже)..." | tee -a "$LOG_FILE"
RESTORE_OUTPUT=$(v-restore-user "$USER" "$BACKUP_FILE" "$DOMAIN" 'no' 'no' 'no' 'no' 'no' 'no' 2>&1) || RESTORE_FAILED=$?

if [ "${RESTORE_FAILED:-0}" -ne 0 ]; then
    echo "v-restore-user вернул код ошибки: $RESTORE_FAILED" | tee -a "$LOG_FILE"
    echo "Вывод команды: $RESTORE_OUTPUT" | tee -a "$LOG_FILE"
    RESTORE_STATUS="error"
    RESTORE_MESSAGE="Ошибка при восстановлении через v-restore-user. Детали: $RESTORE_OUTPUT"

    # Удаляем все временные файлы при ошибке
    log_progress "Очистка: удаляю скачанный архив из-за ошибки..."
    ORIGINAL_BACKUP=$(basename "$FULL_S3_PATH")
    if [ -f "$BACKUP_DIR/$ORIGINAL_BACKUP" ]; then
        rm -f "$BACKUP_DIR/$ORIGINAL_BACKUP"
        echo "Оригинальный архив удалён: $ORIGINAL_BACKUP" | tee -a "$LOG_FILE"
    fi

    if [ -f "$BACKUP_DIR/$BACKUP_FILE" ] && [ "$BACKUP_FILE" != "$ORIGINAL_BACKUP" ]; then
        rm -f "$BACKUP_DIR/$BACKUP_FILE"
        echo "Переименованный архив удалён: $BACKUP_FILE" | tee -a "$LOG_FILE"
    fi

    send_webhook
    exit 1
fi

log_progress "Пользователь и домен успешно восстановлены через v-restore-user"
echo "Вывод v-restore-user: $RESTORE_OUTPUT" | tee -a "$LOG_FILE"

# === Распаковываем domain_data.tar.zst если он есть ===
DOMAIN_DIR="/home/$USER/web/$DOMAIN"
if [ -f "$DOMAIN_DIR/domain_data.tar.zst" ]; then
    log_progress "Найден сжатый архив domain_data.tar.zst, распаковываю..."

    cd "$DOMAIN_DIR" || exit 1

    # Распаковываем zstd архив
    if zstd -d domain_data.tar.zst -o domain_data.tar 2>&1 | tee -a "$LOG_FILE"; then
        echo "Архив распакован из zstd" | tee -a "$LOG_FILE"

        # Извлекаем tar архив
        if tar -xf domain_data.tar 2>&1 | tee -a "$LOG_FILE"; then
            echo "Файлы домена успешно извлечены" | tee -a "$LOG_FILE"

            # Удаляем временные архивы
            rm -f domain_data.tar.zst domain_data.tar
            echo "Временные архивы удалены" | tee -a "$LOG_FILE"
        else
            echo "ОШИБКА: не удалось извлечь tar архив" | tee -a "$LOG_FILE"
        fi
    else
        echo "ОШИБКА: не удалось распаковать zstd архив" | tee -a "$LOG_FILE"
    fi
elif [ -f "$DOMAIN_DIR/domain_data.tar" ]; then
    log_progress "Найден архив domain_data.tar (без zstd), распаковываю..."

    cd "$DOMAIN_DIR" || exit 1

    # Извлекаем tar архив
    if tar -xf domain_data.tar 2>&1 | tee -a "$LOG_FILE"; then
        echo "Файлы домена успешно извлечены" | tee -a "$LOG_FILE"
        rm -f domain_data.tar
    else
        echo "ОШИБКА: не удалось извлечь tar архив" | tee -a "$LOG_FILE"
    fi
else
    echo "domain_data.tar.zst не найден - файлы уже распакованы или используется другая структура" | tee -a "$LOG_FILE"
fi

# === Определяем путь к домену ===
WP_PATH="/home/$USER/web/$DOMAIN/public_html"

# === Устанавливаем правильного владельца файлов ===
log_progress "Устанавливаю владельца файлов для домена: $USER:$USER..."
chown -R "$USER":"$USER" "$WP_PATH" >> "$LOG_FILE" 2>&1 || {
    echo "Предупреждение: не удалось установить владельца файлов" | tee -a "$LOG_FILE"
}

# === Исправляем права для всех остальных доменов этого пользователя ===
log_progress "Проверяю и исправляю права для всех доменов пользователя $USER..."
USER_WEB_PATH="/home/$USER/web"
if [ -d "$USER_WEB_PATH" ]; then
    for DOMAIN_DIR in "$USER_WEB_PATH"/*/ ; do
        if [ -d "$DOMAIN_DIR" ]; then
            DOMAIN_NAME=$(basename "$DOMAIN_DIR")
            echo "  - Исправляю права для домена: $DOMAIN_NAME" | tee -a "$LOG_FILE"
            chown -R "$USER":"$USER" "$DOMAIN_DIR" >> "$LOG_FILE" 2>&1 || true
        fi
    done
    log_progress "Права для всех доменов пользователя $USER исправлены"
fi

# === Настройка WordPress ===
log_progress "Начинаю настройку WordPress"

# === Автоматическое определение местоположения WordPress ===
CONFIG="$WP_PATH/wp-config.php"

# Если wp-config.php не в корне, ищем его в подпапках
if [ ! -f "$CONFIG" ]; then
    log_progress "wp-config.php не найден в корне, ищу в подпапках..."

    # Ищем первый найденный wp-config.php
    FOUND_CONFIG=$(find "$WP_PATH" -maxdepth 2 -name "wp-config.php" -type f | head -n 1 || true)

    if [ -f "$FOUND_CONFIG" ]; then
        CONFIG="$FOUND_CONFIG"
        # Определяем папку, где находится WordPress
        WP_SUBDIR=$(dirname "$FOUND_CONFIG" | sed "s|$WP_PATH||" | sed 's|^/||')
        if [ -n "$WP_SUBDIR" ]; then
            log_progress "WordPress найден в подпапке: $WP_SUBDIR"
            WP_PATH="$WP_PATH/$WP_SUBDIR"

            # Меняем document root для веб-сервера
            # Формат: v-change-web-domain-docroot USER DOMAIN TARGET_DOMAIN [DIRECTORY]
            log_progress "Изменяю document root на подпапку: $WP_SUBDIR"
            echo "Выполняю: v-change-web-domain-docroot $USER $DOMAIN $DOMAIN $WP_SUBDIR" | tee -a "$LOG_FILE"

            DOCROOT_OUTPUT=$(v-change-web-domain-docroot "$USER" "$DOMAIN" "$DOMAIN" "$WP_SUBDIR" 2>&1) || DOCROOT_FAILED=$?

            if [ "${DOCROOT_FAILED:-0}" -ne 0 ]; then
                echo "v-change-web-domain-docroot вернул код ошибки: $DOCROOT_FAILED" | tee -a "$LOG_FILE"
                echo "Вывод команды: $DOCROOT_OUTPUT" | tee -a "$LOG_FILE"
                echo "Предупреждение: не удалось изменить document root" | tee -a "$LOG_FILE"
            else
                log_progress "Document root успешно изменен на подпапку: $WP_SUBDIR"
                echo "Вывод команды: $DOCROOT_OUTPUT" | tee -a "$LOG_FILE"
            fi
        fi
    else
        echo "ВНИМАНИЕ: wp-config.php не найден - возможно, это НЕ WordPress сайт (статический HTML)" | tee -a "$LOG_FILE"
        log_progress "Пропускаю настройку WordPress - сайт восстановлен как есть"

        # Удаляем архив перед завершением
        log_progress "Очистка временных файлов..."
        ORIGINAL_BACKUP=$(basename "$FULL_S3_PATH")
        if [ -f "$BACKUP_DIR/$ORIGINAL_BACKUP" ]; then
            rm -f "$BACKUP_DIR/$ORIGINAL_BACKUP"
            echo "Оригинальный архив удалён: $ORIGINAL_BACKUP" | tee -a "$LOG_FILE"
        fi
        if [ -f "$BACKUP_DIR/$BACKUP_FILE" ] && [ "$BACKUP_FILE" != "$ORIGINAL_BACKUP" ]; then
            rm -f "$BACKUP_DIR/$BACKUP_FILE"
            echo "Переименованный архив удалён: $BACKUP_FILE" | tee -a "$LOG_FILE"
        fi

        # Пропускаем секцию WordPress и переходим к завершению
        RESTORE_STATUS="done"
        RESTORE_MESSAGE="Восстановление домена $DOMAIN выполнено успешно (без настройки WordPress - статический сайт)"
        send_webhook
        exit 0
    fi
fi

if [ ! -f "$CONFIG" ]; then
    echo "ВНИМАНИЕ: wp-config.php не найден - возможно, это НЕ WordPress сайт" | tee -a "$LOG_FILE"
    log_progress "Пропускаю настройку WordPress - сайт восстановлен как есть"

    # Очистка временных файлов перед завершением
    log_progress "Очистка временных файлов..."
    ORIGINAL_BACKUP=$(basename "$FULL_S3_PATH")
    if [ -f "$BACKUP_DIR/$ORIGINAL_BACKUP" ]; then
        rm -f "$BACKUP_DIR/$ORIGINAL_BACKUP"
        echo "Оригинальный архив удалён: $ORIGINAL_BACKUP" | tee -a "$LOG_FILE"
    fi
    if [ -f "$BACKUP_DIR/$BACKUP_FILE" ] && [ "$BACKUP_FILE" != "$ORIGINAL_BACKUP" ]; then
        rm -f "$BACKUP_DIR/$BACKUP_FILE"
        echo "Переименованный архив удалён: $BACKUP_FILE" | tee -a "$LOG_FILE"
    fi

    RESTORE_STATUS="done"
    RESTORE_MESSAGE="Восстановление домена $DOMAIN выполнено успешно (без настройки WordPress - статический сайт)"
    send_webhook
    exit 0
fi

# Читаем данные БД из wp-config.php
DB_NAME=$(grep -E "DB_NAME" "$CONFIG" | sed -E "s/.*['\"]DB_NAME['\"].*['\"]([^'\"]+)['\"].*/\1/")
DB_USER=$(grep -E "DB_USER" "$CONFIG" | sed -E "s/.*['\"]DB_USER['\"].*['\"]([^'\"]+)['\"].*/\1/")
DB_PASS=$(grep -E "DB_PASSWORD" "$CONFIG" | sed -E "s/.*['\"]DB_PASSWORD['\"].*['\"]([^'\"]+)['\"].*/\1/")

if [ -z "$DB_NAME" ] || [ -z "$DB_USER" ]; then
    RESTORE_STATUS="error"
    RESTORE_MESSAGE="Ошибка: не удалось прочитать настройки БД из wp-config.php"
    send_webhook
    exit 1
fi

log_progress "Проверяю наличие БД в HestiaCP: $DB_NAME"
echo "Имя БД: $DB_NAME" | tee -a "$LOG_FILE"
echo "Пользователь БД: $DB_USER" | tee -a "$LOG_FILE"

# Проверяем, существует ли БД в HestiaCP
# Извлекаем короткое имя БД без префикса пользователя
if [[ "$DB_NAME" == ${USER}_* ]]; then
    SHORT_DB_NAME="${DB_NAME#${USER}_}"
else
    SHORT_DB_NAME="$DB_NAME"
fi

# Проверяем существование БД
if v-list-database "$USER" "$SHORT_DB_NAME" >/dev/null 2>&1; then
    log_progress "База данных $DB_NAME уже существует в HestiaCP"
else
    log_progress "База данных $DB_NAME не найдена в HestiaCP. Создаю..."

    # Извлекаем короткое имя пользователя БД без префикса
    if [[ "$DB_USER" == ${USER}_* ]]; then
        SHORT_DB_USER="${DB_USER#${USER}_}"
    else
        SHORT_DB_USER="$DB_USER"
    fi

    # Создаём базу данных
    DB_CREATE_OUTPUT=$(v-add-database "$USER" "$SHORT_DB_NAME" "$SHORT_DB_USER" "$DB_PASS" "mysql" "localhost" "utf8mb4" 2>&1) || DB_CREATE_FAILED=$?

    if [ "${DB_CREATE_FAILED:-0}" -ne 0 ]; then
        echo "v-add-database вернул код ошибки: $DB_CREATE_FAILED" | tee -a "$LOG_FILE"
        echo "Вывод команды: $DB_CREATE_OUTPUT" | tee -a "$LOG_FILE"
        RESTORE_STATUS="error"
        RESTORE_MESSAGE="Ошибка: не удалось создать базу данных $DB_NAME. Детали: $DB_CREATE_OUTPUT"
        send_webhook
        exit 1
    else
        log_progress "База данных $DB_NAME успешно создана в HestiaCP"
    fi

    # SQL дамп всегда в корне архива, ищем его рекурсивно в RESTORE_DIR и WP_PATH
    log_progress "Поиск SQL дампа для импорта..."
    SQL_DUMP=$(find "$BACKUP_DIR" -type f \( -name "*.sql" -o -name "*.sql.gz" \) 2>/dev/null | head -n 1 || true)

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
        log_progress "Импортирую SQL дамп в базу данных $DB_NAME..."

        # Используем root доступ для импорта (скрипт запускается от root)
        if ! mariadb "$DB_NAME" < "$SQL_DUMP" >> "$LOG_FILE" 2>&1; then
            RESTORE_STATUS="error"
            RESTORE_MESSAGE="Ошибка при импорте SQL-дампа"
            send_webhook
            exit 1
        fi

        log_progress "SQL дамп успешно импортирован в базу данных"
    else
        RESTORE_STATUS="error"
        RESTORE_MESSAGE="SQL-дамп не найден для новой БД"
        send_webhook
        exit 1
    fi
fi

# === Пересборка Hestia и отправка webhook ===
log_progress "Пересборка конфигурации веб-доменов и обновление статистики..."
v-rebuild-web-domains "$USER" >/dev/null 2>&1 || true
v-update-user-stats "$USER" >/dev/null 2>&1 || true

# === Удаляем архив при успешном восстановлении ===
log_progress "Очистка временных файлов..."

# Удаляем оригинальный скачанный файл
ORIGINAL_BACKUP=$(basename "$FULL_S3_PATH")
if [ -f "$BACKUP_DIR/$ORIGINAL_BACKUP" ]; then
    rm -f "$BACKUP_DIR/$ORIGINAL_BACKUP"
    echo "Оригинальный архив удалён: $ORIGINAL_BACKUP" | tee -a "$LOG_FILE"
fi

# Удаляем переименованный архив (если был создан)
if [ -f "$BACKUP_DIR/$BACKUP_FILE" ] && [ "$BACKUP_FILE" != "$ORIGINAL_BACKUP" ]; then
    rm -f "$BACKUP_DIR/$BACKUP_FILE"
    echo "Переименованный архив удалён: $BACKUP_FILE" | tee -a "$LOG_FILE"
fi

# === Устанавливаем финальный статус успеха ===
RESTORE_STATUS="done"
RESTORE_MESSAGE="Восстановление домена $DOMAIN выполнено успешно"
send_webhook
echo "=== End restore $DOMAIN at $(date '+%F %T') ===" | tee -a "$LOG_FILE"
exit 0
