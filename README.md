# Скрипты резервного копирования WordPress для Hestia Control Panel

Автоматизированное решение для создания и загрузки резервных копий сайтов WordPress в Amazon S3.

## Содержимое репозитория

| Файл | Описание                                              |
|------|-------------------------------------------------------|
| `v-wp-backup-s3` | Команда Hestia CP для интеграции с панелью управления |
| `v-check-file-exists` | Команда Hestia CP для проверки существования скрипта  |
| `v-wp-restore-s3` | Команда Hestia CP для запуска восстановления бэкапа   |
| `wp-backup-s3.sh` | Основной скрипт создания бэкапа и загрузки в S3       |
| `wp-restore-s3.sh` | Основной скрипт развертывания резервной копии с S3    |
| `install.sh` | Скрипт автоматической установки зависимостей          |

## Установка

### Шаг 1: Войдите под пользователем root

```bash
sudo su
```

### Шаг 2: Создайте директорию backups

```bash
mkdir -p /root/backups && cd /root/backups
```

### Шаг 3: Клонируйте репозиторий

```bash
git clone https://github.com/Traffic-Connect/backups-sites.git .
```

### Шаг 4: Запустите установку

```bash
chmod +x install.sh
./install.sh
```

Скрипт автоматически:
- Обновит список пакетов
- Установит необходимые зависимости (jq, awscli, curl)
- Скопирует команды в системные директории
- Установит права на выполнение
- Создаст директорию /backup

## Тестирование

Для проверки работы скрипта выполните:

```bash
/usr/local/bin/wp-backup-s3.sh example.com
```

## Требования

- Hestia Control Panel
- Root доступ к серверу
- Настроенный доступ к S3 bucket
- WordPress сайт на сервере

## Структура проекта

```
backups-sites/
├── README.md           # Документация
├── install.sh          # Скрипт установки
├── v-wp-backup-s3      # Команда Hestia CP
├── v-wp-restore-s3     # Команда Hestia CP
├── v-check-file-exists # Команда Hestia CP
├── wp-backup-s3.sh     # Основной скрипт бэкапа
└── wp-restore-s3.sh    # Основной скрипт развертывания
```

## Использование

После установки скрипт можно вызвать через команду Hestia:

```bash
v-wp-backup-s3 example.com
```

Или напрямую:

```bash
/usr/local/bin/wp-backup-s3.sh example.com
```

## Что делает скрипт

1. Определяет пользователя по домену
2. Создаёт дамп базы данных MySQL
3. Архивирует файлы WordPress и базу данных
4. Загружает архив в S3 bucket
5. Отправляет статус выполнения через API
6. Удаляет локальные временные файлы

## Логи

Логи сохраняются в `/backup/[domain]/backup.log`



/usr/local/bin/wp-restore-s3.sh nightpanda.cyou s3://artem-test-bucket/backups/chickenroad-it.it/wpbackup_chickenroad-it.it_date_2025-10-08_12-54-22.tar.gz
