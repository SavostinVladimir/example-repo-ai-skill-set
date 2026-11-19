# Реестр архитектурных решений (ADR) — Проект "Оптимизация нотификаций"

В этом файле фиксируются все ключевые архитектурные решения, принятые в рамках проекта **"Оптимизация нотификаций"**.

---

## Правила работы с ADR

1. **Иммутабельность (Append-only):** Принятые записи не переписываются и не удаляются. Если архитектурное решение меняется или отменяется, создается новый ADR, а в старом выставляется статус `Superseded by ADR-X` со ссылкой на новую запись.
2. **Своевременность:** ADR формируется до начала масштабной реализации в процессе обсуждения архитектуры, а не постфактум.
3. **Объективность и честные компромиссы (Trade-offs):** Идеальных решений без минусов не существует. В каждой записи обязательно фиксируются недостатки, ограничения, риски и накладные расходы выбранного подхода.
4. **Нумерация и именование:** Каждая запись строго нумеруется по порядку (`ADR-1`, `ADR-2`, ...) и имеет понятный заголовок, отражающий суть принятого решения.
5. **Жизненный цикл статусов:**
   * `Proposed` — решение предложено, находится на этапе обсуждения/валидации.
   * `Accepted` — решение согласовано командой и обязательно к реализации.
   * `Rejected` — решение отклонено по результатам анализа (сохраняется для истории, чтобы не возвращаться к нежизнеспособным идеям).
   * `Superseded by ADR-X` — решение устарело и заменено записью `ADR-X`.
   * `Deprecated` — функциональность выведена из эксплуатации.

---

## Формат и шаблон записи ADR

Каждая новая запись должна следовать следующей структуре:

```markdown
### ADR-N: [Название принятого решения]

* **Дата:** YYYY-MM-DD
* **Статус:** [Proposed | Accepted | Rejected | Superseded by ADR-X]
* **Автор(ы):** [Имена / логины участников]

#### 1. Краткое описание (Summary)
Краткая суть изменения в 2–3 предложениях (что именно меняем и в каком компоненте).

#### 2. Описание проблемы и контекст (Context & Problem Statement)
* Какую проблему мы решаем (узкие места, метрики, задержки, надежность)?
* Какие существуют ограничения (технические, обратная совместимость, требования к SLA/нагрузке, сроки)?

#### 3. Варианты решения и альтернативы (Options Considered)
* **Вариант 1:** [Название]
  * *Суть:* ...
  * *Плюсы:* ...
  * *Минусы и риски:* ...
* **Вариант 2:** [Название]
  * *Суть:* ...
  * *Плюсы:* ...
  * *Минусы и риски:* ...

#### 4. Принятое решение и обоснование (Decision & Rationale)
* **Выбранный вариант:** [Вариант X]
* **Обоснование:** Почему выбран именно этот подход, какие критерии стали решающими и почему отвергнуты альтернативы.

#### 5. Последствия (Consequences)
* **Положительные:** Ожидаемые улучшения (снижение нагрузки на БД, уменьшение задержки доставки и т.д.).
* **Отрицательные и риски:** Появившиеся накладные расходы (дополнительная инфраструктура, усложнение отладки, необходимость миграции данных).
* **Дальнейшие шаги:** Что требуется сделать для внедрения (настройка мониторинга, схема миграции, фиче-флаги).
```

---

## Записи решений

### ADR-1: Введение таблицы Write-Time группировки `notification_groups` для пагинации API v2

* **Дата:** 2026-11-19
* **Статус:** Accepted
* **Автор(ы):** Команда платформы / Архитектурное ревью

#### 1. Краткое описание (Summary)
Переход от вычисляемой при чтении рекурсивной группировки ленты уведомлений (`WITH RECURSIVE ... LATERAL` в `Notification.paginate_groups` из concern `Notification::Groups`) к материализации групп на этапе записи (Write-Time Grouping) в выделенной таблице PostgreSQL `notification_groups`.

#### 2. Описание проблемы и контекст (Context & Problem Statement)
* В текущей реализации эндпоинт `GET /api/v2/notifications` выполняет до 40 последовательных итераций `LATERAL` по умолчанию (до 80 при `limit=80`), а `GET /api/v2/notifications/unread_count` — до 100 итераций по умолчанию (до 1 000 максимум при `MAX_NOTIFICATIONS_COUNT_LIMIT`) с `INNER JOIN accounts` и проверкой `NOT group_key = ANY(wt.groups)`. На вирусных постах с тысячами однотипных реакций подряд планировщик перебирает тысячи индексных записей на каждый HTTP-запрос (ориентировочные задержки 150–500 мс, высокая утилизация CPU; базовый профиль подлежит замеру в `notification-load-testing`).
* Ограничения: сохранение 100% обратной совместимости контрактов API v2 (`types[]`, `exclude_types[]`, `grouped_types[]` — Web-клиент по умолчанию передает `['favourite', 'reblog', 'follow']` и `['favourite', 'reblog']` при отключённой опции группировки подписок, тогда как `GROUPABLE_NOTIFICATION_TYPES` также включает `admin.sign_up`; `without_suspended`, включающий и `suspended_at`, и 30-дневное окно `requested_deletion_at`; пагинация по `notifications.id` в обе стороны — `DESC` для `max_id`/`since_id` и `ASC` + `.reverse` для `min_id`).

#### 3. Варианты решения и альтернативы (Options Considered)
* **Вариант 1:** Хранение лент групп в Redis Sorted Sets (`ZADD user_notifications:{account_id}`).
  * *Суть:* Поддерживать отсортированное множество `group_key` в памяти Redis на каждого пользователя.
  * *Плюсы:* Чтение `ZREVRANGEBYSCORE` за $< 1$ мс, разгрузка PostgreSQL на скролле.
  * *Минусы и риски:* Огромный расход RAM (~13 ГБ на 100k пользователей при переходе из `listpack` в `skiplist`), невозможность фильтрации по `types[]` и `without_suspended`, невозможность отката `score` при отмене лайков/батчевых `delete_all` и необходимость все равно догружать модели из PostgreSQL.
* **Вариант 2:** Таблица `notification_groups` в PostgreSQL с составным ключом `(account_id, group_key)`.
  * *Суть:* Транзакционный `UPSERT` в одной транзакции PostgreSQL с записью видимого уведомления (`filtered = false`) в `notifications`; в `UnfilterNotificationsWorker` (где у карантинных уведомлений `group_key IS NULL`) — атомарный `UPDATE notifications SET filtered = false, group_key = ... FROM (VALUES ...) WHERE ... AND filtered = true RETURNING ...` (с детерминированным вычислением двустороннего 12-часового окна без перезаписи более свежих 12-часовых Redis-бакетов либо с ключом `ungrouped-<id>`) в одной транзакции с преагрегированным и отсортированным по `(account_id, group_key)` многострочным `UPSERT` (защита от `PG::NotNullViolation`, `PG::CardinalityViolation`, дедлоков и ретраев Sidekiq). Группируются только 3 типа (`favourite`, `reblog`, `follow`), а все негруппируемые типы — включая `admin.sign_up` — материализуются как одиночные строки `ungrouped-<notification_id>` (единая функция `storage_group_key`, `NOT NULL` PK и плоский запрос без проверок ролей модераторов). В схеме добавляется опциональная колонка `target_status_id` с частичным индексом `(account_id, target_status_id) WHERE target_status_id IS NOT NULL` для индексного удаления групп реакций без локалезависимого `LIKE` и основной индекс `(account_id, most_recent_notification_id DESC, type)`. Запросы с дефолтным `grouped_types = nil` также обслуживаются из `notification_groups` и уходят в legacy fallback только если в выборке реально встретился `type = 'admin.sign_up'` (в `#unread_count` — через `BOOL_OR(type = 'admin.sign_up')`). В legacy `notifications` маршрутизируются запросы с нестандартным `grouped_types[]` (включая Web-настройку `['favourite', 'reblog']`), `include_filtered=true`, а также запросы глубже персистентно хранимого в PostgreSQL watermark `backfill_cutoff_id` (строгий фильтр `most_recent_notification_id > backfill_cutoff_id` при чтении, передача `exclude_group_keys` в базовый и рекурсивный шаги CTE на стыке неполной страницы и fallback для `#unread_count`, если `last_read_id` отсутствует или `< backfill_cutoff_id` при числе групп `< limit`).
  * *Плюсы:* Чтение за один прямой `Index Scan` по `DESC`-индексу для основного запроса `ORDER BY most_recent_notification_id DESC` (`Index Scan Backward` только при пагинации вверх по `min_id` / `ASC`) за 1–3 мс (целевой SQL-ориентир), нативная фильтрация по `type`, единое пространство ID пагинации с таблицей `notifications` и WebSocket, ACID-гарантии.
  * *Минусы и риски:* Отключение `HOT update` в PostgreSQL при обновлении индексируемого `most_recent_notification_id`; необходимость явной синхронизации для всех `.delete_all` и одиночных `destroy` путей (`Notification#after_destroy`/`after_destroy_commit`, `Api::V1::NotificationsController#clear`, `Api::V2::NotificationsController#clear`, `LocalNotificationWorker`, `AfterBlockService`, `AfterBlockDomainFromAccountService`, `DeleteAccountService::ASSOCIATIONS_ON_PURGE` и `purge_generated_notifications!`) и всех переходов `Account.without_suspended` (`Account::Suspensions#suspend!`/`unsuspend!`, `Account#mark_deleted!`, `BlockDomainService`, `UnblockDomainService`, `UnallowDomainService`, `Scheduler::SelfDestructScheduler`) через асинхронный `RecomputeNotificationGroupWorker` и батчевый `SyncAccountNotificationGroupsWorker`; поддержка `storage_group_key` (`ungrouped-<id>`) и fallback-маршрутов.

#### 4. Принятое решение и обоснование (Decision & Rationale)
* **Выбранный вариант:** Вариант 2 (`notification_groups` в PostgreSQL с составным PK `(account_id, group_key)`).
* **Обоснование:** Обеспечивает снижение задержки на 2 порядка без взрывного роста стоимости RAM (в отличие от Redis) и полностью поддерживает пользовательские фильтры и курсоры пагинации API v2. Использование составного PK `(account_id, group_key)` исключает лишний индекс и sequence для суррогатного `timestamp_id`.

#### 5. Последствия (Consequences)
* **Положительные:** Снижение SQL-латентности `unread_count` до 1–5 мс p95 напрямую за счёт `ADR-1`, а SQL-фазы `index` (`GET /api/v2/notifications`) — до 1–5 мс p95 (при полном HTTP `<= 25` мс p95) **в связке с `ADR-2`** (устраняющим `load_groups_data`), устранение рекурсивного CTE (целевые ориентиры верифицируются в `notification-load-testing`).
* **Отрицательные и риски:** Увеличение write amplification и риска bloat в `notification_groups` на вирусных постах, рост объёма за счёт материализации `ungrouped-<id>`, необходимость поддержки Dual-Write, синхронизации во всех точках массового удаления/суспенда и legacy fallback-маршрутов.
* **Дальнейшие шаги:** Настроить на таблице агрессивный `autovacuum` (`autovacuum_vacuum_scale_factor = 0.01`, `autovacuum_vacuum_cost_limit = 1000`) и регламентный `pg_repack`, а пониженный `fillfactor` (`80`) задавать именно на вторичном B-tree индексе `index_notification_groups_pagination` (табличный `fillfactor = 70` при отключённом `HOT update` не даёт HOT-выигрыша и раздувает heap в `shared_buffers` на ~43%). Провести Zero-Downtime выкатку по фазам: `DDL` (транзакционное создание `notification_groups` с индексами; `algorithm: :concurrently` + `disable_ddl_transaction!` для индекса на существующей таблице) → `Dual-Write` → идемпотентный backfill за 90 дней с фиксацией watermark `backfill_cutoff_id` в PG → `Shadow Reconciliation` (`mismatch_rate < 0.01%`) → `Canary Read Ramp` (`1% → 10% → 50% → 100%`). Подключить раздельные динамические Redis Kill-Switch (`notification_groups:write_enabled` с `last-known-good` при сбое Redis и `notification_groups:read_rollout_pct` + PG-latch `dirty_since`), план отката (снижение `read_rollout_pct → 0` без потери данных; запрет повторного включения чтения после `write_enabled = false` без полного re-backfill/reconciliation окна) и метрики мониторинга (`read_duration`, `fallback_total`, `upsert_duration`, `recompute_enqueued_total`, `reconciliation_checked_total`, `reconciliation_mismatch_total`).

---

### ADR-2: Материализация агрегатов групп в `notification_groups` взамен до 200 (макс. до 400) подзапросов `unnest`

* **Дата:** 2026-11-19
* **Статус:** Accepted
* **Автор(ы):** Команда платформы / Архитектурное ревью

#### 1. Краткое описание (Summary)
Хранение предвычисленных агрегатов (`notifications_count`, `sample_account_ids bigint[]` с ограничением длины до 8 элементов в логике `UPSERT` и опционального `CHECK (cardinality(sample_account_ids) <= 8)`, `min_notification_id`, `most_recent_notification_id`, `latest_notification_at`) непосредственно в строке таблицы `notification_groups`, введённой в `ADR-1`, с точным вычислением постраничного `page_min_id` в приложении.

#### 2. Описание проблемы и контекст (Context & Problem Statement)
* Метод `NotificationGroup.load_groups_data` выполняет запрос `FROM unnest($3::text[])` с 5 коррелированными подзапросами на каждую группу, порождая до 200 отдельных сканирований индексов по умолчанию (40 групп × 5 подзапросов) и до 400 при максимальном `limit=80`, а также полный `SELECT count(*)` на каждый запрос ленты.
* Ограничения: сохранение контракта `REST::NotificationGroupSerializer` (выдача `page_min_id` в границах страницы в `#index` во избежание пропуска до 12 часов уведомлений в Web-клиенте, скрытие `pagination_data` при `paginated? == false` в `#show`), предотвращение дубликатов и гонок лидера в `sample_account_ids` и недопущение шторма пересчётов $O(N^2)$ при удалении популярных постов и при скрытии крупных групп (`Api::V2::NotificationsController#dismiss`).

#### 3. Варианты решения и альтернативы (Options Considered)
* **Вариант 1:** Хранение счетчиков и массивов участников в Redis Hash (`notif_group_data:{account_id}:{group_key}`).
  * *Суть:* Атомарный `HINCRBY` и обновление JSON-массива через Lua-скрипт (`EVALSHA`) в Redis.
  * *Плюсы:* Быстрый инкремент в памяти.
  * *Минусы и риски:* Расход ~15–25 ГБ RAM на 100k пользователей, дополнительный сетевой round-trip после чтения из БД (медленнее, чем чтение готовой строки из PostgreSQL), гонки `Lost Update` без Lua и рассинхрон с Read Replica PostgreSQL.
* **Вариант 2:** Материализация полей агрегатов в таблице `notification_groups` (PostgreSQL).
  * *Суть:* Дедуплицированное слияние массивов `EXCLUDED.sample_account_ids` и текущего `sample_account_ids` в `UPSERT` через `COALESCE(array_agg(...), '{}')` с `unnest(...) WITH ORDINALITY ... LIMIT 8` с приоритетом записи с большим `most_recent_notification_id` (корректно поддерживает многоавторные батчи `UnfilterNotificationsWorker` и сохраняет лидера; позиции 2..8 являются best-effort при out-of-order доставке Sidekiq). Точный расчёт `page_min_id` (единообразно для полных и неполных страниц, в том числе при `min_id` через `params[:min_id].to_i + 1`): для 95%+ групп (`pagination_range.begin.nil? || group.min_notification_id >= pagination_range.begin`) отдаётся `group.min_notification_id` без дополнительных запросов; только для граничных групп (0–2 на страницу), пересекающих `pagination_range.begin`, выполняется батчевый `Index Only Scan` (`SELECT g.group_key, (SELECT n.id FROM notifications n WHERE n.account_id = $1 AND n.group_key = g.group_key AND n.filtered = false AND n.type IN ('favourite', 'reblog', 'follow') AND n.id >= $3 ORDER BY n.id ASC LIMIT 1) ... FROM unnest($2::text[]) AS g(group_key)`) по частичному покрывающему индексу `index_notifications_on_group_recalculation`; в `#show` чтение агрегатов переводится на `notification_groups` (с fallback в `load_groups_data`) и `pagination_data = nil`. Для защиты от $O(N^2)$: в `RemoveStatusService` подавляется поштучный пересчёт при `remove_reblogs` (`original_removed: true`) как при безвозвратном, так и при мягком удалении (`discard_with_reblogs`); при мягком удалении пакетно удаляются `:reblog`-группы, а при безвозвратном — группы реакций оригинальных статусов (`!reblog?`) по `(account_id, target_status_id)` (без `LIKE`) с предварительным сбором чужих `ungrouped-<id>` по `notifications(activity_id, activity_type)` (`Status`, `Mention`, `Poll`, `Quote`); аналогично в `BatchedRemoveStatusService`; в `Api::V2::NotificationsController#dismiss` малые группы (`<= 100`, `ungrouped-*`, `filtered = true`) удаляются синхронно, а для крупных (`> 100`, с проверкой `LIMIT 101` при отсутствии строки в `notification_groups`) генерируется новый generation/nonce-суффикс бакета в Redis (предотвращая коллизии в том же UTC-часе), атомарно фиксируется `cutoff_id` через `DELETE ... RETURNING most_recent_notification_id` и запускается асинхронный `DismissNotificationGroupWorker(account_id, group_key, cutoff_id)`.
  * *Плюсы:* Полное устранение `unnest` и 200–400 подзапросов (`0` доп. запросов на чтение для 95%+ групп и 0–2 точечных `Index Only Scan` только для граничных групп), атомарность в одной транзакции при записи.
  * *Минусы и риски:* Запрет синхронных мутаций на Read Replica (`with_read_replica`) — восстановление рассинхронизированных групп выносится в дедуплицированный фоновый `RecomputeNotificationGroupWorker` (с пропуском записей моложе 60 секунд от лага репликации, пересчётом вне длинной блокировки и короткой критической секцией `FOR UPDATE` + перепроверкой `MAX(id)`); необходимость частичного покрывающего индекса `index_notifications_on_group_recalculation` на `notifications`; точечный пересчёт группы при отмене реакции/удалении лидера (`Notification#after_destroy` / `after_destroy_commit` + контекст подавления) и явная защита сериализатора от `nil` / `unavailable?` аккаунтов.

#### 4. Принятое решение и обоснование (Decision & Rationale)
* **Выбранный вариант:** Вариант 2 (материализация в `notification_groups`).
* **Обоснование:** Данные достаются единым запросом вместе с пагинацией без второго сетевого хопа, а пакетная предочистка групп по `(account_id, target_status_id)` с подавлением пересчётов на `remove_reblogs` и асинхронный `DismissNotificationGroupWorker` полностью исключают деградацию $O(N^2)$ в `after_destroy` и таймауты `#dismiss`.

#### 5. Последствия (Consequences)
* **Положительные:** Полная ликвидация `load_groups_data` N+1 подзапросов и тяжёлых `COUNT(*)`.
* **Отрицательные и риски:** Увеличение размера кортежа из-за массива `bigint[]`, write amplification на `notifications` от частичного индекса `index_notifications_on_group_recalculation` и необходимость контролировать целостность при всех путях `.delete_all` и переходах `without_suspended` (см. `ADR-1`).
* **Дальнейшие шаги:** Создать частичный покрывающий индекс `index_notifications_on_group_recalculation` (`algorithm: :concurrently`), реализовать защиту в `GroupedNotificationsPresenter` / `NotificationGroup` (исключение групп с `nil` notification или пустым `sample_accounts`), обновить `RemoveStatusService`, `BatchedRemoveStatusService`, `Api::V1::NotificationsController#clear`, `Api::V2::NotificationsController#clear`, `Api::V2::NotificationsController#dismiss` (`DismissNotificationGroupWorker`), `LocalNotificationWorker`, `AfterBlockService`, `AfterBlockDomainFromAccountService`, `DeleteAccountService` и `RecomputeNotificationGroupWorker`. Использовать общую с `ADR-1` схему Zero-Downtime выкатки, раздельные Redis Kill-Switch, `Shadow Reconciliation` и мониторинг (включая метрики `DismissNotificationGroupWorker` и `RecomputeNotificationGroupWorker`).

---

### ADR-3: Введение таблицы `dm_thread_permissions` для проверки цепочек личных сообщений

* **Дата:** 2026-11-19
* **Статус:** Superseded by ADR-4
* **Автор(ы):** Команда платформы / Архитектурное ревью

#### 1. Краткое описание (Summary)
Замена рекурсивного CTE `statuses_that_mention_sender` (глубиной до 100 уровней по таблицам `statuses` и `mentions`) на синхронно поддерживаемый индексированный реестр разрешений `dm_thread_permissions (account_id, target_account_id, conversation_id)`.

#### 2. Описание проблемы и контекст (Context & Problem Statement)
* В `NotifyService::BaseCondition#statuses_that_mention_sender` при каждом входящем личном сообщении от незнакомца выполняется рекурсивный CTE по иерархии `in_reply_to_id`, создающий случайные дисковые чтения (Random Read I/O) на критическом пути записи в Sidekiq.
* Ограничения: строгая изоляция от остальных политик фильтрации (`not_following`, `new_accounts`, `bots`), разрешение ответов строго в рамках конкретного DM-треда (блокировка новых `in_reply_to_id: nil`), игнорирование публичных ответов, защита от спуфинга `conversation` URI в ActivityPub (GHSA-5fq7-3p3j-9vrf) и поддержка федеративных серверов, присылающих собственный `conversation` URI.

#### 3. Варианты решения и альтернативы (Options Considered)
* **Вариант 1:** Проверка по существующей таблице `account_conversations` (`$sender = ANY(participant_account_ids)`).
  * *Суть:* Считать наличие общего диалога разрешением на отправку DM.
  * *Плюсы:* Переиспользование существующей таблицы `account_conversations` без миграций схемы БД и синхронизации новой таблицы.
  * *Минусы и риски:* Критическая уязвимость «Троянский конь» (в `account_conversations` попадают все участники входящих групповых DM без ответа получателя) и отсутствие GIN-индекса на `participant_account_ids` (перебор всех диалогов пользователя).
* **Вариант 2:** Автоматическая запись в существующую таблицу `notification_permissions`.
  * *Суть:* Выдавать разрешение при отправке DM через `NotificationPermission`.
  * *Плюсы:* Использование готовой модели `NotificationPermission` и проверки `override_for_sender?` без добавления новых таблиц.
  * *Минусы и риски:* `override_for_sender?` глобально отключает вообще все фильтры уведомлений для всех типов событий и не привязан к конкретному треду.
* **Вариант 3:** In-Memory Allowlist в Redis Set (`user_dialogs:{recipient_id}`).
  * *Суть:* Компактный `intset` в памяти Redis (~50 МБ на 100k пользователей) с sentinel-битом `"0"` против cache miss.
  * *Плюсы:* Субмиллисекундная проверка в RAM ($< 0.5$ мс) при компактном потреблении памяти (~50 МБ) и нулевой нагрузке чтения на PostgreSQL.
  * *Минусы и риски:* Меняет семантику с per-thread на per-account, требует защиты от рассинхронизации при холодном старте (ложное срабатывание `DropCondition` при промахе кеша).
* **Вариант 4:** Выделенная таблица `dm_thread_permissions` в PostgreSQL с `PRIMARY KEY (account_id, target_account_id, conversation_id)`.
  * *Суть:* Синхронная вставка в транзакции создания/активации не-тихого `Mention` в исходящем `direct`-статусе (до запуска воркеров доставки), проверка через `target_status.thread` по `[target_status.conversation_id, target_status.thread.conversation_id]` и наследование `conversation_id` в `Status#set_conversation` / `ThreadResolveWorker`.
  * *Плюсы:* Проверка за $O(1)$ (`Index Only Scan` за $< 0.2$ мс), сохранение точной per-thread семантики, полная персистентность и защита от атак через третьих лиц и спуфинг.
  * *Минусы и риски:* Необходимость аккуратного отзыва разрешения только при отсутствии других исходящих DM автора в том же треде.

#### 4. Принятое решение и обоснование (Decision & Rationale)
* **Выбранный вариант:** Вариант 4 (`dm_thread_permissions` в PostgreSQL).
* **Обоснование:** Единственное решение, которое одновременно ликвидирует рекурсивный CTE глубиной 100, сохраняет точные гарантии безопасности Mastodon (per-thread + защита от «Троянского коня» + изоляция остальных фильтров) и исключает риск потери DM при сбросе кеша.

#### 5. Последствия (Consequences)
* **Положительные:** Защита воркеров `LocalNotificationWorker` / `NotifyService` от дискового I/O при спам-атаках в глубоких тредах.
* **Отрицательные и риски:** Появление небольшой синхронной записи при отправке DM и дополнительной проверки при удалении/редактировании исходящих DM.
* **Дальнейшие шаги:** Создать таблицу `dm_thread_permissions`, обновить `Status#set_conversation`, `ThreadResolveWorker`, `PostStatusService`, `ProcessMentionsService`, `NotifyService` и покрыть тестами федеративные сценарии и удаление сообщений.


---

### ADR-4: Уточнение верификации `dm_thread_permissions` строго по родительскому треду и полный исторический бэкфилл

* **Дата:** 2026-11-19
* **Статус:** Accepted (Supersedes ADR-3)
* **Автор(ы):** Команда платформы / Архитектурное ревью

#### 1. Краткое описание (Summary)
Уточняет механизм проверки и бэкфилла `dm_thread_permissions` из `ADR-3`: проверка разрешения в `NotifyService::BaseCondition#response_to_recipient?` выполняется **строго** по `target_status.thread.conversation_id` (через `Status.unscoped`, без OR-объединения с `target_status.conversation_id`), а таблица наполняется полным историческим бэкфиллом без постоянного 90-дневного рекурсивного fallback.

#### 2. Описание проблемы и контекст (Context & Problem Statement)
* Проверка по массиву `[target_status.conversation_id, target_status.thread.conversation_id]` (OR-семантика из `ADR-3`) открывает кросс-тредовый обход антиспам-фильтра: злоумышленник с разрешением в диалоге `C1` может ответить на статус из чужого диалога `C2`, подставив внешний URI `C1` в ActivityPub payload.
* Ограничение бэкфилла 90 днями с постоянным fallback к рекурсивному CTE `statuses_that_mention_sender` оставляет открытым DoS-вектор: любой спамер без записи в `dm_thread_permissions` может привязать цепочку ответов к любому статусу старше 90 дней и принудительно запускать 100-шаговый CTE на каждый спам-DM.

#### 3. Варианты решения и альтернативы (Options Considered)
* **Вариант 1:** Оставить OR-проверку и 90-дневный рекурсивный fallback.
  * *Суть:* Проверять разрешения по паре идентификаторов `[target_status.conversation_id, target_status.thread.conversation_id]` и ограничивать первичный бэкфилл 90-дневным окном с постоянным fallback к рекурсивному CTE для старых тредов.
  * *Плюсы:* Минимальный объём первичного бэкфилла за счёт ограничения окном 90 дней.
  * *Минусы и риски:* Сохраняет обход фильтра приватности и DoS-вектор на PostgreSQL.
* **Вариант 2:** Строгая проверка родительского `conversation_id` + полный исторический бэкфилл `dm_thread_permissions` + индексы `(target_account_id)` и `(conversation_id)`.
  * *Суть:* Выдача разрешений строго внутри транзакции `@status.save!` (включая редактирование в `ProcessMentionsService`), безусловное наследование `conversation_id` от родителя (с каскадным обновлением в `ThreadResolveWorker` + перепроверкой `DropCondition`/`FilterCondition`), запрет привязки входящих `in_reply_to_id: nil` `direct`-статусов (или диалогов с записями в `dm_thread_permissions`) к существующим диалогам без поломки `ConversationMute` на не-DM ветках, и полный однократный бэкфилл исходящих `direct`-статусов по `Account.local` через `index_statuses_20190820` со сбором `conversation_id` потомков без мутации исторических `statuses.conversation_id`. Выдача и отзыв по `(account_id, conversation_id)` сериализуются 64-битным `pg_advisory_xact_lock(hashtextextended(...))` с атомарным `DELETE ... WHERE NOT EXISTS (...)` в едином контуре: `RemoveStatusService` (включая `discard_with_reblogs`), `BatchedRemoveStatusService`, `ProcessMentionsService` (при редактировании), синхронный `BlockService` (рядом с `NotificationPermission.destroy_all` — закрывает гонку `Block → Unblock` и полностью изолирует `MuteService`), `AfterBlockDomainFromAccountService` (с нормализацией домена перед `domain_blocking?`) и `DeleteAccountService` (по обеим колонкам `account_id` и `target_account_id`). Старый рекурсивный CTE сохраняется исключительно за аварийным Kill-Switch.
  * *Плюсы:* Закрывает кросс-тредовый спуфинг (без DoS и `Seq Scan` на `conversation_from_uri` благодаря индексу `(conversation_id)`) и DoS через старые треды; гарантирует $O(1)$ проверку за `< 0.2` мс на 100% входящих DM (целевой ориентир).
  * *Минусы и риски:* Требует однократного прохода по локальным аккаунтам при бэкфилле, вторичных индексов `(target_account_id)` и `(conversation_id)` на компактной таблице и сериализации отзыва прав (`pg_advisory_xact_lock(hashtextextended(...))`) во всех точках удаления и блокировки.

#### 4. Принятое решение и обоснование (Decision & Rationale)
* **Выбранный вариант:** Вариант 2.
* **Обоснование:** Единственный вариант, одновременно закрывающий уязвимость кросс-тредового спуфинга (без деградации `ConversationMute` и `Seq Scan`), сохраняющий защиту от DoS из исходного `ADR-3` и обеспечивающий стабильное время проверки `< 0.2` мс без постоянных fallback-вызовов рекурсивного CTE.

#### 5. Последствия (Consequences)
* **Положительные:** Полная ликвидация рекурсивного CTE глубиной до 100 шагов в штатном режиме, переход на `Index Only Scan` за `< 0.2` мс для 100% входящих DM (подлежит верификации в `notification-load-testing`), закрытие спуфинга диалогов и быстрое удаление прав при удалении аккаунта.
* **Отрицательные и риски:** Два дополнительных индекса `(target_account_id)` и `(conversation_id)` на компактной таблице `dm_thread_permissions` и необходимость поддерживать сериализованный отзыв прав во всех точках удаления и блокировки (не мутируя исторические `statuses.conversation_id`, чтобы не сломать `AccountConversation` и `ConversationMute`).
* **Дальнейшие шаги:** Реализовать транзакционную миграцию создания `dm_thread_permissions` с индексами `(target_account_id)` и `(conversation_id)`, сериализацию выдачи/отзыва через `pg_advisory_xact_lock(hashtextextended(...))` и `DELETE ... WHERE NOT EXISTS (...)` в `PostStatusService`, `ProcessMentionsService`, `RemoveStatusService`, `BatchedRemoveStatusService`, `BlockService`, `AfterBlockDomainFromAccountService` и `DeleteAccountService`. Провести Zero-Downtime выкатку (`DDL` → `Dual-Write` → полный бэкфилл → `Shadow Reconciliation` с `mismatch_rate < 0.01%` с исключением ожидаемых расхождений `Block → Unblock`/soft-delete → канареечное включение через атомарные Redis Kill-Switch `dm_thread_permissions:write_enabled` с `last-known-good` при сбое Redis и `dm_thread_permissions:read_rollout_pct` + PG-latch `dirty_since`), подключить мониторинг (`mastodon_dm_permissions_check_total`, `mastodon_dm_permissions_check_duration_seconds`, `reconciliation_checked_total`, `reconciliation_mismatch_total`) и обеспечить план отката (`read_rollout_pct → 0` без потери входящих DM; запрет повторного включения чтения после `write_enabled = false` без полного re-backfill/reconciliation).
