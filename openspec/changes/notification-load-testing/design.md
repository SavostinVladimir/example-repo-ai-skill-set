## Context

Архитектурные решения `ADR-1`, `ADR-2` и `ADR-3` радикально меняют баланс вычислительной нагрузки в подсистеме уведомлений Mastodon:
- **Чтение (`Read Path`):** Эндпоинты `GET /api/v2/notifications` и `GET /api/v2/notifications/unread_count` переходят от рекурсивного CTE (`WITH RECURSIVE ... LATERAL` в `Notification::Groups.paginate_groups`) и 200 коррелированных подзапросов (`NotificationGroup.load_groups_data` через `unnest`) к прямому индексному сканированию таблицы `notification_groups`.
- **Запись (`Write Path`):** В `NotifyService`, `PostStatusService`, `ProcessMentionsService`, `RemoveStatusService` и `UnfilterNotificationsWorker` добавляются дополнительные операции записи и синхронизации: конкурентный `UPSERT` в `notification_groups`, обновление индексируемого `most_recent_notification_id` (отключающего `HOT update`), синхронная запись в `dm_thread_permissions` и пакетная предочистка групп при удалении статусов.

При этом реальная стоимость доставки уведомления определяется не только PostgreSQL, но и взаимодействием всех 7 компонентов конвейера (`Puma`, `Sidekiq`, `NotifyService`, `PostgreSQL`, `Redis`, `Node.js Streaming`, `WebPush/SMTP Gateway`):
- Наличие активного WebSocket-клиента в `mastodon/streaming/index.js` выставляет в Redis ключ `subscribed:timeline:{id}:notifications` (или `subscribed:timeline:{id}`). В `NotifyService` это переводит обработку в ветку `push_to_streaming_api!` с тяжелым `InlineRenderer.render` и публикацией в Redis Pub/Sub, одновременно подавляя постановку отложенного письма `NotificationMailer` (`wait: 2.minutes`) при `recipient_online? == true`.
- Наличие `Web::PushSubscription` у оффлайн- или подписанных пользователей порождает фоновые задачи в очереди `push` (`Web::PushNotificationWorker`), шифрование payload и исходящие HTTP-запросы к внешнему Push-шлюзу.

Поэтому честное сравнение старой (`As-Is`) и новой (`To-Be`) реализаций невозможно через изолированный SQL-микробенчмарк — требуется сквозной нагрузочный стенд, воспроизводящий перекосы данных (вирусные посты), глубокие ветки DM и все ветки доставки на одном сервере с реалистично ограниченным буферным пулом СУБД.

## Goals / Non-Goals

**Goals:**
- Доказательно сравнить производительность решений `As-Is` и `To-Be` (`ADR-1`, `ADR-2`, `ADR-3`) на идентичном предзаполненном датасете масштаба 5x (50 000 аккаунтов, 25 000 000 уведомлений) по задержкам чтения, сквозной скорости доставки (E2E WebSocket/Push), нагрузке на PostgreSQL и максимальной пропускной способности (Breakpoint RPS).
- Проверить все точки риска пути записи в `To-Be`: отсутствие очереди блокировок строк (`row lock contention`) при конкурентных `UPSERT` на вирусных постах, эффективность `fillfactor = 70` и `autovacuum` на `notification_groups` против MVCC bloat, а также отсутствие деградации $O(N^2)$ при удалении популярных статусов и массовой очистке ленты.
- Обеспечить воспроизводимое исполнение стенда на локальном хосте (Apple M5, 10 CPU, 32 ГБ RAM, 672 ГБ свободно на NVMe SSD) с исключением голодания генератора нагрузки (`Resource Starvation`).

**Non-Goals:**
- Нагрузочное тестирование федеративного транспорта ActivityPub (`ActivityPub::DeliveryWorker` и исходящие запросы на внешние инстансы).
- Тестирование клиентского рендеринга DOM/React в реальном браузере (используется протокольная эмуляция REST + WebSocket клиентов).
- Развертывание распределенной мульти-нодовой инфраструктуры с отдельной физической Read-репликой (в `config/database.yml` `primary` и `replica` направляются на один сервер PostgreSQL, что сохраняет работу обертки `with_read_replica` в `Api::V2::NotificationsController`).

## Decisions

### 1. Бюджетирование ресурсов на едином хосте и калибровка буферного пула PostgreSQL

Все компоненты стенда запускаются на одной рабочей машине с жесткими квотами воркеров и памяти, чтобы исключить перегрузку CPU и вытеснение генератора трафика (`k6`) при деградации `As-Is`:

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│             БЮДЖЕТ РЕСУРСОВ СТЕНДА: APPLE M5 (10 CORES / 32 GB RAM)                     │
├─────────────────────────────────────────────────────────────────────────────────────────┤
│  [ macOS + IDE + Агент ]         ──▶ Резерв: ~2 ядра, ~10 ГБ RAM                        │
│                                                                                         │
│  [ Генератор трафика (k6) ]      ──▶ HTTP REST + k6/ws (SharedArray для памяти)        │
│                                      Бюджет: ~1.5 ядра, ~1 ГБ RAM                       │
│                                                                                         │
│  [ Puma (RAILS_ENV=production) ] ──▶ WEB_CONCURRENCY=2, MAX_THREADS=5 (10 потоков)      │
│                                      Бюджет: ~1.5 ядра, ~2.5 ГБ RAM                     │
│                                                                                         │
│  [ Sidekiq (Core + I/O queues) ] ──▶ SIDEKIQ_CONCURRENCY=10 (default, push, mailers...) │
│                                      Бюджет: ~1.5 ядра, ~2 ГБ RAM                       │
│                                                                                         │
│  [ Node.js Streaming ]           ──▶ 1 воркер WebSocket (/api/v1/streaming)             │
│                                      Бюджет: ~0.5 ядра, ~500 МБ RAM                     │
│                                                                                         │
│  [ Mock Gateway (Go/Node.js) ]   ──▶ WebPush HTTP (25–50 мс) + SMTP Sink (15–30 мс)     │
│                                      Бюджет: ~0.5 ядра, ~200 МБ RAM                     │
│                                                                                         │
│  [ Redis ]                       ──▶ Очереди Sidekiq + Pub/Sub + notif-group бакеты     │
│                                      Бюджет: ~0.5 ядра, ~1 ГБ RAM                       │
│                                                                                         │
│  [ PostgreSQL (Single Server) ]  ──▶ shared_buffers=4GB, work_mem=16MB,                 │
│                                      max_parallel_workers=2, max_connections=100        │
│                                      Бюджет: ~2 ядра, ~6–8 ГБ RAM (включая кэш ОС)      │
└─────────────────────────────────────────────────────────────────────────────────────────┘
```

- **Обоснование калибровки `shared_buffers = 4GB`:** При масштабе 5x полный объем БД составляет ~16–22 ГБ, а таблица `notifications` с индексами занимает ~12 ГБ. Ограничение буферного пула до 4 ГБ (~20% размера БД) моделирует реальный продакшен, где рабочий набор превышает RAM. Старые запросы (`WITH RECURSIVE`, 200 подзапросов `unnest` и 100-уровневый CTE для DM) вызывают вымывание кэша и случайные чтения с диска, тогда как компактные таблицы `notification_groups` (~1.2 млн строк ≈ 250–300 МБ) и `dm_thread_permissions` (< 20 МБ) полностью удерживаются в памяти.
- **Альтернатива:** Выделение `shared_buffers = 16GB`. Отклонено: вся таблица `notifications` поместилась бы в память, скрыв ключевую разницу по дисковому Random Read I/O между `As-Is` и `To-Be`.

### 2. Раздельный Bulk SQL Seeder (5x), ссылочная целостность и «Золотой слепок» (`Golden Snapshot`)

Генератор базы отделен от генератора трафика. Для заливки 25 млн строк за несколько минут вместо медленного `ActiveRecord` используется потоковый SQL (`INSERT INTO ... SELECT generate_series` / `COPY`) с отключением вторичных индексов на время вставки, последующим построением индексов, выравниванием всех последовательностей `setval()` и обязательным `VACUUM ANALYZE`. Все сгенерированные даты `created_at` укладываются в диапазон **последних 90 дней** (`NOW() - interval '90 days' .. NOW()`), строго соответствуя 90-дневному окну Backfill-процедуры To-Be. Для первичных ключей `statuses.id` формируются синтетические 64-битные Snowflake-идентификаторы с монотонным распределением миллисекундных эпох во избежание коллизий 16-битного счетчика функции `timestamp_id`.

| Сущность / Таблица | Объем (5x) | Структура и распределение (Data Skew) |
| :--- | :--- | :--- |
| **Аккаунты и политики** (`accounts`, `users`, `account_stats`, `oauth_access_tokens`, `notification_policies`, `web_push_subscriptions`, `markers`) | 50 000 аккаунтов | • 250 «Селебрити» (0.5%), 5 000 «Активных авторов / DM» (10%), 44 750 «Читателей / Ботов» (89.5%).<br>• `users`: `confirmed_at = NOW()`, `approved = true`, `disabled = false`, `current_sign_in_at = NOW()`, `last_sign_in_at = NOW()`; для оффлайн-когорты email в JSON `users.settings` обязательно активны: `notification_emails.favourite = true`, `notification_emails.reblog = true`, `notification_emails.follow = true`, `notification_emails.mention = true` (плюс `always_send_emails = true` для форсирования).<br>• `oauth_access_tokens`: `scopes = 'read write follow push'`, `last_used_at = NOW()`.<br>• 15 000 аккаунтов: `for_private_mentions` = `filter` (1) или `drop` (2) для проверки DM.<br>• 100% аккаунтов Селебрити и Читателей: инициализированные `markers` (`timeline = 'notifications'`).<br>• 10 000 аккаунтов: активные `web_push_subscriptions` с локальным `endpoint`, P-256 ключами и JSON `data` (`policy: 'all'`, `alerts` для всех типов).<br>• 1–2% авторов: приостановлены (`suspended_at IS NOT NULL` / `requested_deletion_at IS NOT NULL`) для верификации `without_suspended`. |
| **Вирусные посты и реакции** (`statuses`, `favourites`, `notifications`, `polls`) | 250 постов (~10 000 000 уведомлений) | • По 25 000–50 000 реакций на пост в 1–3 12-часовых бакетах `group_key` (в пределах 90 дней).<br>• Для `type = 'reblog'` создаются реальные статусы-реблоги (`reblog_of_id = target_status_id`). Для `type = 'poll'` создаются записи в таблице `polls`. |
| **Глубокие DM-треды** (`statuses` `visibility = 3`, `conversations`, `mentions`, `notifications`) | 1 000 тредов (~250 000 сообщений) | • Цепочки `in_reply_to_id` глубиной 100–500 сообщений в пределах 90 дней.<br>• Все получатели имеют `for_private_mentions IN (filter, drop)` и не подписаны на авторов.<br>• 500 легитимных тредов: ответ получателя расположен на глубине **50–95 сообщений от листа** (гарантирует нахождение ответа до срабатывания As-Is лимита `depth_limit: 100`).<br>• 500 спам-тредов без ответа получателя (глубина 100–500). Для каждого треда в `seed_manifest.json` экспортируется тройка `(leaf_status_id, sender_account_id, recipient_acct)`, где `sender_account_id` является автором или участником листового статуса, удовлетворяя проверке `StatusPolicy#show?`. |
| **Запросы на переписку** (`notification_requests`, `notifications`) | 1 000 запросов (~10 000 отфильтрованных уведомлений) | • Предзаполненные записи `notification_requests` со связанными `notifications` (`filtered = true`, `group_key = NULL`) для тестирования `UnfilterNotificationsWorker`. |
| **Фоновая социальная активность** (`follows`, `favourites`, `statuses`, `mentions`, `notifications`) | ~14 740 000 уведомлений | • Распределение по закону Парето по 50 000 аккаунтам (все в пределах 90 дней): 60% `favourite`, 20% `reblog`, 12% `follow`, 8% негруппируемых (`mention`, `status`, `poll`). |

- **Гарантия полиморфной целостности и выравнивание последовательностей:** `Api::V2::NotificationsController#index` вызывает `Notification.preload_cache_collection_target_statuses`, загружая реальные `Favourite`, `Status` (включая цепочку `status.reblog`), `Mention`, `Poll` и `Follow` по `activity_id`. Сидер формирует полноценные записи во всех целевых таблицах активностей. По завершении вставки выполняется `SELECT setval(pg_get_serial_sequence(t, 'id'), coalesce(max(id), 1)) FROM t` для всех задействованных таблиц (`notifications`, `users`, `oauth_access_tokens`, `web_push_subscriptions` и др.).
- **Экспорт `seed_manifest.json`:** По завершении генерации сидер выгружает JSON-манифест с OAuth-токенами, ID когорт (`celebrities`, `active_readers`, `dm_participants`, `spammers`, `mutation_accounts`, `suspended`), списком предзаполненных вирусных постов с 25k–50k реакций, списком троек DM-тредов `(leaf_status_id, sender_account_id, recipient_acct)` и списком `notification_requests.id`.
- **Методология «Золотого слепка» (`Golden Snapshot`) через APFS CoW:**
  1. Заливка эталонного датасета в схему `As-Is` → остановка PostgreSQL → создание моментального снимка каталога данных через Copy-on-Write (`cp -c -R pgdata pgdata_asis`) на файловой системе APFS (занимает <1 секунды и не дублирует физические блоки диска).
  2. Запуск PostgreSQL → накатка миграций `ADR-1..3` → запуск и **тайминг процедуры Backfill** на 25 млн строк с фиксацией размеров `notification_groups` и `dm_thread_permissions` → остановка PostgreSQL → создание APFS-слепка `cp -c -R pgdata pgdata_tobe`.
  3. **Строгая изоляция и сброс перед КАЖДЫМ прогоном:**
     - Остановка PostgreSQL, мгновенный откат рабочего каталога через APFS (`rm -rf pgdata && cp -c -R pgdata_asis pgdata` или `pgdata_tobe`), запуск PostgreSQL.
     - Очистка очередей Sidekiq и Redis (`FLUSHDB`) строго **до** открытия WebSocket-соединений, чтобы `streaming/index.js` успел записать ключи `subscribed:timeline:*`.
     - 60-секундная фаза прогрева (`Warm-up`).
     - **Сброс статистики `pg_stat_statements_reset()` строго ПОСЛЕ окончания 60-секундного Warm-up**, перед началом зачетного интервала измерений (исключает влияние холодного кэша и случайного дискового I/O прогрева).

### 3. Легкий Mock-сервер внешних шлюзов (WebPush & SMTP) и настройка стенда

Для проверки полной асинхронной ветки доставки без обращения к реальным серверам Google/Apple/SMTP поднимается локальный Mock-шлюз:
- **WebPush Sink:** HTTP-сервер, принимающий `POST` от `Web::PushNotificationWorker` с искусственной задержкой `25–50 мс` (или неблокирующей очередью в стресс-тесте) и возвращающий `201 Created`, подсчитывая принятые уведомления.
- **SMTP Sink:** Локальный SMTP-приемник для `ActionMailer` (`NotificationMailer`) с искусственной задержкой `15–30 мс`, подсчитывающий отправленные письма. Учитывается задержка `deliver_later(wait: 2.minutes)`: после окончания нагрузочной фазы выдерживается 2-минутный дренаж для подсчета отложенных писем, а перед началом замера сбрасываются фоновые задачи, оставшиеся от прогрева.

Для корректной работы реального кода Mastodon с локальным стендом и Mock-шлюзом применяются обязательные конфигурационные меры:
1. **Криптографически валидные WebPush-ключи и обязательные production-секреты:** При генерации `web_push_subscriptions` используются валидные P-256 ключи (`key_p256dh`, `key_auth`), проходящие `WebPushKeyValidator`, а в поле `data` прописывается JSON с активными оповещениями. В окружение стенда передаются обязательные секреты: `LOCAL_DOMAIN=localhost:3000`, `SECRET_KEY_BASE`, `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` и `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`, `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY`, `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT`. Для To-Be обязательно передается `PRECOMPUTED_NOTIFICATION_GROUPS=true`. Для предотвращения записи на реплике передается `REPLICA_DB_HOST=127.0.0.1` и `REPLICA_DB_PORT=5432`.
2. **Разрешение локальных адресов и обход SSL-редиректа:** Для разрешения локальных соединений передается `ALLOWED_PRIVATE_ADDRESSES=127.0.0.1,::1`. Во избежание `301 Moved Permanently` из-за `config.force_ssl = true` в `production.rb`, генератор `k6` передает заголовок `X-Forwarded-Proto: https` во всех HTTP-запросах. При этом, поскольку заголовок `X-Forwarded-Proto: https` заставляет контроллеры Mastodon генерировать URL-ы в заголовке `Link` со схемой `https://`, генератор `k6` парсит из `Link` исключительно параметры курсора (`max_id`, `min_id`) и формирует последующие HTTP-запросы напрямую к plain-HTTP порту Puma (`http://localhost:3000`), предотвращая сбои TLS handshake. Для SMTP используется `SMTP_SERVER=127.0.0.1`, `SMTP_PORT`, `SMTP_ENABLE_STARTTLS_AUTO=false`.
3. **Отключение HTTP и бизнес-троттлинга в тестовом контуре:** Поскольку в кодовой базе Mastodon отсутствуют встроенные флаги отключения лимитеров, создается выделенный тестовый initializer `config/initializers/00_load_test_bypass.rb`. При наличии флага `LOAD_TEST_MODE=true` он устанавливает `Rack::Attack.enabled = false` и переопределяет метод `RateLimiter#rate_limited?` (или поднимает пороги `RateLimiter::FAMILIES` до бесконечности), гарантируя, что ни сетевой слой `Rack::Attack`, ни прикладной `RateLimiter` (300 статусов / 3ч, 400 подписок / 24ч) не вернут ложные `429 Too Many Requests` в ходе стресс-тестирования.
4. **Защита от голодания воркеров Sidekiq:** При задержке Mock WebPush 25–50 мс 10 потоков Sidekiq способны обслужить не более 200–400 вызовов/сек. Для исключения зависания очередей задачи распределяются по пулам воркеров (Core-пул для `LocalNotificationWorker` и I/O-пул для `push`/`mailers`), либо Mock-шлюз переводится в режим ультра-быстрого подтверждения с асинхронным подсчетом.

### 4. Генератор трафика (`k6`): 4 пользовательских профиля и 3 прогона

В качестве генератора выбран **`k6`** (Go-рантайм с низким оверхедом на CPU, встроенными `http` и `k6/ws`, поддержкой `randomSeed`, кастомных трендов `Trend`/`Counter` и `SharedArray` для эффективного разделения 50 000 токенов в памяти без GC-пауз).

**Профили виртуальных пользователей (Virtual Users):**
1. **Селебрити (~2% пула, ~60% входящей нагрузки реакций):** держит открытый WebSocket (`stream=user:notification`), опрашивает `GET /api/v2/notifications/unread_count` (с использованием предзаполненного маркера), читает `GET /api/v2/notifications` (первая страница + скролл 2–4 страниц по курсорам `max_id` и `min_id`, извлекаемым из заголовка `Link` со схемой `http://` + инкрементальная подгрузка по `since_id`), детальный просмотр `GET /api/v2/notifications/:group_key` (`#show`, с верификацией отсутствия пагинационных атрибутов `page_min_id`, `page_max_id`, `latest_page_notification_at`), периодический сдвиг курсора `POST /api/v1/markers` (с допуском `409 Conflict` как штатной оптимистичной блокировки).
2. **Активный читатель (~80% пула):** ставит реакции (`POST /api/v1/statuses/:id/favourite`, `/reblog`), подписывается (`POST /api/v1/accounts/:id/follow`), публикует реплаи (`ungrouped-{id}`), читает ленту с параметрами Web-клиента (`grouped_types[]=favourite&grouped_types[]=reblog&grouped_types[]=follow`), фильтрует вкладку `types[]=mention` и через `exclude_types[]`, проверяет оба режима `expand_accounts=partial_avatars` и `full`, запрашивает участников группы `GET /api/v2/notifications/:group_key/accounts`.
3. **Участник глубоких DM / Cold DM Spammer (~13% пула — проверка ADR-3):** отправляет ответы в глубокие DM-треды (`POST /api/v1/statuses` с `visibility=direct`, `in_reply_to_id` глубиной 100–500, обязательно передавая `@recipient_acct` в тексте): 50% от легитимного собеседника (где ответ получателя лежит на глубине 50–95 сообщений) и 50% от спам-авторов из `seed_manifest.json` (где спаммер является автором или участником листового статуса, удовлетворяя `StatusPolicy#show?`, но провоцируя проверку `statuses_that_mention_sender` / `dm_thread_permissions`).
4. **Генератор мутаций и очистки (~5% пула):** оперирует на изолированной когорте `mutation_accounts` (чтобы не нарушать базовые ленты читателей): отменяет реакции (`POST /api/v1/statuses/:id/unfavourite`), редактирует статусы (`PUT /api/v1/statuses/:id`), блокирует пользователей (`POST /api/v1/accounts/:id/block`), одобряет и отклоняет запросы (`GET /api/v1/notifications/requests` -> `POST .../:id/accept` / `/dismiss`), удаляет одиночные группы (`POST /api/v2/notifications/:group_key/dismiss`), очищает уведомления (`POST /api/v2/notifications/clear`) и удаляет статусы (`DELETE /api/v1/statuses/:id`).

**Три последовательных прогона (каждый начинается с обязательного CoW-отката слепка БД, сброса Redis, 60-секундного прогрева и сброса статистики `pg_stat_statements_reset()` ПОСЛЕ прогрева):**
- **Прогон 1 — Baseline Mixed Load (10 мин):** 1 000 постоянных WebSocket-клиентов + стабильный смешанный HTTP-поток (70% чтение / 30% запись и мутации). Цель: измерить базовые `p50/p95/p99` чтения, сквозную WebSocket-доставку, накладные расходы на `LocalNotificationWorker`, обработку глубоких DM и CPU/I/O PostgreSQL.
- **Прогон 2 — Viral Spike & Status Deletion (5 мин):**
  - *Фаза А (0:00–3:30):* 5 селебрити публикуют свежие посты; пул записи направляет шквал лайков и репостов в эти 5 постов при одновременном чтении лент селебрити (проверка конкуренции строк при `UPSERT` и роста латентности `As-Is`).
  - *Фаза Б (3:30–5:00):* удаление одного из предзаполненных вирусных постов с 25 000–50 000 реакций из `seed_manifest.json` (`DELETE /api/v1/statuses/:id`), свежего вирусного поста из Фазы А, и вызов `POST /api/v2/notifications/clear` у автора. Фиксируется не только HTTP-ответ API, но и полное время асинхронной очистки очередей Sidekiq (`RemovalWorker`).
- **Прогон 3 — Stress / Breakpoint Ramp-Up (10 мин):** ступенчатое масштабирование смешанной нагрузки каждые 2 минуты (`1x → 2x → 4x → 8x → 12x` базового RPS) до наступления точки насыщения: `p95` чтения > `500 мс` или задержка очереди Sidekiq / E2E WebSocket > `2 000 мс`.

### 5. Матрица метрик и количественные критерии победы (Pass/Fail Thresholds)

| Группа метрик | Конкретные показатели | Количественный критерий успешности (To-Be vs As-Is) |
| :--- | :--- | :--- |
| **Чтение API v2 (Client HTTP, Прогон 1)** | `p50`, `p95`, `p99` и error rate для `notifications#index` (Селебрити и Обычные), `unread_count`, `show` | **`p95` чтения ленты селебрити снижается $\ge 5$ раз и $\le 25$ мс** на тестовом стенде; error rate = 0% |
| **Запись и сквозная доставка (E2E, Прогон 1)** | `E2E WebSocket Latency` (`ws_received - http_post_sent`), синхронная задержка `POST /api/v1/statuses` (DM), время выполнения `LocalNotificationWorker` (обычные реакции vs глубокие DM), счетчики Mock WebPush/SMTP | **Оверхед на обычную запись $\le 5$ мс**; **обработка входящих DM в глубоких тредах ускоряется $\ge 5$ раз**; **функциональная эквивалентность (Delivery Parity = 100%): отношение доставленных уведомлений к успешным HTTP 201 событиям идентично в As-Is и To-Be, 100% доставка для контрольных легитимных DM и 0% утечек для спам-веток** |
| **Внутренние метрики PostgreSQL (Прогон 1)** | `pg_stat_statements` (общее время выполнения `total_exec_time`), промахи буферного пула `shared_blks_read`, ожидания блокировок (`lock_wait`), `n_dead_tup` bloat | **`total_exec_time` и `shared_blks_read` снижаются $\ge 3$ раз**; **доля мертвых кортежей `n_dead_tup::float / NULLIF(n_live_tup + n_dead_tup, 0) <= 0.25`** в таблице `notification_groups` |
| **Устойчивость к мутациям (Прогон 2)** | Время завершения `RemovalWorker` для вирусного статуса с 25 000+ реакций, ошибки блокировок строк | **0 таймаутов блокировок и дедлоков**, отсутствие шторма $O(N^2)$ при фоновой очистке групп |
| **Пропускная способность (Breakpoint, Прогон 3)** | Максимальный устойчивый RPS до нарушения SLA (`p95 read <= 500 мс` и `E2E WS <= 2 000 мс`) | **Breakpoint RPS в `To-Be` возрастает $\ge 2$ раз** относительно `As-Is` |

## Risks / Trade-offs

- **[Risk] Конкуренция за CPU между генератором `k6` и тестируемым приложением на одном ноутбуке (эффект наблюдателя)** → **Mitigation:** Жесткое ограничение воркеров (`WEB_CONCURRENCY=2`, `SIDEKIQ_CONCURRENCY=10`, `max_parallel_workers=2`), резерв ~2 ядер для ОС, использование `SharedArray` в `k6` и мониторинг CPU процесса `k6` в ходе каждого прогона.
- **[Risk] Длительное время отката слепков БД (~16–22 ГБ)** → **Mitigation:** Использование APFS Copy-on-Write (`cp -c -R pgdata pgdata_snapshot`), обеспечивающего мгновенное создание и восстановление снимка (<1 с) без дублирования блоков диска.
- **[Risk] Искажение замеров из-за холодного кэша ОС и PostgreSQL сразу после восстановления слепка** → **Mitigation:** Обязательная 60-секундная фаза прогрева (`Warm-up`) в начале каждого из 3 прогонов, с вызовом `pg_stat_statements_reset()` строго по завершении прогрева перед снятием телеметрии.
- **[Risk] Исключение валидации rate-limiters скрывает потенциальные лимиты API** → **Mitigation:** Отключение касается только `Rack::Attack` и `RateLimiter` в тестовом контуре; все проверки OAuth-токенов (`doorkeeper_authorize!`), приватности DM (`StatusPolicy`) и `NotificationPolicy` работают в полном объеме.
