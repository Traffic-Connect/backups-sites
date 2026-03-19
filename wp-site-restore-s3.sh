#!/bin/bash
# ==============================================
# Восстановление сайта (WordPress) из S3 Backblaze B2 архива

set -euo pipefail
IFS=$'\n\t'

VERSION="v3"

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

    # Используем timeout для предотвращения зависания
    timeout 10 curl -s --max-time 8 --connect-timeout 5 -X POST "$WEBHOOK_URL" \
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
) >> "$LOG_FILE" 2>&1 || {
        echo "Webhook timeout or failed (non-critical)" >> "$LOG_FILE"
        return 0
    }

    echo "Webhook отправлен" | tee -a "$LOG_FILE"
    return 0
}

# === Функция логирования с отправкой webhook о прогрессе ===
log_progress() {
    local message="$1"
    echo "$message" | tee -a "$LOG_FILE"

    # Отправляем webhook о прогрессе (с защитой от ошибок)
    RESTORE_STATUS="progress"
    RESTORE_MESSAGE="$message"
    send_webhook || {
        echo "WARNING: Webhook failed for message: $message" | tee -a "$LOG_FILE"
        return 0
    }
}

# Используем переданного пользователя
USER="$USERNAME"

# === Функция очистки временных файлов ===
cleanup_temp_files() {
    echo "=== Очистка временных файлов ===" | tee -a "$LOG_FILE"

    # Удаляем временную директорию с извлечёнными SQL дампами
    if [ -n "${TEMP_EXTRACT_DIR:-}" ] && [ -d "$TEMP_EXTRACT_DIR" ]; then
        echo "Удаляю временную директорию: $TEMP_EXTRACT_DIR" | tee -a "$LOG_FILE"
        rm -rf "$TEMP_EXTRACT_DIR" 2>&1 | tee -a "$LOG_FILE" || echo "Ошибка при удалении временной директории (игнорируется)" | tee -a "$LOG_FILE"
    fi

    # Удаляем временную директорию проверки целостности
    if [ -n "${INTEGRITY_CHECK_DIR:-}" ] && [ -d "$INTEGRITY_CHECK_DIR" ]; then
        echo "Удаляю временную директорию проверки: $INTEGRITY_CHECK_DIR" | tee -a "$LOG_FILE"
        rm -rf "$INTEGRITY_CHECK_DIR" 2>&1 | tee -a "$LOG_FILE" || echo "Ошибка при удалении временной директории (игнорируется)" | tee -a "$LOG_FILE"
    fi

    # Удаляем оригинальный скачанный файл
    ORIGINAL_BACKUP=$(basename "$FULL_S3_PATH")
    if [ -f "$BACKUP_DIR/$ORIGINAL_BACKUP" ]; then
        echo "Удаляю оригинальный архив: $ORIGINAL_BACKUP" | tee -a "$LOG_FILE"
        rm -f "$BACKUP_DIR/$ORIGINAL_BACKUP" 2>&1 | tee -a "$LOG_FILE" || echo "Ошибка при удалении архива (игнорируется)" | tee -a "$LOG_FILE"
    fi

    # Удаляем переименованный архив (если был создан)
    if [ -n "${BACKUP_FILE:-}" ] && [ -f "$BACKUP_DIR/$BACKUP_FILE" ] && [ "$BACKUP_FILE" != "$ORIGINAL_BACKUP" ]; then
        echo "Удаляю переименованный архив: $BACKUP_FILE" | tee -a "$LOG_FILE"
        rm -f "$BACKUP_DIR/$BACKUP_FILE" 2>&1 | tee -a "$LOG_FILE" || echo "Ошибка при удалении архива (игнорируется)" | tee -a "$LOG_FILE"
    fi

    echo "Очистка временных файлов завершена" | tee -a "$LOG_FILE"
}

# === Обработчик ошибок ===
error_handler() {
    local exit_code=$?

    # Если выход успешный (код 0), ничего не делаем - trap был отключен
    if [ $exit_code -eq 0 ]; then
        return 0
    fi

    echo "=== ОШИБКА: Скрипт завершился с кодом $exit_code ===" | tee -a "$LOG_FILE"
    echo "Время ошибки: $(date '+%F %T')" | tee -a "$LOG_FILE"

    # Устанавливаем статус ошибки если еще не установлен
    if [ "$RESTORE_STATUS" != "error" ]; then
        RESTORE_STATUS="error"
        RESTORE_MESSAGE="Восстановление прервано с ошибкой (код: $exit_code)"
    fi

    # Очищаем временные файлы
    cleanup_temp_files

    # Отправляем финальный webhook об ошибке
    send_webhook || echo "Не удалось отправить webhook об ошибке" | tee -a "$LOG_FILE"

    echo "=== End restore $DOMAIN at $(date '+%F %T') ===" | tee -a "$LOG_FILE"
    exit $exit_code
}

# Устанавливаем trap для перехвата ошибок и прерываний
trap error_handler ERR EXIT

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
    # Извлекаем имя файла из S3 пути
    BACKUP_FILE=$(basename "$FULL_S3_PATH")
    DOWNLOAD_FILE="$BACKUP_DIR/$BACKUP_FILE"

    # Проверяем, существует ли уже скачанный файл
    if [ -f "$DOWNLOAD_FILE" ]; then
        log_progress "Архив уже существует локально, проверяю целостность..."

        # Получаем размер файла в S3 для сравнения
        TOTAL_SIZE=$(aws --endpoint-url "$AWS_ENDPOINT" s3api head-object --bucket "$(echo $FULL_S3_PATH | cut -d'/' -f3)" --key "$(echo $FULL_S3_PATH | cut -d'/' -f4-)" --query ContentLength --output text 2>/dev/null || echo "0")
        LOCAL_SIZE=$(stat -c%s "$DOWNLOAD_FILE" 2>/dev/null || stat -f%z "$DOWNLOAD_FILE" 2>/dev/null || echo "0")

        echo "Размер файла в S3: $TOTAL_SIZE байт" | tee -a "$LOG_FILE"
        echo "Размер локального файла: $LOCAL_SIZE байт" | tee -a "$LOG_FILE"

        if [ "$LOCAL_SIZE" -eq "$TOTAL_SIZE" ] && [ "$TOTAL_SIZE" -gt 0 ]; then
            log_progress "Локальный архив совпадает с размером в S3, пропускаю скачивание"
            echo "Использую существующий архив: $DOWNLOAD_FILE" | tee -a "$LOG_FILE"
        else
            log_progress "Локальный архив повреждён или неполный, удаляю и скачиваю заново..."
            rm -f "$DOWNLOAD_FILE"
            echo "Повреждённый архив удалён" | tee -a "$LOG_FILE"
        fi
    fi

    # Если файл не существует или был удалён, скачиваем
    if [ ! -f "$DOWNLOAD_FILE" ]; then
        log_progress "Скачивание архива из S3 (через AWS CLI)..."
        echo "Скачиваю файл: $BACKUP_FILE" | tee -a "$LOG_FILE"

        # Получаем размер файла в S3
        TOTAL_SIZE=$(aws --endpoint-url "$AWS_ENDPOINT" s3api head-object --bucket "$(echo $FULL_S3_PATH | cut -d'/' -f3)" --key "$(echo $FULL_S3_PATH | cut -d'/' -f4-)" --query ContentLength --output text 2>/dev/null || echo "0")
        echo "Размер файла в S3: $TOTAL_SIZE байт" | tee -a "$LOG_FILE"

        echo "Скачиваю в: $DOWNLOAD_FILE" | tee -a "$LOG_FILE"

    # Создаем временный файл для вывода AWS CLI
    AWS_LOG=$(mktemp)

    # Конфигурируем AWS CLI для предотвращения зависания и ошибок retry
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
    fi  # Конец блока: if [ ! -f "$DOWNLOAD_FILE" ]
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

# === Проверяем целостность внутренних архивов домена ===
log_progress "Проверяю целостность внутренних архивов домена в бэкапе..."

# Ищем архивы домена внутри основного tar
# Для полных бэкапов структура: ./web/domain.com/domain.com.tar.zst или ./web/domain.com/domain_data.tar.zst
DOMAIN_ARCHIVES=$(tar $TAR_OPTS "$BACKUP_DIR/$BACKUP_FILE" 2>/dev/null | grep -E "^\.?/?web/$DOMAIN/.*\.tar(\.zst|\.gz)?$" | head -5 || true)

if [ -n "$DOMAIN_ARCHIVES" ]; then
    echo "Найдены внутренние архивы домена:" | tee -a "$LOG_FILE"
    echo "$DOMAIN_ARCHIVES" | tee -a "$LOG_FILE"

    # Создаём временную директорию для проверки
    INTEGRITY_CHECK_DIR=$(mktemp -d)
    echo "Временная директория для проверки: $INTEGRITY_CHECK_DIR" | tee -a "$LOG_FILE"

    # Извлекаем внутренние архивы для проверки
    cd "$INTEGRITY_CHECK_DIR"

    # Определяем опции для извлечения (используем ту же логику что и для TAR_OPTS)
    INTEGRITY_TAR_OPTS="-xf"
    if echo "$ARCHIVE_INFO" | grep -qi "gzip"; then
        INTEGRITY_TAR_OPTS="-xzf"
    elif echo "$ARCHIVE_INFO" | grep -qi "bzip2"; then
        INTEGRITY_TAR_OPTS="-xjf"
    elif echo "$ARCHIVE_INFO" | grep -qi "xz"; then
        INTEGRITY_TAR_OPTS="-xJf"
    elif echo "$ARCHIVE_INFO" | grep -qi "zstandard"; then
        INTEGRITY_TAR_OPTS="--zstd -xf"
    fi

    INTEGRITY_FAILED=0
    while IFS= read -r archive_path; do
        if [ -z "$archive_path" ]; then
            continue
        fi

        archive_name=$(basename "$archive_path")
        echo "Извлекаю для проверки: $archive_name" | tee -a "$LOG_FILE"

        # Извлекаем конкретный файл из основного архива
        if tar $INTEGRITY_TAR_OPTS "$BACKUP_DIR/$BACKUP_FILE" "$archive_path" 2>&1 | tee -a "$LOG_FILE"; then
            # Проверяем целостность извлечённого архива
            if [[ "$archive_name" == *.tar.zst ]]; then
                echo "Проверяю целостность zstd архива: $archive_name" | tee -a "$LOG_FILE"
                if ! zstd -t "$archive_path" 2>&1 | tee -a "$LOG_FILE"; then
                    echo "ОШИБКА: Архив $archive_name повреждён!" | tee -a "$LOG_FILE"
                    INTEGRITY_FAILED=1
                fi
            elif [[ "$archive_name" == *.tar.gz ]]; then
                echo "Проверяю целостность gzip архива: $archive_name" | tee -a "$LOG_FILE"
                if ! gzip -t "$archive_path" 2>&1 | tee -a "$LOG_FILE"; then
                    echo "ОШИБКА: Архив $archive_name повреждён!" | tee -a "$LOG_FILE"
                    INTEGRITY_FAILED=1
                fi
            elif [[ "$archive_name" == *.tar ]]; then
                echo "Проверяю целостность tar архива: $archive_name" | tee -a "$LOG_FILE"
                if ! tar -tf "$archive_path" >/dev/null 2>&1; then
                    echo "ОШИБКА: Архив $archive_name повреждён!" | tee -a "$LOG_FILE"
                    INTEGRITY_FAILED=1
                fi
            fi
        else
            echo "ОШИБКА: Не удалось извлечь $archive_name для проверки" | tee -a "$LOG_FILE"
            INTEGRITY_FAILED=1
        fi
    done <<< "$DOMAIN_ARCHIVES"

    # Удаляем временную директорию
    cd "$BACKUP_DIR"
    rm -rf "$INTEGRITY_CHECK_DIR"

    if [ $INTEGRITY_FAILED -ne 0 ]; then
        RESTORE_STATUS="error"
        RESTORE_MESSAGE="Ошибка: Обнаружены повреждённые внутренние архивы домена $DOMAIN"
        echo "$RESTORE_MESSAGE" | tee -a "$LOG_FILE"
        send_webhook
        exit 1
    else
        log_progress "✓ Все внутренние архивы домена прошли проверку целостности"
    fi
else
    echo "Внутренние архивы домена не найдены или не требуют проверки" | tee -a "$LOG_FILE"
fi

# === Проверяем и удаляем существующий домен перед восстановлением ===
log_progress "Проверяю существование домена $DOMAIN на сервере..."

# Проверяем, существует ли домен у текущего пользователя
if v-list-web-domain "$USER" "$DOMAIN" >/dev/null 2>&1; then
    log_progress "Домен $DOMAIN уже существует у пользователя $USER. Удаляю..."

    DELETE_OUTPUT=$(v-delete-web-domain "$USER" "$DOMAIN" 'yes' 2>&1) || DELETE_FAILED=$?

    if [ "${DELETE_FAILED:-0}" -ne 0 ]; then
        echo "v-delete-web-domain вернул код ошибки: $DELETE_FAILED" | tee -a "$LOG_FILE"
        echo "Вывод команды: $DELETE_OUTPUT" | tee -a "$LOG_FILE"
        log_progress "Предупреждение: не удалось удалить существующий домен"
    else
        log_progress "Домен $DOMAIN успешно удален"
    fi
else
    # Проверяем, не принадлежит ли домен другому пользователю
    DOMAIN_OWNER=$(grep -r "DOMAIN='$DOMAIN'" /usr/local/hestia/data/users/*/web.conf 2>/dev/null | cut -d'/' -f7 | head -n1 || echo "")

    if [ -n "$DOMAIN_OWNER" ] && [ "$DOMAIN_OWNER" != "$USER" ]; then
        log_progress "ВНИМАНИЕ: Домен $DOMAIN принадлежит пользователю $DOMAIN_OWNER. Удаляю..."

        DELETE_OUTPUT=$(v-delete-web-domain "$DOMAIN_OWNER" "$DOMAIN" 'yes' 2>&1) || DELETE_FAILED=$?

        if [ "${DELETE_FAILED:-0}" -ne 0 ]; then
            echo "v-delete-web-domain вернул код ошибки: $DELETE_FAILED" | tee -a "$LOG_FILE"
            echo "Вывод команды: $DELETE_OUTPUT" | tee -a "$LOG_FILE"
            RESTORE_STATUS="error"
            RESTORE_MESSAGE="Ошибка: домен принадлежит другому пользователю и не удалось его удалить"
            send_webhook
            exit 1
        else
            log_progress "Домен $DOMAIN успешно удален от пользователя $DOMAIN_OWNER"
        fi
    else
        log_progress "Домен $DOMAIN не существует на сервере"
    fi
fi

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
    send_webhook
    exit 1
fi

log_progress "Пользователь и домен успешно восстановлены через v-restore-user"
echo "Вывод v-restore-user: $RESTORE_OUTPUT" | tee -a "$LOG_FILE"

# === Извлекаем папку db/ из архива для SQL дампов ===
log_progress "Извлекаю SQL дампы из архива..."

echo "Архив: $BACKUP_DIR/$BACKUP_FILE" | tee -a "$LOG_FILE"
echo "Проверяю наличие папки db/ в архиве..." | tee -a "$LOG_FILE"

# Определяем опции tar в зависимости от типа архива
TAR_EXTRACT_OPTS="-xf"
BACKUP_FILE_PATH="$BACKUP_DIR/$BACKUP_FILE"

if [[ "$BACKUP_FILE" == *.tar.gz ]]; then
    TAR_EXTRACT_OPTS="-xzf"
elif [[ "$BACKUP_FILE" == *.tar.bz2 ]]; then
    TAR_EXTRACT_OPTS="-xjf"
elif [[ "$BACKUP_FILE" == *.tar.xz ]]; then
    TAR_EXTRACT_OPTS="-xJf"
elif [[ "$BACKUP_FILE" == *.tar.zst ]]; then
    TAR_EXTRACT_OPTS="--zstd -xf"
fi

# Смотрим структуру архива
echo "Содержимое архива (первые 50 строк):" | tee -a "$LOG_FILE"
tar -tf "$BACKUP_FILE_PATH" 2>/dev/null | head -50 | tee -a "$LOG_FILE" || true

# Проверяем, есть ли папка db/ в архиве
echo "Поиск папки db/ в архиве..." | tee -a "$LOG_FILE"
DB_ENTRIES=$(tar -tf "$BACKUP_FILE_PATH" 2>/dev/null | grep "db/" | head -20 || true)
echo "Найденные записи db/:" | tee -a "$LOG_FILE"
echo "$DB_ENTRIES" | tee -a "$LOG_FILE"

DB_IN_ARCHIVE=$(echo "$DB_ENTRIES" | grep -c "db/" || echo "0")
echo "Найдено записей db/ в архиве: $DB_IN_ARCHIVE" | tee -a "$LOG_FILE"

if [ "$DB_IN_ARCHIVE" -gt 0 ]; then
    log_progress "Папка db/ найдена в архиве, извлекаю во временную директорию..."

    # Создаём временную директорию для извлечения
    TEMP_EXTRACT_DIR="$BACKUP_DIR/temp_extract_$$"
    mkdir -p "$TEMP_EXTRACT_DIR"
    echo "Временная директория: $TEMP_EXTRACT_DIR" | tee -a "$LOG_FILE"

    # Извлекаем только папку db/
    cd "$TEMP_EXTRACT_DIR"
    echo "Извлекаю папку db/ из архива..." | tee -a "$LOG_FILE"

    # Пробуем извлечь папку db/ - используем паттерн "./db" так как в архиве структура ./db/
    echo "Выполняю: tar $TAR_EXTRACT_OPTS $BACKUP_FILE_PATH ./db" | tee -a "$LOG_FILE"
    if tar $TAR_EXTRACT_OPTS "$BACKUP_FILE_PATH" ./db 2>&1 | tee -a "$LOG_FILE"; then
        log_progress "SQL дампы извлечены из архива"

        # Показываем содержимое
        echo "Содержимое извлечённой папки:" | tee -a "$LOG_FILE"
        ls -laR "$TEMP_EXTRACT_DIR" 2>/dev/null | head -100 | tee -a "$LOG_FILE" || true

        echo "SQL файлы:" | tee -a "$LOG_FILE"
        find "$TEMP_EXTRACT_DIR" -type f -name "*.sql*" 2>/dev/null | tee -a "$LOG_FILE" || true
    else
        echo "Ошибка при извлечении папки db/ из архива" | tee -a "$LOG_FILE"
        echo "Возможно, папка db/ отсутствует в этом архиве" | tee -a "$LOG_FILE"
    fi

    cd "$BACKUP_DIR"
else
    echo "Папка db/ не найдена в архиве, возможно это бэкап только домена" | tee -a "$LOG_FILE"
fi

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

        # Пропускаем секцию WordPress и переходим к завершению
        RESTORE_STATUS="done"
        RESTORE_MESSAGE="Восстановление домена $DOMAIN выполнено успешно (без настройки WordPress - статический сайт)"

        # Удаляем временные файлы только при успешном завершении
        log_progress "Удаляю временные файлы после успешного восстановления..."
        cleanup_temp_files

        # Отключаем trap перед успешным выходом
        trap - ERR EXIT

        send_webhook
        echo "=== End restore $DOMAIN at $(date '+%F %T') ===" | tee -a "$LOG_FILE"
        exit 0
    fi
fi

if [ ! -f "$CONFIG" ]; then
    echo "ВНИМАНИЕ: wp-config.php не найден - возможно, это НЕ WordPress сайт" | tee -a "$LOG_FILE"
    log_progress "Пропускаю настройку WordPress - сайт восстановлен как есть"

    RESTORE_STATUS="done"
    RESTORE_MESSAGE="Восстановление домена $DOMAIN выполнено успешно (без настройки WordPress - статический сайт)"

    # Удаляем временные файлы только при успешном завершении
    log_progress "Удаляю временные файлы после успешного восстановления..."
    cleanup_temp_files

    # Отключаем trap перед успешным выходом
    trap - ERR EXIT

    send_webhook
    echo "=== End restore $DOMAIN at $(date '+%F %T') ===" | tee -a "$LOG_FILE"
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
# Сначала пробуем точное совпадение с USER_
if [[ "$DB_NAME" == ${USER}_* ]]; then
    SHORT_DB_NAME="${DB_NAME#${USER}_}"
    echo "Префикс '$USER' найден и удален. Короткое имя: $SHORT_DB_NAME" | tee -a "$LOG_FILE"
# Пробуем найти префикс USER без подчеркивания в конце
elif [[ "$DB_NAME" == ${USER%_}_* ]]; then
    SHORT_DB_NAME="${DB_NAME#${USER%_}_}"
    echo "Префикс '${USER%_}' найден и удален. Короткое имя: $SHORT_DB_NAME" | tee -a "$LOG_FILE"
# Если DB_NAME начинается с букв из USER, пробуем разные варианты
else
    # Для случаев типа: USER=schema_44, DB_NAME=schema44_winline_by
    # Убираем подчеркивания из USER и ищем совпадение
    USER_NO_UNDERSCORE="${USER//_/}"
    if [[ "$DB_NAME" == ${USER_NO_UNDERSCORE}_* ]]; then
        SHORT_DB_NAME="${DB_NAME#${USER_NO_UNDERSCORE}_}"
        echo "Префикс '$USER_NO_UNDERSCORE' (без подчеркиваний) найден и удален. Короткое имя: $SHORT_DB_NAME" | tee -a "$LOG_FILE"
    else
        # Если ничего не подошло, используем полное имя БД как есть
        SHORT_DB_NAME="$DB_NAME"
        echo "Префикс пользователя не найден, используется полное имя: $SHORT_DB_NAME" | tee -a "$LOG_FILE"
    fi
fi

# Извлекаем короткое имя пользователя БД без префикса (используем ту же логику, что и для DB_NAME)
if [[ "$DB_USER" == ${USER}_* ]]; then
    SHORT_DB_USER="${DB_USER#${USER}_}"
    echo "Префикс пользователя '$USER' найден в DB_USER и удален. Короткое имя пользователя: $SHORT_DB_USER" | tee -a "$LOG_FILE"
elif [[ "$DB_USER" == ${USER%_}_* ]]; then
    SHORT_DB_USER="${DB_USER#${USER%_}_}"
    echo "Префикс пользователя '${USER%_}' найден в DB_USER и удален. Короткое имя пользователя: $SHORT_DB_USER" | tee -a "$LOG_FILE"
else
    USER_NO_UNDERSCORE="${USER//_/}"
    if [[ "$DB_USER" == ${USER_NO_UNDERSCORE}_* ]]; then
        SHORT_DB_USER="${DB_USER#${USER_NO_UNDERSCORE}_}"
        echo "Префикс пользователя '$USER_NO_UNDERSCORE' (без подчеркиваний) найден в DB_USER и удален. Короткое имя пользователя: $SHORT_DB_USER" | tee -a "$LOG_FILE"
    else
        SHORT_DB_USER="$DB_USER"
        echo "Префикс пользователя не найден в DB_USER, используется полное имя: $SHORT_DB_USER" | tee -a "$LOG_FILE"
    fi
fi

# Сначала проверяем существование БД напрямую в MySQL/MariaDB
FULL_DB_NAME="${USER}_${SHORT_DB_NAME}"
log_progress "Проверяю существование БД в MySQL: $FULL_DB_NAME"

echo "Запрашиваю список всех баз данных пользователя..." | tee -a "$LOG_FILE"
mariadb -e "SHOW DATABASES LIKE '${USER}_%';" 2>&1 | tee -a "$LOG_FILE"

# Список всех возможных вариантов имени БД для удаления
USER_NO_UNDERSCORE="${USER//_/}"
POSSIBLE_DB_NAMES=(
    "${USER}_${SHORT_DB_NAME}"
    "${USER}_${USER_NO_UNDERSCORE}_${SHORT_DB_NAME}"
    "${USER}_${DB_NAME}"
)

echo "Проверяю и удаляю все варианты имён БД..." | tee -a "$LOG_FILE"
DELETED_COUNT=0

for CHECK_DB_NAME in "${POSSIBLE_DB_NAMES[@]}"; do
    # Удаляем дубликаты из массива
    if [[ " ${CHECKED_DBS[@]} " =~ " ${CHECK_DB_NAME} " ]]; then
        continue
    fi
    CHECKED_DBS+=("$CHECK_DB_NAME")

    echo "Проверяю: $CHECK_DB_NAME" | tee -a "$LOG_FILE"
    DB_EXISTS=$(mariadb -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$CHECK_DB_NAME';" 2>/dev/null | grep -c "$CHECK_DB_NAME" || echo "0")

    if [ "$DB_EXISTS" -gt 0 ]; then
        log_progress "Найдена база данных: $CHECK_DB_NAME. Удаляю..."

        echo "Выполняю: DROP DATABASE IF EXISTS \`$CHECK_DB_NAME\`" | tee -a "$LOG_FILE"
        if mariadb -e "DROP DATABASE IF EXISTS \`$CHECK_DB_NAME\`;" 2>&1 | tee -a "$LOG_FILE"; then
            echo "База данных $CHECK_DB_NAME удалена из MySQL" | tee -a "$LOG_FILE"
            DELETED_COUNT=$((DELETED_COUNT + 1))
        else
            RESTORE_STATUS="error"
            RESTORE_MESSAGE="Ошибка: не удалось удалить существующую базу данных $CHECK_DB_NAME из MySQL"
            send_webhook
            exit 1
        fi
    fi
done

echo "DELETED_COUNT=$DELETED_COUNT" | tee -a "$LOG_FILE"

if [ "$DELETED_COUNT" -gt 0 ]; then
    echo "Удалено баз данных: $DELETED_COUNT" | tee -a "$LOG_FILE"

    # Также удаляем всех возможных пользователей БД
    FULL_DB_USER="${USER}_${SHORT_DB_USER}"
    echo "FULL_DB_USER=$FULL_DB_USER" | tee -a "$LOG_FILE"
    echo "Начинаю удаление пользователя БД: $FULL_DB_USER" | tee -a "$LOG_FILE"

    # Используем timeout для предотвращения зависания
    timeout 10 mariadb -e "DROP USER IF EXISTS '${FULL_DB_USER}'@'localhost';" 2>&1 | tee -a "$LOG_FILE" || echo "DROP USER завершён (timeout или ошибка)" | tee -a "$LOG_FILE"
    echo "Команда DROP USER завершена" | tee -a "$LOG_FILE"

    echo "Начинаю FLUSH PRIVILEGES" | tee -a "$LOG_FILE"
    timeout 10 mariadb -e "FLUSH PRIVILEGES;" 2>&1 | tee -a "$LOG_FILE" || echo "FLUSH PRIVILEGES завершён (timeout или ошибка)" | tee -a "$LOG_FILE"
    echo "FLUSH PRIVILEGES завершён" | tee -a "$LOG_FILE"

    echo "Отправляю webhook о завершении удаления..." | tee -a "$LOG_FILE"
    log_progress "Все найденные базы данных и пользователи успешно удалены"
    echo "Webhook отправлен" | tee -a "$LOG_FILE"
else
    echo "Базы данных не найдены" | tee -a "$LOG_FILE"
    echo "Отправляю webhook..." | tee -a "$LOG_FILE"
    log_progress "Базы данных не найдены, пропускаю удаление"
    echo "Webhook отправлен" | tee -a "$LOG_FILE"
fi

echo "Блок удаления баз завершён успешно" | tee -a "$LOG_FILE"

echo "Продолжаю выполнение скрипта..." | tee -a "$LOG_FILE"

# Теперь проверяем и удаляем из HestiaCP
echo "Перед проверкой HestiaCP..." | tee -a "$LOG_FILE"
log_progress "Проверяю существование базы данных в HestiaCP..."
echo "После webhook проверки HestiaCP..." | tee -a "$LOG_FILE"

HESTIA_DB_EXISTS=false
if v-list-database "$USER" "$SHORT_DB_NAME" >/dev/null 2>&1; then
    HESTIA_DB_EXISTS=true
    log_progress "База данных $SHORT_DB_NAME найдена в HestiaCP. Удаляю..."

    # Удаляем через HestiaCP
    DB_DELETE_OUTPUT=$(v-delete-database "$USER" "$SHORT_DB_NAME" 2>&1) || DB_DELETE_FAILED=$?

    if [ "${DB_DELETE_FAILED:-0}" -ne 0 ]; then
        echo "v-delete-database вернул код ошибки: $DB_DELETE_FAILED" | tee -a "$LOG_FILE"
        echo "Вывод команды: $DB_DELETE_OUTPUT" | tee -a "$LOG_FILE"
        log_progress "Предупреждение: не удалось удалить через HestiaCP (уже удалено из MySQL)"
    else
        log_progress "База данных $SHORT_DB_NAME успешно удалена из HestiaCP"
    fi
else
    log_progress "База данных $SHORT_DB_NAME не найдена в HestiaCP"
fi

# Удаляем записи о БД из конфигурации HestiaCP
echo "Проверяю конфигурационные файлы HestiaCP..." | tee -a "$LOG_FILE"
HESTIA_USER_CONF="/usr/local/hestia/data/users/${USER}"

if [ -d "$HESTIA_USER_CONF" ]; then
    echo "Ищу конфигурационные файлы баз данных..." | tee -a "$LOG_FILE"

    # Проверяем db.conf
    if [ -f "$HESTIA_USER_CONF/db.conf" ]; then
        echo "Содержимое db.conf до очистки:" | tee -a "$LOG_FILE"
        grep -E "${SHORT_DB_NAME}|${DB_NAME}" "$HESTIA_USER_CONF/db.conf" | tee -a "$LOG_FILE" || echo "Записей не найдено" | tee -a "$LOG_FILE"

        # Удаляем все строки, содержащие наши базы
        sed -i.bak "/${SHORT_DB_NAME}/d" "$HESTIA_USER_CONF/db.conf" 2>&1 | tee -a "$LOG_FILE" || true
        sed -i.bak "/${DB_NAME}/d" "$HESTIA_USER_CONF/db.conf" 2>&1 | tee -a "$LOG_FILE" || true

        echo "Содержимое db.conf после очистки:" | tee -a "$LOG_FILE"
        grep -E "${SHORT_DB_NAME}|${DB_NAME}" "$HESTIA_USER_CONF/db.conf" | tee -a "$LOG_FILE" || echo "Записи успешно удалены" | tee -a "$LOG_FILE"
    fi

    # Проверяем и удаляем папки баз данных
    for possible_db in "$SHORT_DB_NAME" "$DB_NAME" "${USER_NO_UNDERSCORE}_${SHORT_DB_NAME}"; do
        if [ -d "$HESTIA_USER_CONF/$possible_db" ]; then
            echo "Удаляю папку конфигурации БД: $HESTIA_USER_CONF/$possible_db" | tee -a "$LOG_FILE"
            rm -rf "$HESTIA_USER_CONF/$possible_db" 2>&1 | tee -a "$LOG_FILE"
        fi
    done
fi

# Ждём для применения изменений
echo "Жду 2 секунды для применения изменений..." | tee -a "$LOG_FILE"
sleep 2

# Проверяем ещё раз, что база действительно удалена
echo "Финальная проверка удаления БД в MySQL..." | tee -a "$LOG_FILE"
DB_STILL_EXISTS=$(mariadb -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$FULL_DB_NAME';" 2>/dev/null | grep -c "$FULL_DB_NAME" || echo "0")

if [ "$DB_STILL_EXISTS" -gt 0 ]; then
    log_progress "ВНИМАНИЕ: База $FULL_DB_NAME всё ещё существует! Повторная попытка удаления..."

    # Принудительное удаление с остановкой всех соединений
    echo "Закрываю все соединения к БД..." | tee -a "$LOG_FILE"
    mariadb -e "SELECT CONCAT('KILL ', id, ';') FROM information_schema.processlist WHERE db='$FULL_DB_NAME';" 2>&1 | grep KILL | mariadb 2>&1 | tee -a "$LOG_FILE" || true

    sleep 1

    echo "Повторное удаление БД..." | tee -a "$LOG_FILE"
    mariadb -e "DROP DATABASE IF EXISTS \`$FULL_DB_NAME\`;" 2>&1 | tee -a "$LOG_FILE"

    sleep 1

    # Проверяем ещё раз
    DB_STILL_EXISTS=$(mariadb -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='$FULL_DB_NAME';" 2>/dev/null | grep -c "$FULL_DB_NAME" || echo "0")

    if [ "$DB_STILL_EXISTS" -gt 0 ]; then
        RESTORE_STATUS="error"
        RESTORE_MESSAGE="КРИТИЧЕСКАЯ ОШИБКА: Не удалось удалить базу данных $FULL_DB_NAME даже после повторных попыток"
        send_webhook
        exit 1
    else
        log_progress "База данных успешно удалена после повторной попытки"
    fi
else
    echo "База данных успешно удалена, можно создавать новую" | tee -a "$LOG_FILE"
fi

log_progress "Создаю базу данных $DB_NAME..."

echo "Итоговые параметры для v-add-database:" | tee -a "$LOG_FILE"
echo "  USER: $USER" | tee -a "$LOG_FILE"
echo "  SHORT_DB_NAME: $SHORT_DB_NAME" | tee -a "$LOG_FILE"
echo "  SHORT_DB_USER: $SHORT_DB_USER" | tee -a "$LOG_FILE"
echo "  HestiaCP создаст БД с именем: ${USER}_${SHORT_DB_NAME}" | tee -a "$LOG_FILE"

# Создаём базу данных
echo "Выполняю: v-add-database $USER $SHORT_DB_NAME $SHORT_DB_USER [PASS] mysql localhost utf8mb4" | tee -a "$LOG_FILE"
DB_CREATE_OUTPUT=$(v-add-database "$USER" "$SHORT_DB_NAME" "$SHORT_DB_USER" "$DB_PASS" "mysql" "localhost" "utf8mb4" 2>&1) || DB_CREATE_FAILED=$?

echo "v-add-database завершён с кодом: ${DB_CREATE_FAILED:-0}" | tee -a "$LOG_FILE"

if [ "${DB_CREATE_FAILED:-0}" -ne 0 ]; then
    echo "v-add-database вернул код ошибки: $DB_CREATE_FAILED" | tee -a "$LOG_FILE"
    echo "Вывод команды: $DB_CREATE_OUTPUT" | tee -a "$LOG_FILE"
    RESTORE_STATUS="error"
    RESTORE_MESSAGE="Ошибка: не удалось создать базу данных $DB_NAME. Детали: $DB_CREATE_OUTPUT"
    send_webhook
    exit 1
else
    echo "База данных успешно создана" | tee -a "$LOG_FILE"
    log_progress "База данных ${USER}_${SHORT_DB_NAME} успешно создана в HestiaCP"
fi

    # SQL дамп ищем в разных местах и форматах
    log_progress "Поиск SQL дампа для импорта..."

    # Список возможных расширений SQL дампов
    SQL_EXTENSIONS=( "*.sql" "*.sql.gz" "*.sql.zst" )

    # 1. Ищем в директории db/ внутри распакованного архива
    # Для полных бэкапов HestiaCP структура: /backup/backup_file/db/dbname/dbname.mysql.sql.zst
    echo "Поиск SQL дампа для БД: $DB_NAME (SHORT_DB_NAME: $SHORT_DB_NAME)" | tee -a "$LOG_FILE"

    # Определяем директорию с распакованным архивом
    # Ищем в /home/$USER/web/$DOMAIN/ где v-restore-user распаковал бэкап
    RESTORE_TEMP_DIR="/home/$USER/web/$DOMAIN"

    # Также ищем в BACKUP_DIR и во временной директории извлечения
    SEARCH_DIRS=(
        "$TEMP_EXTRACT_DIR"
        "$RESTORE_TEMP_DIR"
        "/home/$USER"
        "$BACKUP_DIR"
    )

    USER_NO_UNDERSCORE="${USER//_/}"

    # Возможные имена SQL файлов
    POSSIBLE_SQL_NAMES=(
        "${DB_NAME}.mysql"
        "${USER_NO_UNDERSCORE}_${SHORT_DB_NAME}.mysql"
        "${SHORT_DB_NAME}.mysql"
    )

    echo "Ищу SQL дамп в директориях: ${SEARCH_DIRS[*]}" | tee -a "$LOG_FILE"
    echo "Возможные имена SQL файлов: ${POSSIBLE_SQL_NAMES[*]}" | tee -a "$LOG_FILE"

    # Перебираем директории поиска
    for search_dir in "${SEARCH_DIRS[@]}"; do
        if [ ! -d "$search_dir" ]; then
            continue
        fi

        echo "Поиск в директории: $search_dir" | tee -a "$LOG_FILE"

        # Перебираем возможные имена
        for sql_name in "${POSSIBLE_SQL_NAMES[@]}"; do
            # Перебираем расширения
            for ext in "sql" "sql.gz" "sql.zst"; do
                echo "  Проверяю: */db/*/${sql_name}.${ext}" | tee -a "$LOG_FILE"

                # Ищем файл
                SQL_DUMP=$(find "$search_dir" -type f -path "*/db/*" -name "${sql_name}.${ext}" 2>/dev/null | head -n 1 || true)

                if [ -n "$SQL_DUMP" ] && [ -f "$SQL_DUMP" ]; then
                    echo "✓ Найден SQL дамп: $SQL_DUMP" | tee -a "$LOG_FILE"
                    log_progress "SQL дамп найден: $(basename $SQL_DUMP)"
                    break 3  # Выходим из всех трёх циклов
                fi
            done
        done
    done

    # Если не найден, делаем более широкий поиск по всем файлам (без ограничения на путь */db/*)
    if [ -z "$SQL_DUMP" ] || [ ! -f "$SQL_DUMP" ]; then
        echo "Широкий поиск всех SQL файлов в директориях (без фильтра пути)..." | tee -a "$LOG_FILE"
        for search_dir in "${SEARCH_DIRS[@]}"; do
            if [ ! -d "$search_dir" ]; then
                echo "  Директория не существует: $search_dir" | tee -a "$LOG_FILE"
                continue
            fi

            echo "  Ищу в: $search_dir" | tee -a "$LOG_FILE"

            # Ищем без ограничения на путь */db/*
            SQL_DUMP=$(find "$search_dir" -type f \( -name "*.sql" -o -name "*.sql.gz" -o -name "*.sql.zst" \) 2>/dev/null | head -n 1 || true)

            if [ -n "$SQL_DUMP" ] && [ -f "$SQL_DUMP" ]; then
                echo "✓ Найден SQL дамп при широком поиске: $SQL_DUMP" | tee -a "$LOG_FILE"
                log_progress "SQL дамп найден: $(basename $SQL_DUMP)"
                break
            else
                echo "  SQL файлы не найдены в $search_dir" | tee -a "$LOG_FILE"
            fi
        done
    fi

    # Если всё ещё не найден, показываем содержимое TEMP_EXTRACT_DIR для диагностики
    if [ -z "$SQL_DUMP" ] || [ ! -f "$SQL_DUMP" ]; then
        if [ -n "$TEMP_EXTRACT_DIR" ] && [ -d "$TEMP_EXTRACT_DIR" ]; then
            echo "=== ДИАГНОСТИКА: Содержимое $TEMP_EXTRACT_DIR ===" | tee -a "$LOG_FILE"
            ls -laR "$TEMP_EXTRACT_DIR" | head -100 | tee -a "$LOG_FILE"
            echo "=== Конец диагностики ===" | tee -a "$LOG_FILE"
        fi
    fi

    # 2. Если не найден в db/, ищем в BACKUP_DIR
    if [ -z "$SQL_DUMP" ] || [ ! -f "$SQL_DUMP" ]; then
        echo "SQL дамп не найден в db/, ищу в директории бэкапов..." | tee -a "$LOG_FILE"
        for ext in "${SQL_EXTENSIONS[@]}"; do
            SQL_DUMP=$(find "$BACKUP_DIR" -type f -name "$ext" 2>/dev/null | head -n 1 || true)
            if [ -n "$SQL_DUMP" ] && [ -f "$SQL_DUMP" ]; then
                echo "Найден SQL дамп в BACKUP_DIR: $SQL_DUMP" | tee -a "$LOG_FILE"
                break
            fi
        done
    fi

    # 3. Если не найден, ищем в WP_PATH (где распакован архив)
    if [ -z "$SQL_DUMP" ] || [ ! -f "$SQL_DUMP" ]; then
        echo "SQL дамп не найден, ищу в WP_PATH: $WP_PATH" | tee -a "$LOG_FILE"
        for ext in "${SQL_EXTENSIONS[@]}"; do
            SQL_DUMP=$(find "$WP_PATH" -type f -name "$ext" 2>/dev/null | head -n 1 || true)
            if [ -n "$SQL_DUMP" ] && [ -f "$SQL_DUMP" ]; then
                echo "Найден SQL дамп в WP_PATH: $SQL_DUMP" | tee -a "$LOG_FILE"
                break
            fi
        done
    fi

    # 4. Если WordPress в подпапке, SQL дамп может быть в родительской папке
    if [ -z "$SQL_DUMP" ] || [ ! -f "$SQL_DUMP" ]; then
        PARENT_PATH=$(dirname "$WP_PATH")
        echo "Поиск SQL дампа в родительской папке: $PARENT_PATH" | tee -a "$LOG_FILE"
        for ext in "${SQL_EXTENSIONS[@]}"; do
            SQL_DUMP=$(find "$PARENT_PATH" -maxdepth 1 -type f -name "$ext" 2>/dev/null | head -n 1 || true)
            if [ -n "$SQL_DUMP" ] && [ -f "$SQL_DUMP" ]; then
                echo "Найден SQL дамп в родительской папке: $SQL_DUMP" | tee -a "$LOG_FILE"
                break
            fi
        done
    fi

    echo "Итоговый найденный SQL дамп: $SQL_DUMP" | tee -a "$LOG_FILE"
    if [ -n "$SQL_DUMP" ] && [ -f "$SQL_DUMP" ]; then
        # Проверяем расширение файла и распаковываем если нужно
        if [[ "$SQL_DUMP" == *.zst ]]; then
            log_progress "Распаковываю SQL дамп (zstd)..."
            UNCOMPRESSED_SQL="${SQL_DUMP%.zst}"
            if zstd -d "$SQL_DUMP" -o "$UNCOMPRESSED_SQL" 2>&1 | tee -a "$LOG_FILE"; then
                echo "SQL дамп успешно распакован: $UNCOMPRESSED_SQL" | tee -a "$LOG_FILE"
                SQL_DUMP="$UNCOMPRESSED_SQL"
                log_progress "SQL дамп распакован, начинаю импорт..."
            else
                RESTORE_STATUS="error"
                RESTORE_MESSAGE="Ошибка при распаковке SQL дампа (zstd)"
                send_webhook
                exit 1
            fi
        elif [[ "$SQL_DUMP" == *.gz ]]; then
            log_progress "Распаковываю SQL дамп (gzip)..."
            if gunzip -c "$SQL_DUMP" > "${SQL_DUMP%.gz}" 2>&1 | tee -a "$LOG_FILE"; then
                SQL_DUMP="${SQL_DUMP%.gz}"
                echo "SQL дамп успешно распакован: $SQL_DUMP" | tee -a "$LOG_FILE"
                log_progress "SQL дамп распакован, начинаю импорт..."
            else
                RESTORE_STATUS="error"
                RESTORE_MESSAGE="Ошибка при распаковке SQL дампа (gzip)"
                send_webhook
                exit 1
            fi
        else
            log_progress "Начинаю импорт SQL дампа в базу данных..."
        fi

        # Используем root доступ для импорта (скрипт запускается от root)
        echo "Импортирую SQL дамп в базу данных: ${USER}_${SHORT_DB_NAME}" | tee -a "$LOG_FILE"
        FULL_DB_NAME="${USER}_${SHORT_DB_NAME}"
        if ! mariadb "$FULL_DB_NAME" < "$SQL_DUMP" >> "$LOG_FILE" 2>&1; then
            RESTORE_STATUS="error"
            RESTORE_MESSAGE="Ошибка при импорте SQL-дампа"
            send_webhook
            exit 1
        fi

        # Удаляем распакованный SQL дамп после импорта
        if [[ "$SQL_DUMP" == *.sql ]] && [[ -f "${SQL_DUMP}.zst" || -f "${SQL_DUMP}.gz" ]]; then
            rm -f "$SQL_DUMP"
            echo "Распакованный SQL дамп удалён" | tee -a "$LOG_FILE"
        fi

        log_progress "SQL дамп успешно импортирован в базу данных"

        echo "=== CHECKPOINT: SQL дамп импортирован успешно ===" | tee -a "$LOG_FILE"
        echo "Время: $(date '+%F %T')" | tee -a "$LOG_FILE"
    else
        RESTORE_STATUS="error"
        RESTORE_MESSAGE="SQL-дамп не найден для новой БД"
        send_webhook
        exit 1
    fi

echo "=== CHECKPOINT: Начинаю пересборку HestiaCP ===" | tee -a "$LOG_FILE"
echo "Время: $(date '+%F %T')" | tee -a "$LOG_FILE"

# === Пересборка Hestia и отправка webhook ===
log_progress "Пересборка конфигурации веб-доменов и обновление статистики..."

echo "Выполняю v-rebuild-web-domains..." | tee -a "$LOG_FILE"
v-rebuild-web-domains "$USER" 2>&1 | tee -a "$LOG_FILE" || echo "v-rebuild-web-domains завершён с ошибкой (игнорируется)" | tee -a "$LOG_FILE"
echo "=== CHECKPOINT: v-rebuild-web-domains завершён ===" | tee -a "$LOG_FILE"

echo "Выполняю v-update-user-stats..." | tee -a "$LOG_FILE"
v-update-user-stats "$USER" 2>&1 | tee -a "$LOG_FILE" || echo "v-update-user-stats завершён с ошибкой (игнорируется)" | tee -a "$LOG_FILE"
echo "=== CHECKPOINT: v-update-user-stats завершён ===" | tee -a "$LOG_FILE"

echo "Пересборка завершена" | tee -a "$LOG_FILE"

# === Устанавливаем финальный статус успеха ===
echo "=== CHECKPOINT: Устанавливаю финальный статус успеха ===" | tee -a "$LOG_FILE"
RESTORE_STATUS="done"
RESTORE_MESSAGE="Восстановление домена $DOMAIN выполнено успешно"

# === Удаляем архив ТОЛЬКО при успешном восстановлении ===
echo "=== CHECKPOINT: Начинаю удаление временных файлов ===" | tee -a "$LOG_FILE"
echo "Удаляю временные файлы после успешного восстановления..." | tee -a "$LOG_FILE"
cleanup_temp_files

# Отключаем trap перед успешным выходом
trap - ERR EXIT

echo "Отправляю финальный webhook..." | tee -a "$LOG_FILE"
send_webhook || echo "Ошибка при отправке финального webhook (игнорируется)" | tee -a "$LOG_FILE"

echo "=== End restore $DOMAIN at $(date '+%F %T') ===" | tee -a "$LOG_FILE"
echo "Скрипт успешно завершён" | tee -a "$LOG_FILE"
exit 0
