## Context

В текущей реализации Mastodon три операции с уведомлениями создают критическую нагрузку на PostgreSQL:
1. **Пагинация сгруппированных уведомлений (`Notification::Groups.paginate_groups` в API v2):** рекурсивный `WITH RECURSIVE` с до 40 итерациями `LATERAL` и проверкой `NOT group_key = ANY(wt.groups)`. На вирусных постах с тысячами однотипных реакций планировщик перебирает тысячи индексных записей на каждый HTTP-запрос.
2. **Сбор агрегатов по группам (`NotificationGroup.load_groups_data`):** разворачивает массив из 40 ключей через `unnest` и выполняет по 5 коррелированных подзапросов на каждую группу (до 200 подзапросов + полный `COUNT(*)`).
3. **Проверка цепочки личных сообщений (`NotifyService::BaseCondition#statuses_that_mention_sender`):** рекурсивный CTE по иерархии `in_reply_to_id` глубиной до 100 шагов на критическом пути записи при каждом входящем DM от незнакомца.

По итогам архитектурного ревью (`ADR-1`, `ADR-2`, `ADR-4`) перенос лент, буферов или счётчиков уведомлений в Redis отклонён в пользу чистой ACID-материализации в PostgreSQL.

## Goals / Non-Goals

**Goals:**
- Снизить p95-латентность чтения `GET /api/v2/notifications` и `GET /api/v2/notifications/unread_count` со 150–500 мс до 1–5 мс для целевого профиля запросов (активные видимые уведомления в окне материализации при стандартной группировке Web-клиента, доля fallback `< 5%` трафика).
- Заменить 100-шаговый рекурсивный CTE `statuses_that_mention_sender` на точечный `Index Only Scan` за `< 0.2` мс для 100% входящих личных сообщений без постоянных рекурсивных fallback-путей.
- Сократить Read CPU и дисковый I/O PostgreSQL на порядок, обеспечив подтверждённый чистый выигрыш по суммарной нагрузке с учётом Write Amplification.
- Сохранить 100% обратную совместимость контрактов API v1/v2 (`types[]`, `exclude_types[]`, `grouped_types[]`, `include_filtered`, `without_suspended`, `page_min_id`, `page_max_id`, `Link`-заголовки) и правил безопасности DM.

**Non-Goals:**
- Изменение форматов ответов REST API v1/v2, Streaming API или клиентских приложений.
- Вынос хранилища, счётчиков или stateful write-behind буферов уведомлений в Redis / NoSQL (в соответствии с `ADR-1` и `ADR-2`).
- Изменение правил 12-часового окна группировки (`MAXIMUM_GROUP_SPAN_HOURS = 12`).

## Decisions

### 1. Таблица `notification_groups` для Write-Time Grouping и агрегатов (Сценарии 1 и 2)

#### 1.1. DDL, индексы и хранение
Таблица создаётся без суррогатного `id`, с составным первичным ключом `(account_id, group_key)` и опциональной ссылкой `target_status_id` для точного пакетного удаления реакций без префиксного `LIKE` (исключая зависимость от локали / `varchar_pattern_ops`). DDL и параметры хранения оборачиваются в `safety_assured` (`StrongMigrations`), а индексы на существующих таблицах создаются с `disable_ddl_transaction!` и `algorithm: :concurrently`:

```sql
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
  SET (fillfactor = 70, autovacuum_vacuum_scale_factor = 0.01, autovacuum_vacuum_cost_limit = 1000);

CREATE INDEX CONCURRENTLY index_notification_groups_pagination
  ON notification_groups (account_id, most_recent_notification_id DESC, type);

CREATE INDEX CONCURRENTLY index_notification_groups_on_account_target_status
  ON notification_groups (account_id, target_status_id)
  WHERE target_status_id IS NOT NULL;

-- Покрывающий частичный индекс для точечного пересчёта групп и расчёта граничных page_min_id
CREATE INDEX CONCURRENTLY index_notifications_on_group_recalculation
  ON notifications (account_id, group_key, id DESC)
  INCLUDE (from_account_id, created_at)
  WHERE group_key IS NOT NULL AND filtered = false;
```

#### 1.2. Контракты ActiveRecord-модели и сериализации
- Модель `NotificationGroupRecord` мапится на таблицу `notification_groups`, использует нативный составной первичный ключ Rails 8.1 `[:account_id, :group_key]` и отключает STI (`inheritance_column = nil`).
- Метод `id` **не переопределяется**, чтобы не нарушать внутренние механизмы ActiveRecord 8.1 (`reload`, `update`, `destroy`, `==`). Для заголовков `Link` в `Api::V2::NotificationsController` коллекцией пагинации остаются загруженные объекты `@notifications` (либо переопределяются `pagination_max_id` / `pagination_since_id` на `most_recent_notification_id`).
- Чтение `type` приводит строковое значение колонки к `Symbol`, обеспечивая совместимость со строгими Symbol-проверками в `REST::NotificationGroupSerializer`.
- Связь `most_recent_notification` объявляется опциональной (`optional: true`), а в `Account::Associations` добавляется `has_many :notification_group_records` с каскадным удалением (`dependent: :delete_all`).
- В `NotificationGroup` делегирование к `notification` настраивается с `allow_nil: true`, а `sample_accounts` очищаются от `nil` до создания `NotificationGroup`. В `GroupedNotificationsPresenter` извлечение первого и остальных авторов (`partial_avatars`) защищается от пустых массивов и `nil`. Группы с отсутствующим `notification` или пустым `sample_accounts` **не сериализуются** клиенту (исключаются до рендеринга либо восстанавливаются read-only чтением из `notifications`), предотвращая HTTP 500 и `TypeError` в Web UI.

#### 1.3. Транзакционный идемпотентный `UPSERT` и пакетное слияние
- **Транзакционность Write Path:** Запись в `notifications` и `UPSERT` в `notification_groups` выполняются **в одной транзакции PostgreSQL** как в `NotifyService`, так и в `UnfilterNotificationsWorker`. В `UnfilterNotificationsWorker` переход из карантина выполняется атомарно через `UPDATE notifications SET filtered = false, group_key = ... WHERE id IN (...) AND filtered = true RETURNING ...` внутри той же транзакции, что и многострочный `UPSERT`: при повторной попытке Sidekiq `WHERE filtered = true` вернёт 0 строк, гарантируя строгую идемпотентность счётчика `notifications_count`.
- **Детерминированный многострочный `UPSERT`:** Перед пакетной вставкой в `UnfilterNotificationsWorker` батч агрегируется по `(account_id, group_key)` (с раздельными `most_recent_notification_id`, `min_notification_id`, `notifications_count` и дедуплицированным массивом `sample_account_ids` длиной до 8) и сортируется по `[account_id, group_key]` для исключения `PG::DeadlockDetected` и `PG::CardinalityViolation`. SQL-запрос объединяет массивы `EXCLUDED.sample_account_ids` целиком (не теряя участников батча) и сохраняет позицию текущего лидера при запаздывающих уведомлениях:

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
  sample_account_ids = (
    SELECT array_agg(aid ORDER BY ord)
    FROM (
      SELECT aid, MIN(ord) AS ord
      FROM unnest(
        CASE
          WHEN EXCLUDED.most_recent_notification_id >= notification_groups.most_recent_notification_id
            THEN EXCLUDED.sample_account_ids || notification_groups.sample_account_ids
          ELSE notification_groups.sample_account_ids || EXCLUDED.sample_account_ids
        END
      ) WITH ORDINALITY AS t(aid, ord)
      GROUP BY aid
      ORDER BY ord
      LIMIT 8
    ) deduped
  ),
  updated_at = NOW();
```

- **Хранение негруппируемых уведомлений и `admin.sign_up`:**
  - В `notification_groups` группируются только три типа, группируемые Web-клиентом по умолчанию (`favourite`, `reblog`, `follow`). Все остальные типы — **включая `admin.sign_up`** — материализуются как одиночные строки `ungrouped-<notification_id>` (при этом `notifications.group_key` остаётся без изменений).
  - Это позволяет обслуживать 100% запросов официального Web-клиента (`grouped_types = ['favourite', 'reblog', 'follow']`) — для обычных пользователей, действующих и бывших модераторов — **одним** плоским запросом к `notification_groups` как в `#index`, так и в `#unread_count`, без многоисточникового слияния и без проверки ролей.
  - Запросы с иным набором `grouped_types[]` (например, содержащим `admin.sign_up` или отключающим `favourite`/`reblog`/`follow`) или с `include_filtered = true` полностью направляются в legacy-путь `Notification::Groups.paginate_groups` + `load_groups_data`.

#### 1.4. Пагинация, точный `page_min_id` и граница 90-дневного горизонта (`backfill_cutoff_id`)
- **Направление сортировки:** `ORDER BY most_recent_notification_id DESC LIMIT N` для первой страницы, `max_id` и `since_id`; `ORDER BY most_recent_notification_id ASC LIMIT N` с последующим разворотом результата для `min_id`.
- **Точный расчёт `page_min_id` и `page_max_id` (единообразно для полных и неполных страниц):**
  - `pagination_range` строится строго по правилам `Api::V2::NotificationsController`: на полной странице — от `last_id` до `first_id`; на неполной странице при `min_id` — от `last_id` до `max_id`; на неполной странице при пагинации вниз — от `since_id + 1` (если `since_id` задан, иначе `nil`) до `first_id`.
  - Для каждой группы на странице `page_max_id = group.most_recent_notification_id`.
  - Если нижняя граница `pagination_range.begin` отсутствует или `group.min_notification_id >= pagination_range.begin`, отдаётся `page_min_id = group.min_notification_id` без дополнительных запросов (95%+ групп).
  - Только для граничных групп (обычно 0–2 на страницу), чьё окно `[min_notification_id, most_recent_notification_id]` пересекает `pagination_range.begin`, выполняется точечный `Index Only Scan` по `index_notifications_on_group_recalculation` (`SELECT MIN(id) ... WHERE account_id = $1 AND group_key = $2 AND id >= $3`), возвращающий **реальный** минимальный ID уведомления этой группы внутри окна страницы.
  - В `#show` метаданные пагинации не формируются (`pagination_data = nil`).
- **Сквозная пагинация на границе `backfill_cutoff_id`:**
  - Хранится явный watermark `backfill_cutoff_id` (минимальный `notifications.id`, покрытый бэкфиллом и политикой retention).
  - При `max_id <= backfill_cutoff_id` или `min_id < backfill_cutoff_id` запрос сразу обслуживается через legacy `paginate_groups` (исключая пропуск истории при скролле вверх).
  - При скролле вниз из области выше `backfill_cutoff_id`, если выборка из `notification_groups` вернула меньше `limit` строк, контроллер проверяет наличие у аккаунта уведомлений с `id <= backfill_cutoff_id` (быстрый `EXISTS` по индексу `notifications`): если их нет — страница завершена без вызова legacy CTE; если есть — остаток добирается через `paginate_groups` с передачей `exclude_group_keys` (начальное значение `wt.groups`) для исключения дублирования `group_key` на стыке.
  - В `#unread_count`: при `last_read_id == nil` считаются все группы до `limit`; если `last_read_id.nil? || last_read_id < backfill_cutoff_id` и число групп в `notification_groups` меньше `limit`, выполняется fallback к legacy-подсчёту.

### 2. Консистентность при скрытии, массовых удалениях, очистке и модерации

1. **Скрытие группы (`Api::V2::NotificationsController#dismiss`):**
   - Если `group_key` начинается с `ungrouped-`: определяется фактический `notification.group_key` удаляемой записи; если он не `nil` (например, пользователь отключил группировку `follow`), удаляется одиночное уведомление и пересчитывается соответствующая строка в `notification_groups`.
   - Для малых групп (`notifications_count <= 100`, `ungrouped-*` или `filtered = true`): удаление строки `notification_groups`, удаление уведомлений (`by_group_key`) и обновление `NotificationRequest#reconsider_existence!` выполняются синхронно.
   - Для крупных групп (`notifications_count > 100`): фиксируется `cutoff_id = group.most_recent_notification_id`, сбрасывается Redis-ключ бакета `notif-group/<account_id>/<type_prefix>` (чтобы новые реакции открывали новый бакет), ставится фоновая задача `DismissNotificationGroupWorker(account_id, group_key, cutoff_id)` и удаляется строка из `notification_groups`. Воркер удаляет строго `by_group_key(group_key).where(id: ..cutoff_id)` батчами и вызывает `NotificationRequest#reconsider_existence!` для затронутых отфильтрованных отправителей.
2. **Удаление статусов (`RemoveStatusService` и `BatchedRemoveStatusService`):**
   - В `RemoveStatusService`: при удалении оригинального статуса (`!reblog?`) — как безвозвратном, так и мягком (`discard_with_reblogs`) — каскадный `remove_reblogs` и удаление статуса оборачиваются в подавление поштучного пересчёта (`original_removed: true`), полностью исключая $O(N^2)$ шторм на репостах. При безвозвратном удалении оригинального статуса связанные группы реакций удаляются одним индексным запросом `WHERE account_id = <status.account_id> AND target_status_id = <status.id>` (а связанные `ungrouped-*` — по парам `(account_id, group_key)` из удаляемых уведомлений). При отмене одиночного репоста (`reblog? && !original_removed`) выполняется штатный точечный пересчет группы репостов.
   - В `BatchedRemoveStatusService`: до `Status.unscoped.delete_all` выполняется пакетное удаление групп реакций для оригинальных статусов из коллекции по `(account_id, target_status_id)` и очистка затронутых `ungrouped-*`.
3. **Очистка ленты и замена уведомлений (`delete_all` пути):**
   - `Api::V1::NotificationsController#clear` (вызывается Web UI) и `Api::V2::NotificationsController#clear` синхронно очищают `notification_group_records` аккаунта вместе с `notifications`.
   - `LocalNotificationWorker`: при замене уведомлений типов `update`, `quoted_update`, `collection_update` предварительно выбирает ID удаляемых уведомлений и удаляет соответствующие строки `ungrouped-<id>` из `notification_groups` со скоупом по `account_id`.
4. **Изоляция Read Replica и фоновое восстановление (`RecomputeNotificationGroupWorker`):**
   - В `with_read_replica` контроллера `#index` синхронные мутации БД запрещены; признак неполной страницы вычисляется по числу выбранных строк до отбрасывания битых элементов.
   - Воркер `RecomputeNotificationGroupWorker` настраивается валидными опциями `sidekiq-unique-jobs 8.1`: `lock: :until_and_while_executing, on_conflict: :log, lock_ttl: 5.minutes.to_i`. Постановка задачи пропускается для записей моложе 60 секунд (защита от ложных срабатываний при лаге репликации).
   - Внутри воркера пересчёт выполняется под транзакционной блокировкой строки `notification_groups` (или `pg_advisory_xact_lock` по `(account_id, group_key)`), с `INNER JOIN accounts` по скоупу `Account.without_suspended` (исключая `suspended_at` и `requested_deletion_at` в 30-дневном окне), и физически удаляет строку группы, если видимых активных уведомлений не осталось.
5. **Синхронизация жизненного цикла аккаунтов и блокировок доменов (`without_suspended`):**
   - Для одиночных операций (`Account#suspend!`, `Account#unsuspend!`, `Account#mark_deleted!`, `AfterBlockService`, `AfterBlockDomainFromAccountService`, `DeleteAccountService#purge_generated_notifications!`) затронутые пары `(account_id, group_key)` собираются до удаления уведомлений и ставятся на дедуплицированный асинхронный пересчёт (`RecomputeNotificationGroupWorker`).
   - Для массовых операций (`BlockDomainService#suspend_accounts!`, `BlockDomainService#process_retroactive_updates!`, `Scheduler::SelfDestructScheduler`) используется батчевый низкоприоритетный воркер синхронизации с ограничением параллелизма (rate limit), что гарантирует точность `unread_count` и размера страницы без перегрузки Sidekiq и без «ленивой фильтрации» в презентере.

### 3. Таблица `dm_thread_permissions` (Сценарий 3, `ADR-4`)

#### 3.1. DDL и индексы
```sql
CREATE TABLE dm_thread_permissions (
  account_id bigint NOT NULL,
  target_account_id bigint NOT NULL,
  conversation_id bigint NOT NULL,
  created_at timestamp without time zone NOT NULL,
  PRIMARY KEY (account_id, target_account_id, conversation_id)
);

-- Индекс для быстрой очистки прав удаляемого собеседника в DeleteAccountService
CREATE INDEX CONCURRENTLY index_dm_thread_permissions_on_target_account_id
  ON dm_thread_permissions (target_account_id);
```

#### 3.2. Жизненный цикл, федерация и безопасность
- **Транзакционная выдача прав:** Вставка `INSERT ... ON CONFLICT DO NOTHING` выполняется внутри **той же** транзакции `ApplicationRecord.transaction`, что и сохранение статуса в `PostStatusService` (после присвоения `conversation_id`, до коммита и до постановки воркеров рассылки), а также в `ProcessMentionsService#assign_mentions!` при добавлении/реактивации не-тихих упоминаний при редактировании `direct`-статусов (`UpdateStatusService`).
- **Проверка строго по родительскому треду (без DoS-fallback):**
  - В `NotifyService#response_to_recipient?` проверяется наличие родителя (`in_reply_to_id` и `thread`) и выполняется `Index Only Scan` в `dm_thread_permissions` **строго** по `(account_id: recipient_id, target_account_id: sender_id, conversation_id: thread.conversation_id)` (без OR-массива).
  - Постоянный 90-дневный рекурсивный fallback **не используется** — таблица наполняется полным историческим бэкфиллом всех исходящих `direct`-статусов (менее 1–2% таблицы `statuses`), что полностью закрывает DoS-вектор через старые треды.
- **Федерация и анти-спуфинг без поломки `ConversationMute`:**
  - Дочерние ответы (`thread.present?`) безусловно наследуют `conversation_id` родителя (игнорируя внешний URI `conversation` у реплаев).
  - Входящим корневым статусам (`in_reply_to_id: nil`) запрещается привязываться к существующим **локальным** `Conversation` (или любым диалогам, уже имеющим записи в `dm_thread_permissions`), блокируя 2-шаговый спуфинг без разрушения `ConversationMute` для удалённых веток.
  - В `ThreadResolveWorker`: используется общая с `DistributionWorker` распределённая блокировка (`with_redis_lock` по `distribute:<child_status_id>`), при обновлении `conversation_id` выполняется каскадное обновление уже пришедших потомков и синхронизация `AccountConversation`; если для статуса уже существует отфильтрованное уведомление (`filtered = true`) и теперь подтверждено разрешение в `dm_thread_permissions`, оно разблокируется (`filtered = false`, upsert в `notification_groups`, обновление `NotificationRequest`, добавление в `AccountConversation`, стриминг), а при отсутствии уведомления запускается доставка.
- **Конкурентно-безопасный отзыв прав:**
  - Выдача и отзыв по `(account_id, conversation_id)` сериализуются транзакционным `pg_advisory_xact_lock`, а удаление выполняется через `DELETE ... WHERE NOT EXISTS (SELECT 1 FROM statuses ...)` (покрывая безвозвратное удаление, мягкое удаление `discard_with_reblogs`, `BatchedRemoveStatusService` и деактивацию упоминаний при редактировании в `ProcessMentionsService`).
  - В `AfterBlockService` права отзываются только при подтверждённой блокировке аккаунта (`blocking?`), не затрагивая mute; в `AfterBlockDomainFromAccountService` — при подтверждённой блокировке домена (`domain_blocking?`) одним `DELETE ... USING accounts`; в `DeleteAccountService` — для удаляемого аккаунта как по `account_id`, так и по `target_account_id`.

### 4. Политика роста данных (Retention & Pruning)
- Плановая фоновая задача еженедельно очищает из `notification_groups` записи, чьё `most_recent_notification_id` старше окна хранения (по умолчанию 90–180 дней), синхронно сдвигая watermark `backfill_cutoff_id` вперёд. Более старые уведомления остаются полностью доступными в API v2 через watermark-маршрутизацию в `notifications`.
- Записи `dm_thread_permissions` очищаются при удалении аккаунтов (`account_id` / `target_account_id`), блокировках и удалении исходных `direct`-статусов.

## Risks / Trade-offs

- **[Risk] Срыв HOT-update и B-tree bloat в `notification_groups` на вирусных постах** → **Mitigation:** Осознанный компромисс (`ADR-1`): обновление индексируемого `most_recent_notification_id` отключает HOT-update при in-order вставках. Митигируется агрессивным `autovacuum` (`scale_factor = 0.01`, `cost_limit = 1000`), `fillfactor = 70` (для out-of-order вставок) и регламентным `pg_repack`. Если продакшен-метрики зафиксируют деградацию из-за row lock contention на одиночном вирусном посте, в отдельной итерации оформляется `ADR-5` на идемпотентный coalescing пересчёта (без write-behind дельт в Redis).
- **[Risk] Write Amplification на горячей таблице `notifications` от индекса `index_notifications_on_group_recalculation`** → **Mitigation:** Индекс частичный (`WHERE group_key IS NOT NULL AND filtered = false`), поэтому не индексирует одиночные уведомления (`mention`, `status`, `admin.sign_up`, `update`, `poll`) и карантин; в задаче бенчмаркинга обязательно замеряются время `INSERT`, рост WAL и размер индекса.
- **[Risk] Пересечение Dual-Write и бэкфилла `notification_groups` (двойной учёт)** → **Mitigation:** Бэкфилл выполняется идемпотентным `INSERT ... ON CONFLICT DO UPDATE` с полным пересчётом точных агрегатов (`COUNT(*)`, `MIN/MAX(id)`, top-8 авторов) для граничных групп на стыке старта Dual-Write (без относительного `+ count`).

## Rollout Plan (Поэтапная Zero-Downtime выкатка)

Управление выкаткой строится на **раздельных динамических флагах в Redis** (с 5-секундным локальным in-memory кэшем и безопасным fallback при недоступности Redis; без зависимости от записи в PG Primary и без рестарта кластера):
- `notification_groups:write_enabled` (`bool`), `notification_groups:read_rollout_pct` (`0..100`, канарейка по `account_id % 100`).
- `dm_thread_permissions:write_enabled` (`bool`), `dm_thread_permissions:read_rollout_pct` (`0..100`).

**Фазы выкатки:**
1. **DDL (Zero-Downtime):** Применение миграций создания таблиц и конкурентных индексов (`read_rollout_pct = 0`, `write_enabled = false`).
2. **Dual-Write:** Деплой кода на все ноды Puma/Sidekiq -> включение `write_enabled = true` для обоих контуров (при `read_rollout_pct = 0`).
3. **Идемпотентный Backfill:**
   - Полный исторический бэкфилл `dm_thread_permissions` батчами с throttling (включая все `conversation_id` в исторических федеративных DM-цепочках).
   - Бэкфилл `notification_groups` за 90 дней с фиксацией watermark `backfill_cutoff_id` и пересчётом пограничных 12-часовых групп.
4. **Shadow Reconciliation:** Прогон периодической сверки выборки аккаунтов (`notification_groups` vs `notifications`, `dm_thread_permissions` vs `statuses_that_mention_sender`) до достижения `mismatch_rate < 0.01%`.
5. **Canary Read Ramp:** Пошаговое увеличение `read_rollout_pct`: `1% → 10% → 50% → 100%` с наблюдением за p95-латентностью, error rate и нагрузкой реплик.

## Rollback Plan (План отката)

1. **Обратимый откат чтения (без потери данных):** Плавное или немедленное снижение `read_rollout_pct → 0` (отдельно для групп или DM). Пока `write_enabled = true`, данные остаются консистентными, и включение можно безопасно повторить.
2. **Экстренное отключение записи (при аварии Write Path):** Установка `write_enabled = false` мгновенно останавливает `UPSERT` и запись разрешений без деплоя. **Обязательное правило runbook:** после отключения `write_enabled` повторное включение `read_rollout_pct > 0` **запрещено** до проведения инкрементального re-backfill с временной метки отключения.
3. **Удаление схемы (только пост-деинсталляция):** `DROP TABLE` выполняется **только** после выкатки релиза с удалённым кодом обращения к таблицам и полного дренирования очередей `RecomputeNotificationGroupWorker` и `DismissNotificationGroupWorker`.

## Observability & Metrics

- **Сценарии 1–2 (`notification_groups`):**
  - `mastodon_notification_groups_read_duration_seconds{path="precomputed|legacy"}` (p95/p99).
  - `mastodon_notification_groups_fallback_total{reason="custom_types|filtered|backfill_boundary|missing_record"}`.
  - `mastodon_notification_groups_upsert_duration_seconds` и `mastodon_notification_groups_recompute_enqueued_total`.
  - `mastodon_notification_groups_dismiss_worker_duration_seconds` и счётчик ошибок `DismissNotificationGroupWorker`.
- **Сценарий 3 (`dm_thread_permissions`):**
  - `mastodon_dm_permissions_check_total{result="hit|miss|kill_switch"}` и гистограмма `mastodon_dm_permissions_check_duration_seconds`.
- **Reconciliation и триггеры отката (SLI/SLO):**
  - `mastodon_notification_optimizations_reconciliation_mismatch_total{component="groups|dm_permissions", kind}`.
  - **Триггеры обязательного отката (`read_rollout_pct → 0`):** любой всплеск 5xx на `/api/v2/notifications` (`> 0.1%`), p95 чтения `> 50 мс`, `dm_permissions` false-negative mismatch `> 0` на shadow-сверке, очередь `RecomputeNotificationGroupWorker > 10 000` или p95 `upsert_duration > 100 мс`.
