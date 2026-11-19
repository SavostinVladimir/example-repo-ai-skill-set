## Context

В текущей реализации Mastodon три операции с уведомлениями создают непропорционально высокую нагрузку на PostgreSQL:
1. **Пагинация сгруппированных уведомлений (`Notification.paginate_groups` из concern `Notification::Groups` в API v2):** рекурсивный `WITH RECURSIVE` с до 40 итерациями `LATERAL` по умолчанию (до 80 при `limit = 80`) в `#index` и до 100 (максимум до 1 000 при `MAX_NOTIFICATIONS_COUNT_LIMIT`) в `#unread_count`, с проверкой `NOT group_key = ANY(wt.groups)`. На вирусных постах с тысячами однотипных реакций планировщик перебирает тысячи индексных записей на каждый HTTP-запрос.
2. **Сбор агрегатов по группам (`NotificationGroup.load_groups_data`):** разворачивает массив ключей через `unnest` и выполняет по 5 коррелированных подзапросов на каждую группу (4 скалярных, включая `COUNT(*)`, и 1 `array(SELECT ...)` — до 200 подзапросов по умолчанию и до 400 при `limit = 80`).
3. **Проверка цепочки личных сообщений (`NotifyService::BaseCondition#statuses_that_mention_sender`):** рекурсивный CTE по иерархии `in_reply_to_id` глубиной до 100 шагов на критическом пути записи при каждом входящем DM от незнакомца.

По итогам архитектурного ревью (`ADR-1`, `ADR-2`, `ADR-4`) перенос лент, буферов или счётчиков уведомлений в Redis отклонён в пользу чистой ACID-материализации в PostgreSQL.

## Goals / Non-Goals

**Goals:**
- Снизить p95 SQL-латентность целевых запросов чтения групп/агрегатов и `GET /api/v2/notifications/unread_count` со 150–500 мс до 1–5 мс (обеспечивая end-to-end HTTP p95 `<= 25 мс` для `GET /api/v2/notifications` на целевом профиле: активные видимые уведомления в окне материализации при стандартной группировке или опущенном `grouped_types[]`, доля fallback `< 5%` трафика).
- Заменить 100-шаговый рекурсивный CTE `statuses_that_mention_sender` на точечный `Index Only Scan` за `< 0.2` мс для 100% входящих личных сообщений без постоянных рекурсивных fallback-путей.
- Сократить Read CPU и дисковый I/O целевых SQL-запросов на порядок, обеспечив подтверждённый чистый выигрыш по суммарной нагрузке подсистемы уведомлений в PostgreSQL `>= 3x` при бюджете оверхеда на запись `<= +5 мс` p95 в `LocalNotificationWorker` и доле мёртвых кортежей `<= 25%`.
- Сохранить 100% обратную совместимость контрактов API v1/v2 (`types[]`, `exclude_types[]`, `grouped_types[]`, `include_filtered`, `without_suspended`, `page_min_id`, `page_max_id`, `Link`-заголовки) и правил безопасности DM.

**Non-Goals:**
- Изменение форматов ответов REST API v1/v2, Streaming API или клиентских приложений.
- Вынос хранилища, счётчиков или stateful write-behind буферов уведомлений в Redis / NoSQL (в соответствии с `ADR-1` и `ADR-2`).
- Изменение правил 12-часового окна группировки (`MAXIMUM_GROUP_SPAN_HOURS = 12`).

## Decisions

### 1. Таблица `notification_groups` для Write-Time Grouping и агрегатов (Сценарии 1 и 2)

#### 1.1. DDL, индексы и хранение (разделение миграций)
Миграции схемы делятся на транзакционные для новых пустых таблиц (без `CONCURRENTLY`) и отдельную миграцию с `disable_ddl_transaction!` и `algorithm: :concurrently` исключительно для существующей горячей таблицы `notifications`. Таблица `notification_groups` создаётся с составным первичным ключом `(account_id, group_key)` без суррогатного `id` и с опциональной ссылкой `target_status_id` (заполняется только для группируемых реакций `favourite` и `reblog`, и остаётся `NULL` для `follow` и всех `ungrouped-*`) для точного индексного удаления без локалезависимого `LIKE`. В соответствии с `ADR-1` пониженный `fillfactor` (`80`) задаётся на вторичном B-tree индексе `index_notification_groups_pagination`, а сама таблица остаётся со стандартным `fillfactor = 100` (разреживание heap при отключённом `HOT update` не даёт выигрыша и раздувает `shared_buffers` на ~43%). Поскольку Mastodon использует `schema_format = :ruby` (`db/schema.rb` не сохраняет `reloptions`), параметры `autovacuum` (внутри блока `safety_assured` `StrongMigrations`) и `fillfactor` индекса верифицируются через `pg_class.reloptions` / `pg_indexes` и фиксируются в runbook:

```sql
-- Миграция 1 (транзакционная): новая таблица notification_groups и её индексы
CREATE TABLE notification_groups (
  account_id bigint NOT NULL,
  group_key varchar NOT NULL,
  type varchar NOT NULL,
  target_status_id bigint,
  most_recent_notification_id bigint NOT NULL,
  min_notification_id bigint NOT NULL,
  notifications_count bigint NOT NULL DEFAULT 1,
  sample_account_ids bigint[] NOT NULL DEFAULT '{}',
  latest_notification_at timestamp without time zone NOT NULL,
  created_at timestamp without time zone NOT NULL,
  updated_at timestamp without time zone NOT NULL,
  PRIMARY KEY (account_id, group_key)
);

ALTER TABLE notification_groups
  SET (autovacuum_vacuum_scale_factor = 0.01, autovacuum_vacuum_cost_limit = 1000);

CREATE INDEX index_notification_groups_pagination
  ON notification_groups (account_id, most_recent_notification_id DESC, type)
  WITH (fillfactor = 80);

CREATE INDEX index_notification_groups_on_account_target_status
  ON notification_groups (account_id, target_status_id)
  WHERE target_status_id IS NOT NULL;

-- Миграция 2 (disable_ddl_transaction!): конкурентный индекс на существующей таблице notifications
-- Покрывает точечный пересчёт и расчёт граничных page_min_id только для 3 материализуемых группируемых типов
CREATE INDEX CONCURRENTLY index_notifications_on_group_recalculation
  ON notifications (account_id, group_key, id DESC)
  INCLUDE (from_account_id, created_at)
  WHERE group_key IS NOT NULL AND filtered = false AND type IN ('favourite', 'reblog', 'follow');
```

#### 1.2. Контракты ActiveRecord-модели и сериализации
- Модель `NotificationGroupRecord` мапится на таблицу `notification_groups`, использует нативный составной первичный ключ Rails 8.1 (`primary_key = [:account_id, :group_key]`) и отключает STI (`inheritance_column = nil`).
- Метод `id` **не переопределяется**, чтобы не нарушать внутренние механизмы ActiveRecord 8.1 (`reload`, `update`, `destroy`, `==`). Заголовки пагинации `Link` (`pagination_max_id` / `pagination_since_id`) в `Api::V2::NotificationsController` строятся строго по **исходной** выборке `NotificationGroupRecord` (по значению `most_recent_notification_id`) до отбрасывания битых записей в Ruby, чтобы бесконечный скролл никогда не обрывался; если отброшены все строки страницы — контроллер выполняет ограниченный добор следующей страницы (или переход в legacy).
- Чтение `type` приводит строковое значение колонки к `Symbol` для совместимости со строгими Symbol-проверками в `REST::NotificationGroupSerializer`.
- Связь `most_recent_notification` объявляется с `optional: true`, а в `Account::Associations` добавляется `has_many :notification_group_records` (`dependent: :delete_all`).
- В `NotificationGroup`: делегирование к `notification` настраивается с `allow_nil: true`; при загрузке `accounts_map` всегда применяется скоуп `Account.without_suspended` (0 дополнительных SQL-запросов, мгновенная защита во время фоновой очистки), а `sample_accounts` очищаются от `nil` до создания `NotificationGroup`. В `GroupedNotificationsPresenter` извлечение первого и остальных авторов (`partial_avatars`) защищается от пустых массивов и `nil`. Осиротевшие группы с отсутствующим `notification` или пустым `sample_accounts` **всегда исключаются до сериализации** (без синхронной записи и без inline-восстановления внутри `with_read_replica`), а `RecomputeNotificationGroupWorker` ставится в очередь строго после выхода из блока `with_read_replica` (если `updated_at < 60.seconds.ago`).

#### 1.3. Канонический ключ, транзакционный идемпотентный `UPSERT`, `LocalNotificationWorker` и `UnfilterNotificationsWorker`
- **Единый канонический ключ хранения:** Вводится константа `MATERIALIZED_GROUPED_TYPES = %i(favourite reblog follow)` и единая функция маппинга `NotificationGroupRecord.storage_group_key(notification)` (SQL-эквивалент: `CASE WHEN type IN ('favourite', 'reblog', 'follow') AND group_key IS NOT NULL THEN group_key ELSE 'ungrouped-' || id END`). Она используется **во всех** точках: `UPSERT`, `UnfilterNotificationsWorker`, `#dismiss`, `RecomputeNotificationGroupWorker`, `RemoveStatusService` / `BatchedRemoveStatusService`, переходах `without_suspended` и бэкфилле. Все остальные типы — включая `admin.sign_up` — материализуются как одиночные строки `ungrouped-<notification_id>` (при этом колонка `notifications.group_key` остаётся без изменений).
- **Транзакционность Write Path и сериализация `LocalNotificationWorker`:** Запись в `notifications` и `UPSERT` в `notification_groups` выполняются **в одной транзакции PostgreSQL**. Поскольку в `db/schema.rb` на `notifications` нет `UNIQUE`-индекса по `(account_id, activity_id, activity_type, type)`, в `LocalNotificationWorker` (вызывающем `NotifyService`) проверка дубликатов и вставка оборачиваются в транзакцию с `pg_advisory_xact_lock(hashtextextended('local_notif:' || receiver_id || ':' || activity_type || ':' || activity_id || ':' || type, 0))` — это полностью исключает двойной учёт `notifications_count` при конкурентных повторах Sidekiq.
- **`UnfilterNotificationsWorker` (выход из карантина):**
  1. Батч предзагружает полиморфные `activity` (`:favourite`, `:status`, `:follow`) во избежание N+1 и вычисляет timestamp с fallback `activity&.created_at || created_at` (защита от удалённых `activity`).
  2. Проверка **двустороннего 12-часового окна бакета:** существующий `previous_bucket` из Redis `notif-group/<account_id>/<type_prefix>` переиспользуется только если `previous_bucket <= hour_bucket && hour_bucket < previous_bucket + MAXIMUM_GROUP_SPAN_HOURS`; при разблокировке старых уведомлений (`hour_bucket < previous_bucket` или после истёкшего окна) используется детерминированный `hour_bucket` самого уведомления без перезаписи актуального Redis-бакета старой датой.
  3. Переход из карантина выполняется атомарно одним запросом с разнородными ключами `UPDATE notifications AS n SET filtered = false, group_key = v.group_key FROM (VALUES ...) AS v(id, group_key) WHERE n.id = v.id AND n.filtered = true RETURNING ...` в **одной транзакции** с многострочным `UPSERT` в `notification_groups` (при ретрае Sidekiq `WHERE filtered = true` вернёт 0 строк — строгая идемпотентность).
  4. Для записей, где `@from_account.unavailable?` или `notification.id <= backfill_cutoff_id`, `UPSERT` в `notification_groups` не выполняется (обновляется только `notifications.filtered = false`).
- **Детерминированный многострочный `UPSERT`:** Батч в `UnfilterNotificationsWorker` агрегируется по `(account_id, group_key)` (с раздельными `most_recent_notification_id`, `min_notification_id`, `notifications_count` и дедуплицированным массивом `sample_account_ids` длиной до 8) и сортируется по `[account_id, group_key]` для исключения `PG::DeadlockDetected` и `PG::CardinalityViolation`. В SQL-выражении `COALESCE(..., '{}')` защищает `sample_account_ids NOT NULL` на пустом массиве:

```sql
INSERT INTO notification_groups (
  account_id, group_key, type, target_status_id,
  most_recent_notification_id, min_notification_id,
  notifications_count, sample_account_ids, latest_notification_at,
  created_at, updated_at
) VALUES (...)
ON CONFLICT (account_id, group_key) DO UPDATE SET
  most_recent_notification_id = GREATEST(notification_groups.most_recent_notification_id, EXCLUDED.most_recent_notification_id),
  min_notification_id = LEAST(notification_groups.min_notification_id, EXCLUDED.min_notification_id),
  latest_notification_at = GREATEST(notification_groups.latest_notification_at, EXCLUDED.latest_notification_at),
  notifications_count = notification_groups.notifications_count + EXCLUDED.notifications_count,
  sample_account_ids = COALESCE((
    SELECT array_agg(aid ORDER BY first_ord)
    FROM (
      SELECT aid, MIN(ord) AS first_ord
      FROM unnest(
        CASE
          WHEN EXCLUDED.most_recent_notification_id >= notification_groups.most_recent_notification_id
            THEN EXCLUDED.sample_account_ids || notification_groups.sample_account_ids
          ELSE notification_groups.sample_account_ids || EXCLUDED.sample_account_ids
        END
      ) WITH ORDINALITY AS t(aid, ord)
      GROUP BY aid
      ORDER BY first_ord
      LIMIT 8
    ) deduped
  ), '{}'::bigint[]),
  updated_at = NOW();
```

- **Маршрутизация `grouped_types[]` (Web UI, мобильные клиенты и `unread_count`):**
  - Запросы с набором Web-клиента `['favourite', 'reblog', 'follow']` обслуживаются **одним** плоским запросом к `notification_groups` (для обычных пользователей, действующих и бывших модераторов — без проверок ролей и без многоисточникового слияния).
  - Дефолтные запросы с опущенным параметром `grouped_types[]` (`nil` — мобильные/сторонние клиенты и ~100% трафика `#unread_count`) или с полным 4-элементным набором `GROUPABLE_NOTIFICATION_TYPES` **также** обслуживаются быстрым путём из `notification_groups`: контроллер уходит в legacy fallback **только если** в выборке реально присутствует `type = 'admin.sign_up'` (в `#index` — проверка наличия среди строк страницы; в `#unread_count` — одним индексным запросом `SELECT COUNT(*), BOOL_OR(type = 'admin.sign_up') FROM (SELECT type FROM notification_groups ... LIMIT $limit) t`). Для 99.9% пользователей (не модераторов) и при исключении `admin.sign_up` фильтрами запрос остаётся в fast-path (1–5 мс SQL).
  - Запросы с иным кастомным `grouped_types[]` (отключающим `favourite`/`reblog`/`follow`, напр. `['favourite', 'reblog']`) или с `include_filtered = true` направляются в legacy-путь `Notification.paginate_groups` + `load_groups_data`.

#### 1.4. Пагинация, точный `page_min_id`, `#show` и граница горизонта (`backfill_cutoff_id`)
- **Направление сортировки:** `ORDER BY most_recent_notification_id DESC LIMIT N` для первой страницы, `max_id` и `since_id`; `ORDER BY most_recent_notification_id ASC LIMIT N` с разворотом результата для `min_id`.
- **Точный расчёт `page_min_id` и `page_max_id` (единообразно для полных и неполных страниц):**
  - При пагинации вниз (`max_id` / без курсора): `pagination_range.begin` на полной странице равен `last_group.most_recent_notification_id`, а на неполной — `(params[:since_id].to_i + 1)` при наличии `since_id` (иначе `nil`).
  - При пагинации вверх (`paginating_up?` с `params[:min_id]`): нижняя граница `pagination_range.begin` **всегда** равна `params[:min_id].to_i + 1` (как на неполной `(min_id + 1)...max_id`, так и на полной странице, т.к. `notification_groups` хранит `most_recent_notification_id`, а не старейший ID группы > `min_id`). Это гарантирует прохождение контрактов API v2 (включая кейс неполной страницы из `notifications_spec`).
  - Для каждой группы `page_max_id = group.most_recent_notification_id`.
  - Если `pagination_range.begin.nil?` или `group.min_notification_id >= pagination_range.begin`, отдаётся `page_min_id = group.min_notification_id` без дополнительных запросов (95%+ групп).
  - Для граничных групп (обычно 0–2 на страницу), чьё окно `[min_notification_id, most_recent_notification_id]` пересекает `pagination_range.begin`, выполняется **один батчевый** `Index Only Scan` по `index_notifications_on_group_recalculation` (с обязательным `AND n.filtered = false AND n.type IN ('favourite', 'reblog', 'follow')` для попадания в частичный предикат индекса) и `COALESCE` на `most_recent_notification_id`:
    ```sql
    SELECT g.group_key, (
      SELECT n.id FROM notifications n
      WHERE n.account_id = $1 AND n.group_key = g.group_key
        AND n.filtered = false AND n.type IN ('favourite', 'reblog', 'follow')
        AND n.id >= $3
      ORDER BY n.id ASC LIMIT 1
    ) AS page_min_id
    FROM unnest($2::text[]) AS g(group_key);
    ```
- **Детальный просмотр группы (`#show`):** `Api::V2::NotificationsController#show` также переводится на чтение агрегатов из `notification_groups` через `storage_group_key` (с fallback в `load_groups_data` при отсутствии строки) и не формирует метаданные пагинации (`pagination_data = nil`).
- **Сквозная пагинация и `unread_count` на границе `backfill_cutoff_id`:**
  - Watermark `backfill_cutoff_id` хранится персистентно в PostgreSQL (`Setting` с локальным 5-секундным кэшем). При `nil` (до завершения первичного бэкфилла или при ошибке чтения) контроллер действует fail-safe — уходит в legacy-путь (никогда не трактует `nil` как `0`).
  - Все выборки из `notification_groups` (`#index` и `#unread_count`) включают фильтр `AND most_recent_notification_id > :backfill_cutoff_id`.
  - При `max_id <= backfill_cutoff_id` или `min_id < backfill_cutoff_id` запрос сразу обслуживается через legacy `Notification.paginate_groups` (исключая пропуск истории при скролле вверх).
  - При скролле вниз из области выше `backfill_cutoff_id`, если выборка из `notification_groups` вернула меньше `limit` строк **и** `(since_id.blank? || since_id.to_i < backfill_cutoff_id)`, контроллер выполняет индексный `EXISTS` по `notifications` с **учётом активных `types[]` / `exclude_types[]` и `filtered = false` для `id <= backfill_cutoff_id`**: при `false` страница завершена без вызова legacy CTE (защита от деградации редких вкладок и малоактивных аккаунтов); при `true` остаток добирается через `Notification.paginate_groups` с параметром `exclude_group_keys`.
  - В `Notification::Groups#paginate_groups(..., exclude_group_keys: [])`: фильтр `WHERE NOT (#{group_key_sql} = ANY(:exclude_group_keys))` добавляется в базовый шаг CTE, `groups` инициализируется как `:exclude_group_keys || ARRAY[#{group_key_sql}]`, а условие остановки рекурсии проверяется как `array_length(grouped_notifications.groups, 1) < :limit + :exclude_count`.
  - В `#unread_count`: при `last_read_id == nil` считаются все группы до `limit`; если `(last_read_id.nil? || last_read_id < backfill_cutoff_id)` и число групп в `notification_groups` меньше `limit`, выполняется проверка/fallback к legacy-подсчёту (с учётом фильтров типов).

### 2. Консистентность при скрытии, одиночных удалениях, массовых очистках и модерации

1. **Скрытие группы (`Api::V2::NotificationsController#dismiss`):**
   - Для `ungrouped-<id>`: по удаляемому уведомлению определяется, относится ли его тип к `MATERIALIZED_GROUPED_TYPES` с непустым `group_key`. Если да (пользователь отключил группировку этого типа) — удаляется одиночное уведомление и ставится пересчёт строки `notification.group_key` в `notification_groups`; иначе (включая `admin.sign_up`) — удаляется уведомление и строка `ungrouped-<id>` в `notification_groups`.
   - Для `admin.sign_up-<bucket>` (если сторонний клиент скрыл сгруппированную регистрацию): удаляются уведомления `by_group_key` и все соответствующие строки `'ungrouped-' || id` в `notification_groups` (оценка размера `> 100` выполняется через `LIMIT 101`).
   - Для малых групп (`notifications_count <= 100`, `ungrouped-*`, `filtered = true`, с проверкой `by_group_key(key).limit(101).count <= 100` если строки нет в `notification_groups`): удаление строки `notification_groups`, удаление уведомлений (`delete_all` в контексте `NotificationGroupRecord.without_recompute`) и обновление `NotificationRequest#reconsider_existence!` выполняются синхронно.
   - Для крупных групп (`> 100`):
     1. В Redis для пары `(account_id, type_prefix)` инкрементируется монотонный счётчик поколения бакета `notif-group-gen/<account_id>/<type_prefix>` (TTL >= 12 часов), который включается в суффикс `set_group_key!` (`#{type_prefix}-#{hour_bucket}-#{gen}` при `gen > 0`) — это гарантирует **новый** `group_key` для новых реакций даже в пределах того же UTC-часа.
     2. Атомарным запросом `DELETE FROM notification_groups WHERE account_id = $1 AND group_key = $2 RETURNING most_recent_notification_id` фиксируется `cutoff_id` (исключая TOCTOU-гонку чтения/удаления), и если строка отсутствовала (группа `< backfill_cutoff_id`) — берётся `maximum(:id)`.
     3. Ставится `DismissNotificationGroupWorker(account_id, group_key, cutoff_id)`, который удаляет строго `by_group_key(group_key).where(id: ..cutoff_id)` батчами, пересчитывает `NotificationRequest#reconsider_existence!` для затронутых отфильтрованных отправителей и в конце проверяет наличие выживших видимых уведомлений `id > cutoff_id` с тем же `group_key` (при наличии ставя `RecomputeNotificationGroupWorker`).
2. **Одиночное удаление уведомлений (`Notification#after_destroy` / `after_destroy_commit`):**
   - Обслуживает `UnfavouriteService`, `UnfollowService`, `RejectFollowService`, `ActivityPub::Activity::Undo`, одиночный unreblog и `Api::V1::NotificationsController#dismiss`.
   - В `NotificationGroupRecord` вводится контекст подавления `without_recompute { ... }` на `ActiveSupport::CurrentAttributes` с гарантированным сбросом в `ensure`.
   - Коллбэк пропускает обработку, если `!groups_write_enabled?`, уведомление в карантине (`filtered?`) или активно `without_recompute`.
   - Для одиночных (`!MATERIALIZED_GROUPED_TYPES.include?(type) || group_key.nil?`, включая `admin.sign_up`): в `after_destroy` выполняется точечный `DELETE` по PK `(account_id, 'ungrouped-' || id)`.
   - Для группируемых (`favourite`, `reblog`, `follow` с `group_key.present?`): в `after_destroy_commit` ставится `RecomputeNotificationGroupWorker` (оптимизация: пересчёт нужен, даже если удалён старейший элемент вне топ-8, чтобы сдвинуть `min_notification_id`, `notifications_count`, `most_recent_notification_id` или `sample_account_ids`).
3. **Удаление статусов (`RemoveStatusService` и `BatchedRemoveStatusService`):**
   - В `RemoveStatusService`: при удалении оригинального статуса (`!reblog?`) — как безвозвратном (`permanently?`), так и мягком (`discard_with_reblogs`) — каскадный `remove_reblogs` (с передачей `original_removed: true`) и удаление статуса оборачиваются в `NotificationGroupRecord.without_recompute`. Поскольку при мягком удалении оригинала репосты физически уничтожаются через `reblog.destroy!`, пакетное удаление `:reblog`-групп (`WHERE account_id = <status.account_id> AND target_status_id = <status.id> AND type = 'reblog'`) выполняется при **обоих** режимах, а удаление `:favourite`-групп (`type = 'favourite'`) — при `permanently?`. При отмене одиночного репоста (`reblog? && !original_removed`) пересчёт **не подавляется**.
   - Для чужих одиночных уведомлений (`mention`, `poll`, `quote`, `status`, `update`, `quoted_update`), каскадно удаляемых при уничтожении статуса: строго **до** `@status.destroy!` и `Status.unscoped.delete_all` (в `RemoveStatusService` и `BatchedRemoveStatusService`) по индексу `notifications(activity_id, activity_type)` выбираются затронутые `(account_id, storage_group_key)` для полиморфных объектов этого статуса (`Status`, `Mention`, `Poll`, `Quote`) и пакетно удаляются из `notification_groups`.
4. **Очистка ленты и замена уведомлений (`#clear` и `LocalNotificationWorker`):**
   - `Api::V1::NotificationsController#clear` (вызывается Web UI) и `Api::V2::NotificationsController#clear` в **одной транзакции** удаляют `notifications` и `notification_group_records` аккаунта.
   - `LocalNotificationWorker` при замене типов `update`, `quoted_update`, `collection_update` в **одной транзакции** выполняет `DELETE FROM notifications WHERE ... RETURNING id` и удаляет соответствующие `'ungrouped-' || id` из `notification_groups` со скоупом `account_id`.
5. **Фоновое восстановление (`RecomputeNotificationGroupWorker`):**
   - Настраивается валидными опциями `sidekiq-unique-jobs`: дедупликация во время ожидания и выполнения с перепланировкой при серверном конфликте (`lock: :until_and_while_executing, on_conflict: { client: :log, server: :reschedule }, lock_ttl: 5.minutes.to_i`).
   - Пересчёт не держит длинный `FOR UPDATE` поверх 50k `JOIN accounts`: (1) вне блокировки вычисляются актуальные агрегаты (`COUNT(*)`, `MIN/MAX(id)`, top-8 `sample_account_ids` с `INNER JOIN accounts` по `Account.without_suspended` и условием `id > backfill_cutoff_id`, а для `ungrouped-<id>` — по PK `notifications.id`); (2) в короткой транзакции берётся `FOR UPDATE` строки `notification_groups` и перепроверяется текущий `MAX(id)` по покрывающему индексу `index_notifications_on_group_recalculation` (`< 0.1` мс): если за время расчёта пришло более новое уведомление — воркер перепланирует короткий повторный пересчёт (`perform_in(1.second, ...)`), не допуская Lost Update и не блокируя горячую строку. При 0 активных видимых уведомлений строка удаляется; если строки не было — выполняется `INSERT ... ON CONFLICT DO NOTHING` с однократным повтором при конкурентной вставке.
6. **Синхронизация жизненного цикла аккаунтов и блокировок доменов (`without_suspended`):**
   - В `DeleteAccountService::ASSOCIATIONS_ON_PURGE` и `ASSOCIATIONS_WITHOUT_SIDE_EFFECTS` добавляется `'notification_group_records'` (покрывает удаление собственных данных при дефолтном `reserve_username: true`).
   - Из синхронных методов `Account::Suspensions#suspend!`, `unsuspend!` и `Account#mark_deleted!` в Puma не выполняется синхронный сбор ключей — ставится **одна** фоновая задача `SyncAccountNotificationGroupsWorker.perform_async(id)` (очередь `pull`), которая батчами читает `notifications` (`from_account_id: id, filtered: false, id > backfill_cutoff_id`), мапит через `storage_group_key` и ставит `RecomputeNotificationGroupWorker`.
   - Тот же батчевый координатор в очереди `pull` (с распределением батчей во времени без несуществующего `sidekiq-throttled`) используется для `BlockDomainService#suspend_accounts!`, `BlockDomainService#process_retroactive_updates!`, `UnblockDomainService#process_retroactive_updates`, `UnallowDomainService#suspend_accounts!`, `DeleteAccountService#purge_generated_notifications!` (`DELETE ... RETURNING`) и `Scheduler::SelfDestructScheduler`.

### 3. Таблица `dm_thread_permissions` (Сценарий 3, `ADR-4`)

#### 3.1. DDL и индексы (транзакционная миграция новой пустой таблицы)
```sql
CREATE TABLE dm_thread_permissions (
  account_id bigint NOT NULL,
  target_account_id bigint NOT NULL,
  conversation_id bigint NOT NULL,
  created_at timestamp without time zone NOT NULL,
  PRIMARY KEY (account_id, target_account_id, conversation_id)
);

-- Индекс для быстрой очистки прав удаляемого собеседника в DeleteAccountService
CREATE INDEX index_dm_thread_permissions_on_target_account_id
  ON dm_thread_permissions (target_account_id);

-- Индекс для проверки входящих корневых DM в ActivityPub::Activity::Create#conversation_from_uri без Seq Scan
CREATE INDEX index_dm_thread_permissions_on_conversation_id
  ON dm_thread_permissions (conversation_id);
```

#### 3.2. Жизненный цикл, федерация и безопасность
- **Транзакционная выдача прав:** Вставка `INSERT ... ON CONFLICT DO NOTHING` выполняется внутри **той же** транзакции `ApplicationRecord.transaction`, что и сохранение статуса в `PostStatusService` (после присвоения `conversation_id`, до коммита и до постановки воркеров рассылки), а также внутри `Status.transaction` в `ProcessMentionsService#assign_mentions!` (после `scan_text!` HTTP-вызовов и при сохранении статуса, что покрывает добавление/реактивацию не-тихих упоминаний при редактировании `direct`-статусов из `UpdateStatusService`).
- **Проверка строго по родительскому треду (без DoS-fallback и без потери мягко удалённого родителя):**
  - В `NotifyService::BaseCondition#response_to_recipient?` проверяется `target_status.in_reply_to_id.present?`. Родительский `conversation_id` читается через `Status.unscoped` (`Status.unscoped.where(id: target_status.in_reply_to_id).pick(:conversation_id)`), чтобы мягкое удаление (`deleted_at IS NOT NULL`, скрываемое `Status.default_scope`) промежуточного статуса в живой цепочке не вызывало ложный отказ в сравнении с legacy CTE.
  - Выполняется `Index Only Scan` в `dm_thread_permissions` **строго** по `(account_id: recipient_id, target_account_id: sender_id, conversation_id: parent_conversation_id)` (без OR-массива).
  - Постоянный 90-дневный рекурсивный fallback **не используется** — таблица наполняется полным историческим бэкфиллом всех исходящих `direct`-статусов локальных аккаунтов (по `Account.local` через индекс `index_statuses_20190820`), закрывая DoS-вектор через старые треды.
- **Федерация и анти-спуфинг без поломки `ConversationMute`:**
  - Дочерние ответы (`thread.present?`) безусловно наследуют `conversation_id` родителя (игнорируя внешний URI `conversation` у реплаев).
  - В `ActivityPub::Activity::Create#conversation_from_uri` входящим статусам с `in_reply_to_id: nil` запрещается привязываться к уже существующему в БД `Conversation` **только если** входящий статус имеет `visibility == :direct` (или проверяемый `Conversation` уже содержит записи в `dm_thread_permissions`, что мгновенно проверяется по `index_dm_thread_permissions_on_conversation_id`). Локальные не-DM ветки при потере промежуточного поста сохраняют `ConversationMute` без регрессий.
  - В `ThreadResolveWorker`:
    1. Сетевая догрузка `FetchRemoteStatusService` выполняется **до** взятия `with_redis_lock`. Блок обновления БД защищается `with_redis_lock("distribute:#{child_status_id}")` (при `Mastodon::RaceConditionError` — явный `perform_in(5.seconds, ...)` без сжигания `retry: 3`).
    2. Оценка и создание/разблокировка DM-уведомления для каждого получателя сериализуется с `LocalNotificationWorker` общим транзакционным локом `pg_advisory_xact_lock(hashtextextended('dm_notify:' || recipient_id || ':' || mention_id, 0))` с перечитыванием актуального `Status` с Primary.
    3. При смене `conversation_id` (с сохранением `old_conversation_id` до обновления): каскадно (через рекурсивный CTE с `NOT id = ANY(path)` и лимитом глубины `<= 100`) обновляются уже пришедшие потомки, переносится `AccountConversation` (удаление со старого `conversation_id` до записи в новый) и мигрируются записи `dm_thread_permissions` / `ConversationMute` локальных direct-потомков с `old_conversation_id` на новый `conversation_id`.
    4. Для существующих `filtered = true` уведомлений (включая потомков) обязательно повторно вычисляются полные `NotifyService::DropCondition` (если `true` — удаление уведомления и пересчёт `NotificationRequest`) и `NotifyService::FilterCondition` (разблокировка в `filtered = false` с полным конвейером уведомлений — `upsert`, `NotificationRequest`, `AccountConversation`, стриминг, WebPush, email — выполняется **только** при `drop? == false && filter? == false`).
    5. При отсутствии уведомления повторная доставка запускается **только** если `child_status.direct_visibility? && child_status.within_realtime_window?`, у получателя активен `drop_private_mentions?` и с учётом `DropCondition`/`FilterCondition`.
- **Конкурентно-безопасный отзыв прав (64-битные ключи и синхронный `BlockService`):**
  - Выдача и отзыв по `(account_id, conversation_id)` сериализуются внутри DB-транзакции 64-битным ключом `pg_advisory_xact_lock(hashtextextended('dm_perm:' || account_id || ':' || conversation_id, 0))` (после всех сетевых вызовов), а удаление выполняется через `DELETE ... WHERE NOT EXISTS (SELECT 1 FROM statuses ...)`. В `BatchedRemoveStatusService` пары `(account_id, conversation_id)` детерминированно сортируются перед захватом локов во избежание AB-BA дедлоков.
  - Отзыв при блокировке аккаунта переносится в **синхронный** `BlockService#call` (рядом с `NotificationPermission.destroy_all`), что полностью устраняет гонку `Block → Unblock` и изолирует `MuteService`.
  - В `AfterBlockDomainFromAccountService` домен предварительно нормализуется через `TagManager.instance.normalize_domain(@domain)` перед проверкой `domain_blocking?`.
  - В `DeleteAccountService` права удаляются по обеим колонкам (`account_id` и `target_account_id`).

### 4. Политика роста данных (Retention & Pruning)
- Плановая еженедельная задача (зарегистрирована в `config/sidekiq.yml`) поддерживает окно хранения (по умолчанию 90 дней) через 2-фазный безопасный сдвиг: (1) монотонно поднимает `backfill_cutoff_id` в PostgreSQL; (2) выжидает паузу `> max(cache_ttl, max_replica_lag)` (30 с); (3) удаляет устаревшие записи батчами по `Account.local` (`WHERE account_id IN (...) AND most_recent_notification_id <= $new_cutoff`), задействуя `index_notification_groups_pagination` без Full Seq Scan.
- Записи `dm_thread_permissions` очищаются при удалении аккаунтов, блокировках и удалении исходных `direct`-статусов.

## Risks / Trade-offs

- **[Risk] Срыв HOT-update и B-tree bloat в `notification_groups` на вирусных постах** → **Mitigation:** Осознанный компромисс (`ADR-1`): обновление `most_recent_notification_id` отключает HOT-update при in-order вставках. Митигируется агрессивным `autovacuum` на таблице (`scale_factor = 0.01`, `cost_limit = 1000`), стандартным heap (`fillfactor = 100`), пониженным `fillfactor = 80` на индексе `index_notification_groups_pagination` и регламентным `pg_repack`.
- **[Risk] Write Amplification на горячей таблице `notifications` от индекса `index_notifications_on_group_recalculation`** → **Mitigation:** Индекс строго частичный (`WHERE group_key IS NOT NULL AND filtered = false AND type IN ('favourite', 'reblog', 'follow')`), не индексирует `admin.sign_up`, `mention`, `status`, `update`, `poll` и карантин; в задаче бенчмаркинга замеряются оверхед `INSERT`, WAL, bloat и оценивается возможность отказа от дублирующего по префиксу `index_notifications_on_account_id_and_group_key`.
- **[Risk] Пересечение Dual-Write и бэкфилла `notification_groups` (двойной учёт)** → **Mitigation:** На этапе бэкфилла для граничных групп на стыке времени старта Dual-Write используется тот же безопасный паттерн пересчёта с проверкой `MAX(id)` под коротким `FOR UPDATE`, исключающий перезатирание свежих реакций.

## Rollout Plan (Поэтапная Zero-Downtime выкатка)

Управление выкаткой строится на **атомарном документе конфигурации контура в Redis** (`{ write_enabled, read_rollout_pct }`) с 5-секундным локальным in-memory кэшем и персистентным latch `dirty_since` + `backfill_cutoff_id` в PostgreSQL (`Setting`):
- **Политика деградации при сбое/рестарте Redis:** `read_rollout_pct` безопасно сбрасывается в `0` (fail-closed в legacy), а `write_enabled` удерживает последнее валидное значение (`last-known-good`; при холодном старте без Redis — дефолт из ENV этапа релиза), инкрементируя метрику `mastodon_notification_optimizations_redis_flag_fallback_total`. В коде действует жёсткий программный инвариант: чтение материализованных таблиц **не активируется**, если `write_enabled == false` или выставлен `dirty_since` в PostgreSQL.
- Раздельные контуры: `notification_groups` и `dm_thread_permissions` (канарейка по `account_id % 100`).

**Фазы выкатки:**
1. **DDL (Zero-Downtime):** Применение 3 раздельных миграций (`read_rollout_pct = 0`, `write_enabled = false`).
2. **Dual-Write:** Деплой кода на все ноды → включение `write_enabled = true`.
3. **Идемпотентный Backfill:**
   - Полный исторический бэкфилл `dm_thread_permissions` с итерацией по `Account.local` (через `index_statuses_20190820`) и сбором всех `conversation_id` поддерева потомков (без мутации исторических `statuses.conversation_id`, при отзыве удаляя права для всех `conversation_id` статуса и потомков).
   - Бэкфилл `notification_groups` за 90 дней с фиксацией watermark `backfill_cutoff_id` в PostgreSQL и безопасным пересчётом пограничных 12-часовых групп.
4. **Shadow Reconciliation:** Периодическая сверка выборки аккаунтов до достижения `mismatch_rate < 0.01%` (ожидаемые расхождения `Block → Unblock` и soft-delete для DM отфильтровываются в логике сверки и не считаются ошибками).
5. **Canary Read Ramp:** Пошаговое увеличение `read_rollout_pct`: `1% → 10% → 50% → 100%`.

## Rollback Plan (План отката)

1. **Обратимый откат чтения (без потери данных):** Снижение `read_rollout_pct → 0` (вступает в силу `<= 5 с`). Пока `write_enabled = true`, данные остаются консистентными.
2. **Экстренное отключение записи:** Установка `write_enabled = false` автоматически фиксирует персистентный `dirty_since` в PostgreSQL и блокирует чтение. Сброс `dirty_since` и повторное включение `read_rollout_pct > 0` возможны **только** после полного re-backfill и reconciliation активного окна (включая удаление лишних/удалённых строк и отозванных DM-разрешений).
3. **Удаление схемы (пост-деинсталляция):** `DROP TABLE` выполняется только после выкатки релиза без обращений к таблицам и полного дренирования очередей `RecomputeNotificationGroupWorker`, `DismissNotificationGroupWorker` и `SyncAccountNotificationGroupsWorker`.

## Observability & Metrics (Prometheus `prometheus_exporter` + OpenTelemetry)

- **Сценарии 1–2 (`notification_groups`):**
  - `mastodon_notification_groups_read_duration_seconds{path="precomputed|legacy"}` (SQL-блок выборки/агрегации; полная HTTP-латентность контролируется через стандартные метрики Puma/Rails).
  - `mastodon_notification_groups_fallback_total{reason="custom_types|filtered|backfill_boundary|missing_record|admin_sign_up"}`.
  - `mastodon_notification_groups_upsert_duration_seconds`, `mastodon_notification_groups_recompute_enqueued_total`, глубина очереди `RecomputeNotificationGroupWorker`.
  - `mastodon_notification_groups_dismiss_worker_duration_seconds` и счётчик ошибок `DismissNotificationGroupWorker`.
- **Сценарий 3 (`dm_thread_permissions`):**
  - `mastodon_dm_permissions_check_total{result="hit|miss|kill_switch"}` и `mastodon_dm_permissions_check_duration_seconds`.
- **Reconciliation, рубильники и триггеры отката (SLI/SLO):**
  - `mastodon_notification_optimizations_reconciliation_checked_total{component="groups|dm_permissions"}` (знаменатель для `mismatch_rate`).
  - `mastodon_notification_optimizations_reconciliation_mismatch_total{component="groups|dm_permissions", kind="false_negative|false_positive|count_drift|samples_drift"}`.
  - `mastodon_notification_optimizations_redis_flag_fallback_total{component="groups|dm_permissions"}`.
  - **Триггеры обязательного отката (`read_rollout_pct → 0`):** всплеск 5xx на `/api/v2/notifications > 0.1%`, HTTP p95 `#index > 50 мс` или SQL p95 `> 10 мс`, `dm_permissions` истинный `false_negative` (вне `Block → Unblock`/soft-delete) `> 0`, очередь `RecomputeNotificationGroupWorker > 10 000` или p95 `upsert_duration > 100 мс`.
