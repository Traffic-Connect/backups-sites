# Скрипты резервного копирования для Hestia Control Panel

Автоматизированное решение для создания и восстановления резервных копий:
- Отдельных WordPress сайтов
- Полных бэкапов пользователей (все домены, БД, почта)

Интеграция с Amazon S3 (Backblaze B2) и webhook уведомлениями.

## Содержимое репозитория

| Файл | Описание                                              |
|------|-------------------------------------------------------|
| `v-wp-backup-s3` | Команда Hestia CP для создания бэкапа WordPress сайта |
| `v-wp-restore-s3` | Команда Hestia CP для восстановления WordPress сайта   |
| `v-restore-user-s3` | Команда Hestia CP для восстановления полного бэкапа пользователя |
| `v-check-file-exists` | Команда Hestia CP для проверки существования скрипта  |
| `wp-backup-s3.sh` | Основной скрипт создания бэкапа и загрузки в S3       |
| `wp-restore-s3.sh` | Основной скрипт развертывания резервной копии с S3    |
| `restore-user-s3.sh` | Основной скрипт восстановления полного бэкапа пользователя |
| `remove-domain.sh` | Поиск и удаление домена если он был на сервере        |
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
chmod +x install.sh && ./install.sh
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

## Обновление

```bash
cd /root/backups && git checkout . && git pull origin main && bash install.sh
```

## Требования

- Hestia Control Panel
- Root доступ к серверу
- Настроенный доступ к S3 bucket
- jq, awscli, curl (устанавливаются автоматически через install.sh)

### Дополнительно:
- WordPress сайт (для v-wp-backup-s3 / v-wp-restore-s3)
- Полный бэкап пользователя HestiaCP (для v-restore-user-s3)

## Структура проекта

```
backups-sites/
├── README.md              # Документация
├── install.sh             # Скрипт установки
├── v-wp-backup-s3         # Команда Hestia CP (бэкап WordPress)
├── v-wp-restore-s3        # Команда Hestia CP (восстановление WordPress)
├── v-restore-user-s3      # Команда Hestia CP (восстановление пользователя)
├── v-check-file-exists    # Команда Hestia CP (проверка файлов)
├── wp-backup-s3.sh        # Основной скрипт бэкапа WordPress
├── wp-restore-s3.sh       # Основной скрипт восстановления WordPress
├── restore-user-s3.sh     # Основной скрипт восстановления пользователя
└── remove-domain.sh       # Скрипт поиска и удаления домена
```

## Использование

### Бэкап WordPress сайта

После установки скрипт можно вызвать через команду Hestia:

```bash
v-wp-backup-s3 example.com
```

Или напрямую:

```bash
/usr/local/bin/wp-backup-s3.sh example.com
```

### Восстановление WordPress сайта

Восстановление отдельного WordPress сайта из бэкапа:

```bash
v-wp-restore-s3 DOMAIN BACKUP_URL BACKUP_ID SITE_ID IS_DONOR ENVIRONMENT SCHEMA_ID
```

Пример:

```bash
v-wp-restore-s3 example.com \
  "https://s3.example.com/backup.tar.gz" \
  42 \
  17 \
  true \
  manager.example.com \
  24
```

### Восстановление полного бэкапа пользователя

Восстановление всех данных пользователя (все домены, базы данных, почта):

```bash
v-restore-user-s3 BACKUP_URL BACKUP_ID ENVIRONMENT SCHEMA_ID
```

Пример:

```bash
v-restore-user-s3 \
  "https://s3.example.com/user-backup.tar?X-Amz-..." \
  42 \
  manager.example.com \
  24
```

**Важно:** URL должен быть в кавычках, если содержит параметры!

## Что делают скрипты

### v-wp-backup-s3

1. Определяет пользователя по домену
2. Создаёт дамп базы данных MySQL
3. Архивирует файлы WordPress и базу данных
4. Загружает архив в S3 bucket
5. Отправляет статус выполнения через API
6. Удаляет локальные временные файлы

### v-wp-restore-s3

1. Создаёт или пересоздаёт домен для указанного пользователя
2. Скачивает бэкап из S3 (поддержка S3 URL и HTTPS URL)
3. Распаковывает архив (tar.gz или zip)
4. Настраивает WordPress (wp-config.php)
5. Создаёт и импортирует базу данных
6. Настраивает SSL сертификаты
7. Отправляет webhook со статусом

### v-restore-user-s3

1. **Запускается в фоновом режиме** (асинхронно)
2. Скачивает полный бэкап пользователя из S3 (534+ MB)
3. Проверяет целостность архива и структуру
4. Удаляет существующего пользователя (если есть)
5. Создаёт нового пользователя `schema_{SCHEMA_ID}`
6. Восстанавливает через `v-restore-user`:
   - Все веб-домены
   - Все базы данных
   - Почтовые ящики
   - DNS зоны
   - Cron задачи
7. Отправляет webhook со статусом `done` или `error`
8. Удаляет временные файлы

**Время выполнения:** 3-15 минут в зависимости от размера бэкапа

## Логи

### WordPress бэкап/восстановление
Логи сохраняются в `/backup/[domain]/backup.log` и `/backup_restore/[domain]/v-wp-restore.log`

### Восстановление пользователя
Логи сохраняются в:
- `/backup_restore/schema_{SCHEMA_ID}/restore-user.log` - детальный лог основного скрипта
- `/backup_restore/schema_{SCHEMA_ID}/v-restore-user.log` - лог wrapper'а Hestia CP

## Webhook уведомления

Все скрипты восстановления отправляют статус на webhook после завершения работы.

### v-wp-restore-s3

**URL:** `https://{ENVIRONMENT}/api/b2-webhooks/restore`

**Тело запроса:**
```json
{
  "domain": "example.com",
  "restore_status": "done|error",
  "restore_message": "Сообщение о результате",
  "backup_id": "42",
  "archive": "URL бэкапа",
  "site_id": "17",
  "is_donor": "true",
  "scheme_id": "24",
  "service": "s3"
}
```

### v-restore-user-s3

**URL:** `https://{ENVIRONMENT}/api/b2-webhooks/restore-user`

**Тело запроса:**
```json
{
  "status": "done|error|progress",
  "message": "Сообщение о результате",
  "backup_id": "42",
  "archive": "URL бэкапа",
  "schema_id": "24",
  "service": "s3"
}
```

**Статусы:**
- `progress` - восстановление запущено в фоне (отправляется сразу)
- `done` - восстановление успешно завершено
- `error` - произошла ошибка

## Интеграция с Laravel

### Вызов через HestiaCP API

```php
use Illuminate\Support\Facades\Http;

// Восстановление WordPress сайта
$response = Http::asForm()->post('https://hestia-server:8083/api/', [
    'hash' => config('hestia.api_key'),
    'user' => 'admin',
    'cmd' => 'v-wp-restore-s3',
    'arg1' => $domain,
    'arg2' => $backupUrl,
    'arg3' => $backupId,
    'arg4' => $siteId,
    'arg5' => $isDonor ? 'true' : 'false',
    'arg6' => config('app.url'),
    'arg7' => $schemaId,
]);

// Восстановление пользователя (асинхронно)
$response = Http::timeout(30)->asForm()->post('https://hestia-server:8083/api/', [
    'hash' => config('hestia.api_key'),
    'user' => 'admin',
    'cmd' => 'v-restore-user-s3',
    'arg1' => $backupUrl,  // Свежий signed URL!
    'arg2' => $backupId,
    'arg3' => config('app.url'),
    'arg4' => $schemaId,
]);

// Для v-restore-user-s3 сразу вернется:
// {"status": "progress", "message": "...", "pid": "12345"}
// Реальный результат придет на webhook
```

### Обработка webhook

```php
// routes/api.php
Route::post('/b2-webhooks/restore', [BackupController::class, 'handleRestore']);
Route::post('/b2-webhooks/restore-user', [BackupController::class, 'handleRestoreUser']);

// app/Http/Controllers/BackupController.php
public function handleRestoreUser(Request $request)
{
    $validated = $request->validate([
        'status' => 'required|in:done,error,progress',
        'message' => 'required|string',
        'backup_id' => 'required',
        'schema_id' => 'required',
    ]);

    $backup = Backup::find($validated['backup_id']);

    if ($validated['status'] === 'done') {
        $backup->markAsRestored();
        event(new BackupRestored($backup));
    } elseif ($validated['status'] === 'error') {
        $backup->markAsFailed($validated['message']);
        event(new BackupRestoreFailed($backup));
    }

    return response()->json(['success' => true]);
}
```

## Требования к бэкапу пользователя

### Формат архива

Скрипт `v-restore-user-s3` работает **только** со стандартными бэкапами пользователей HestiaCP:

```
username.YYYY-MM-DD_HH-MM-SS.tar
```

### Структура архива

Архив должен содержать:
```
./pam/              # Учетные данные (обязательно!)
./web/              # Веб-сайты и домены
./dns/              # DNS зоны
./mail/             # Почтовые ящики
./db/               # Базы данных
./cron/             # Задачи cron
./user.conf         # Конфигурация пользователя
```

### Создание правильного бэкапа

```bash
# Используйте команду HestiaCP
v-backup-user username

# Это создаст файл в /backup/username.YYYY-MM-DD_HH-MM-SS.tar
```

### Что НЕ подходит

❌ Бэкап отдельного сайта (WordPress плагин)
❌ Архив только с файлами без структуры ./pam
❌ ZIP архивы с произвольной структурой

✅ Только полный бэкап пользователя через `v-backup-user`

## Важные примечания

### Signed URL

Signed URL от Backblaze B2 имеет срок действия (обычно 1 час, параметр `X-Amz-Expires=3600`).

**Генерируйте свежий URL непосредственно перед восстановлением!**

### Асинхронное выполнение

`v-restore-user-s3` запускается в фоновом режиме через `nohup`, что:
- Позволяет API сразу вернуть ответ (без таймаута 30 секунд)
- Восстановление продолжается в фоне (3-15 минут)
- Результат отправляется на webhook по завершению

### Размер бэкапа

Учитывайте время скачивания для больших бэкапов:
- 100 MB → ~30 секунд
- 500 MB → ~2 минуты
- 1 GB → ~4 минуты

(при скорости ~40 MB/s)
