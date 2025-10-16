#!/bin/bash

# Скрипт для поиска и полного удаления домена из Hestia Control Panel у всех пользователей
# Использование: ./remove-domain.sh domain.com

set -e

# Проверка аргументов
if [ $# -ne 1 ]; then
    echo "Использование: $0 <domain>"
    echo "Пример: $0 casino-1win-cl.com"
    exit 1
fi

DOMAIN="$1"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${YELLOW}Поиск и удаление домена: ${DOMAIN}${NC}"
echo -e "${BLUE}========================================${NC}"

# Проверяем, что скрипт запущен под root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Этот скрипт должен быть запущен под root${NC}"
    exit 1
fi

# Проверяем существование Hestia CP
if [ ! -d "/usr/local/hestia" ]; then
    echo -e "${RED}Hestia Control Panel не найден!${NC}"
    exit 1
fi

# Функция для безопасного удаления файлов/папок
safe_remove() {
    if [ -e "$1" ]; then
        echo -e "${YELLOW}  Удаляем: $1${NC}"
        rm -rf "$1"
        echo -e "${GREEN}  ✓ Удалено: $1${NC}"
    fi
}

# Массивы для найденных пользователей
declare -a FOUND_WEB_USERS=()
declare -a FOUND_DNS_USERS=()
declare -a FOUND_MAIL_USERS=()
declare -a FOUND_FILE_USERS=()

echo -e "${BLUE}1. Поиск домена во всех пользователях...${NC}"

# Получаем список всех пользователей Hestia
USERS_DIR="/usr/local/hestia/data/users"
if [ ! -d "$USERS_DIR" ]; then
    echo -e "${RED}Папка пользователей Hestia не найдена!${NC}"
    exit 1
fi

# Перебираем всех пользователей
for user_dir in "$USERS_DIR"/*; do
    if [ -d "$user_dir" ]; then
        USERNAME=$(basename "$user_dir")

        echo -e "${YELLOW}Проверяем пользователя: ${USERNAME}${NC}"

        # Проверяем веб-домен
        if /usr/local/hestia/bin/v-list-web-domain "$USERNAME" "$DOMAIN" >/dev/null 2>&1; then
            echo -e "${GREEN}  ✓ Найден WEB домен у пользователя: ${USERNAME}${NC}"
            FOUND_WEB_USERS+=("$USERNAME")
        fi

        # Проверяем DNS домен
        if /usr/local/hestia/bin/v-list-dns-domain "$USERNAME" "$DOMAIN" >/dev/null 2>&1; then
            echo -e "${GREEN}  ✓ Найден DNS домен у пользователя: ${USERNAME}${NC}"
            FOUND_DNS_USERS+=("$USERNAME")
        fi

        # Проверяем почтовый домен
        if /usr/local/hestia/bin/v-list-mail-domain "$USERNAME" "$DOMAIN" >/dev/null 2>&1; then
            echo -e "${GREEN}  ✓ Найден MAIL домен у пользователя: ${USERNAME}${NC}"
            FOUND_MAIL_USERS+=("$USERNAME")
        fi

        # Проверяем файлы домена
        if [ -d "/home/${USERNAME}/web/${DOMAIN}" ] || [ -d "/home/${USERNAME}/tmp/${DOMAIN}" ]; then
            echo -e "${GREEN}  ✓ Найдены ФАЙЛЫ домена у пользователя: ${USERNAME}${NC}"
            FOUND_FILE_USERS+=("$USERNAME")
        fi
    fi
done

# Объединяем всех найденных пользователей
ALL_USERS=($(printf '%s\n' "${FOUND_WEB_USERS[@]}" "${FOUND_DNS_USERS[@]}" "${FOUND_MAIL_USERS[@]}" "${FOUND_FILE_USERS[@]}" | sort -u))

echo -e "\n${BLUE}2. Результаты поиска:${NC}"
echo -e "WEB домены найдены у: ${FOUND_WEB_USERS[*]}"
echo -e "DNS домены найдены у: ${FOUND_DNS_USERS[*]}"
echo -e "MAIL домены найдены у: ${FOUND_MAIL_USERS[*]}"
echo -e "Файлы найдены у: ${FOUND_FILE_USERS[*]}"
echo -e "${YELLOW}Всего пользователей с доменом: ${#ALL_USERS[@]}${NC}"

if [ ${#ALL_USERS[@]} -eq 0 ]; then
    echo -e "${RED}Домен ${DOMAIN} не найден ни у одного пользователя в Hestia CP${NC}"

    # Но всё равно ищем файлы в системе
    echo -e "\n${YELLOW}3. Поиск файлов домена в системе...${NC}"
    echo "Поиск файлов содержащих ${DOMAIN}:"
    find /home /etc /var/log /usr/local/hestia -name "*${DOMAIN}*" 2>/dev/null | head -20

    echo -e "\n${YELLOW}Поиск в конфигурационных файлах:${NC}"
    grep -r "${DOMAIN}" /etc/nginx/ 2>/dev/null | head -10 || echo "Nginx: не найдено"
    grep -r "${DOMAIN}" /etc/apache2/ /etc/httpd/ 2>/dev/null | head -10 || echo "Apache: не найдено"

    exit 0
fi

echo -e "\n${BLUE}3. Начинаем удаление домена...${NC}"

# Удаляем домен у каждого найденного пользователя
for USERNAME in "${ALL_USERS[@]}"; do
    echo -e "\n${BLUE}=== Удаляем домен у пользователя: ${USERNAME} ===${NC}"

    # Удаляем веб-домен
    if /usr/local/hestia/bin/v-list-web-domain "$USERNAME" "$DOMAIN" >/dev/null 2>&1; then
        echo -e "${YELLOW}Удаляем веб-домен...${NC}"
        /usr/local/hestia/bin/v-delete-web-domain "$USERNAME" "$DOMAIN"
        echo -e "${GREEN}✓ Веб-домен удален${NC}"
    fi

    # Удаляем DNS-домен
    if /usr/local/hestia/bin/v-list-dns-domain "$USERNAME" "$DOMAIN" >/dev/null 2>&1; then
        echo -e "${YELLOW}Удаляем DNS-домен...${NC}"
        /usr/local/hestia/bin/v-delete-dns-domain "$USERNAME" "$DOMAIN"
        echo -e "${GREEN}✓ DNS-домен удален${NC}"
    fi

    # Удаляем почтовый домен
    if /usr/local/hestia/bin/v-list-mail-domain "$USERNAME" "$DOMAIN" >/dev/null 2>&1; then
        echo -e "${YELLOW}Удаляем почтовый домен...${NC}"
        /usr/local/hestia/bin/v-delete-mail-domain "$USERNAME" "$DOMAIN"
        echo -e "${GREEN}✓ Почтовый домен удален${NC}"
    fi

    # Удаляем файлы и конфигурации
    echo -e "${YELLOW}Удаляем файлы и конфигурации...${NC}"

    # Веб-файлы
    safe_remove "/home/${USERNAME}/web/${DOMAIN}"
    safe_remove "/home/${USERNAME}/tmp/${DOMAIN}"
    safe_remove "/home/${USERNAME}/conf/web/${DOMAIN}.conf"
    safe_remove "/home/${USERNAME}/conf/web/s${DOMAIN}.conf"
    safe_remove "/home/${USERNAME}/conf/web/ssl.${DOMAIN}.conf"

    # SSL сертификаты
    safe_remove "/home/${USERNAME}/conf/web/ssl.${DOMAIN}.pem"
    safe_remove "/home/${USERNAME}/conf/web/ssl.${DOMAIN}.key"
    safe_remove "/usr/local/hestia/ssl/certificate/${USERNAME}/${DOMAIN}"

    # Удаляем записи из конфиг файлов пользователя
    USER_CONF_DIR="/usr/local/hestia/data/users/${USERNAME}"

    if [ -f "${USER_CONF_DIR}/web.conf" ]; then
        sed -i "/^DOMAIN='${DOMAIN}'/d" "${USER_CONF_DIR}/web.conf"
    fi

    if [ -f "${USER_CONF_DIR}/dns.conf" ]; then
        sed -i "/^DOMAIN='${DOMAIN}'/d" "${USER_CONF_DIR}/dns.conf"
    fi

    if [ -f "${USER_CONF_DIR}/mail.conf" ]; then
        sed -i "/^DOMAIN='${DOMAIN}'/d" "${USER_CONF_DIR}/mail.conf"
    fi

    # Удаляем backup файлы
    find /backup -name "*${DOMAIN}*" -type f -exec rm -f {} \; 2>/dev/null || true
    find /home/${USERNAME}/backup -name "*${DOMAIN}*" -type f -exec rm -f {} \; 2>/dev/null || true

    # Очищаем cron задачи
    if [ -f "/var/spool/cron/crontabs/${USERNAME}" ]; then
        sed -i "/${DOMAIN}/d" "/var/spool/cron/crontabs/${USERNAME}"
    fi
done

echo -e "\n${BLUE}4. Удаляем системные файлы...${NC}"

# Логи веб-серверов
safe_remove "/var/log/apache2/domains/${DOMAIN}.log"
safe_remove "/var/log/apache2/domains/${DOMAIN}.error.log"
safe_remove "/var/log/nginx/domains/${DOMAIN}.log"
safe_remove "/var/log/nginx/domains/${DOMAIN}.error.log"

# Конфигурации веб-серверов
safe_remove "/etc/apache2/conf.d/domains/${DOMAIN}.conf"
safe_remove "/etc/httpd/conf.d/domains/${DOMAIN}.conf"
safe_remove "/etc/nginx/conf.d/domains/${DOMAIN}.conf"

# Поиск и удаление всех конфигураций с доменом
echo -e "${YELLOW}Поиск дополнительных конфигураций...${NC}"
find /etc/nginx /etc/apache2 /etc/httpd -name "*${DOMAIN}*" -type f 2>/dev/null | while read file; do
    safe_remove "$file"
done

# Удаляем строки с доменом из конфигов
echo -e "${YELLOW}Очистка конфигураций от записей домена...${NC}"
find /etc/nginx /etc/apache2 /etc/httpd -name "*.conf" -type f 2>/dev/null | \
xargs grep -l "${DOMAIN}" 2>/dev/null | \
while read file; do
    echo -e "${YELLOW}  Очищаем $file${NC}"
    sed -i "/${DOMAIN}/d" "$file"
done

echo -e "\n${BLUE}5. Перезагружаем сервисы...${NC}"
systemctl reload nginx 2>/dev/null && echo -e "${GREEN}✓ Nginx перезагружен${NC}" || echo -e "${YELLOW}⚠ Nginx не перезагружен${NC}"
systemctl reload apache2 2>/dev/null && echo -e "${GREEN}✓ Apache2 перезагружен${NC}" || echo -e "${YELLOW}⚠ Apache2 не найден${NC}"
systemctl reload httpd 2>/dev/null && echo -e "${GREEN}✓ Httpd перезагружен${NC}" || echo -e "${YELLOW}⚠ Httpd не найден${NC}"

echo -e "\n${BLUE}6. Финальная проверка...${NC}"
echo -e "${YELLOW}Поиск оставшихся файлов:${NC}"
REMAINING_FILES=$(find /home /etc /usr/local/hestia /var/log -name "*${DOMAIN}*" 2>/dev/null | head -10)
if [ -n "$REMAINING_FILES" ]; then
    echo "$REMAINING_FILES"
    echo -e "${YELLOW}Найдены оставшиеся файлы (показаны первые 10)${NC}"
else
    echo -e "${GREEN}✓ Файлы с именем домена не найдены${NC}"
fi

echo -e "\n${YELLOW}Поиск в конфигурационных файлах:${NC}"
NGINX_REFS=$(grep -r "${DOMAIN}" /etc/nginx/ 2>/dev/null | wc -l)
APACHE_REFS=$(grep -r "${DOMAIN}" /etc/apache2/ /etc/httpd/ 2>/dev/null | wc -l)

echo "Nginx: $NGINX_REFS упоминаний"
echo "Apache: $APACHE_REFS упоминаний"

# Итоговая проверка в Hestia
echo -e "\n${YELLOW}Проверка в Hestia CP:${NC}"
DOMAIN_FOUND=false
for USERNAME in "${ALL_USERS[@]}"; do
    if /usr/local/hestia/bin/v-list-web-domain "$USERNAME" "$DOMAIN" >/dev/null 2>&1; then
        echo -e "${RED}⚠ Домен все еще найден у ${USERNAME}!${NC}"
        DOMAIN_FOUND=true
    fi
done

if ! $DOMAIN_FOUND; then
    echo -e "${GREEN}✓ Домен полностью удален из Hestia CP${NC}"
fi

echo -e "\n${BLUE}========================================${NC}"
echo -e "${GREEN}Удаление домена ${DOMAIN} завершено!${NC}"
echo -e "${BLUE}========================================${NC}"

echo -e "\n${YELLOW}Рекомендации:${NC}"
echo "1. Проверьте работу сайтов на сервере"
echo "2. Проверьте логи веб-серверов на ошибки"
echo "3. Убедитесь что домен больше не отвечает"
echo "4. При необходимости перезагрузите сервер"
