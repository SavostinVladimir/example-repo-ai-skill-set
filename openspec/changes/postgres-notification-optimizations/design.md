## Context

В текущей реализации Mastodon три операции с уведомлениями создают непропорционально высокую нагрузку на PostgreSQL:
1. **Пагинация сгруппированных уведомлений (`Notification::Groups.paginate_groups` в API v2):** использует `WITH RECURSIVE` с 40 итерациями `LATERAL` и проверкой `NOT group_key = ANY(wt.groups)`. На популярных постах с тысячами лайков планировщик перебирает тысячи индексных записей на каждый HTTP-запрос.
2. **Сбор агрегатов по группам (`NotificationGroup.load_groups_data`):** разворачивает массив из 40 ключей через `unnest($3::text[])` и выполняет по 5 коррелированных подзапросов на каждую группу (до 200 подзапросов + полный `COUNT(*)` по группе).
3. **Проверка цепочки личных сообщений (`NotifyService::BaseCondition#statuses_that_mention_sender`):** выполняет рекурсивный CTE по иерархии `in_reply_to_id` глубиной до 100 шагов с соединением `statuses` и `mentions` на критическом пути записи (Write Path) при каждом входящем DM от незнакомого отправителя.

По результатам архитектурного ревью (PostgreSQL, Redis, UX/Spec, Red Team) было доказано, что перенос ленты и агрегатов групп в Redis экономически и функционально нецелесообразен (~30–40 ГБ RAM на 100k пользователей, невозможность фильтрации по `types[]` и `without_suspended`, гонки на JSON-массивах), тогда как правильно спроектированная материализация в PostgreSQL решает все три проблемы с сохранением ACID-гарантий и контрактов API v2.

## Goals / Non-Goals

**Goals:**
- Снизить латентность чтения `/api/v2/notifications` и `/api/v2/notifications/unread_count` с 150–500 мс до 1–5 мс за счет отказа от рекурсивного CTE и 200 подзапросов `unnest`.
- Устранить рекурсивный CTE `statuses_that_mention_sender` глубиной до 100 шагов при проверке входящих личных сообщений, заменив его на точечный `Index Only Scan` за $< 0.2$ мс.
- Сохранить 100% совместимость с контрактами API v2 (`types[]`, `exclude_types[]`, `grouped_types[]`, `include_filtered`, `without_suspended`, `page_min_id`, `page_max_id`) и правилами безопасности (защита от инъекции спамеров через групповые DM и подмену `conversation_id`).
- Предотвратить деградацию PostgreSQL (MVCC bloat, срыв HOT-update, `500 Internal Server Error` на пустых массивах `sample_account_ids`) при пиковых нагрузках и отмене реакций.

**Non-Goals:**
- Изменение формата ответов REST API v1 или v2 для клиентских приложений.
- Вынос основного хранилища уведомлений во внешние NoSQL/In-Memory СУБД (Redis, Cassandra).
- Изменение продуктовых правил группировки (12-часовое окно `MAXIMUM_GROUP_SPAN_HOURS = 12`).

## Decisions

### 1. Единая таблица `notification_groups` для Write-Time Grouping и агрегатов (Сценарии 1 и 2)
- **Решение:** Создать таблицу `notification_groups`:
  ```sql
  CREATE TABLE notification_groups (
    id bigint PRIMARY KEY DEFAULT timestamp_id('notification_groups'),
    account_id bigint NOT NULL,
    group_key varchar NOT NULL,
    type varchar NOT NULL,
    most_recent_notification_id bigint NOT NULL,
    min_notification_id bigint NOT NULL,
    notifications_count bigint NOT NULL DEFAULT 1,
    sample_account_ids bigint[] NOT NULL DEFAULT '{}',
    latest_notification_at timestamp without time zone NOT NULL,
    created_at timestamp without time zone NOT NULL,
    updated_at timestamp without time zone NOT NULL
  ) WITH (fillfactor = 70);

  CREATE UNIQUE INDEX index_notification_groups_on_account_and_group_key
    ON notification_groups (account_id, group_key);

  CREATE INDEX index_notification_groups_pagination
    ON notification_groups (account_id, most_recent_notification_id DESC, type);
  ```
- **Почему именно так (учет ревью):**
  - *Сортировка по `most_recent_notification_id DESC`, а не по `id`:* При поступлении нового лайка в существующую группу её `id` не меняется, но `most_recent_notification_id` обновляется, поднимая группу наверх ленты и сохраняя единое пространство курсоров (`max_id`, `min_id`, `since_id`, `last_read_id`) с таблицей `notifications` и WebSocket-событиями.
  - *Хранение негруппируемых уведомлений:* Для уведомлений с `group_key = NULL` в `notification_groups` записывается строка с `group_key = 'ungrouped-' || notification.id`, что позволяет вычитывать всю смешанную ленту одним `Index Scan Backward`.
  - *Атомарный `UPSERT` без дублей в `sample_account_ids`:*
    ```sql
    INSERT INTO notification_groups (
      account_id, group_key, type, most_recent_notification_id, min_notification_id,
      notifications_count, sample_account_ids, latest_notification_at, created_at, updated_at
    ) VALUES ($1, $2, $3, $4, $4, 1, ARRAY[$5::bigint], $6, NOW(), NOW())
    ON CONFLICT (account_id, group_key) DO UPDATE SET
      most_recent_notification_id = GREATEST(notification_groups.most_recent_notification_id, EXCLUDED.most_recent_notification_id),
      min_notification_id = LEAST(notification_groups.min_notification_id, EXCLUDED.min_notification_id),
      latest_notification_at = GREATEST(notification_groups.latest_notification_at, EXCLUDED.latest_notification_at),
      notifications_count = notification_groups.notifications_count + 1,
      sample_account_ids = (ARRAY_PREPEND($5::bigint, array_remove(notification_groups.sample_account_ids, $5::bigint)))[1:8],
      updated_at = NOW();
    ```
  - *Fallback для кастомного `grouped_types[]`:* Если клиент запрашивает нестандартный `grouped_types[]` (например, просит разгруппировать `favourite`), контроллер использует классический путь чтения из `notifications`.

### 2. Консистентность при удалении, банах и разблокировке (`UnfilterNotificationsWorker`)
- **Решение:**
  1. В `UnfilterNotificationsWorker` вместо слепого `update_all(filtered: false)` вычислять `group_key` для разблокируемых уведомлений и выполнять пакетный `UPSERT` в `notification_groups`.
  2. При удалении уведомления (`after_destroy` или батчевая очистка в `AfterBlockService`) выполнять пересчет или удаление группы:
     - Если в группе было 1 уведомление (`notifications_count <= 1`), строка `notification_groups` удаляется.
     - Если удаленный автор входил в `sample_account_ids` или удалено уведомление с `id == most_recent_notification_id`, выполняется быстрый пересчет строки группы по индексу `(account_id, group_key)` из таблицы `notifications`.
  3. В `NotificationGroup.from_notifications` при маппинге `sample_account_ids.filter_map { |id| accounts_map[id] }` отсекать удаленные и `suspended` аккаунты (`.reject(&:suspended?)`), исключая `NoMethodError` (`500 Error`) в `GroupedNotificationsPresenter`.

### 3. Таблица `dm_thread_permissions` вместо `account_conversations` и `notification_permissions` (Сценарий 3)
- **Решение:** Создать узкую таблицу:
  ```sql
  CREATE TABLE dm_thread_permissions (
    account_id bigint NOT NULL,
    target_account_id bigint NOT NULL,
    conversation_id bigint NOT NULL,
    created_at timestamp without time zone NOT NULL,
    PRIMARY KEY (account_id, target_account_id, conversation_id)
  );
  ```
- **Почему отвергнуты альтернативы из первого драфта:**
  - *Почему не `account_conversations`:* Туда добавляются все входящие DM и все участники групповых переписок (`participants_from_status`), что открывает уязвимость «Троянский конь» (третье лицо упоминает жертву и спамера в одном сообщении), а также отсутствует GIN-индекс на массив `participant_account_ids`.
  - *Почему не `notification_permissions`:* Наличие записи в `notification_permissions` (`override_for_sender?`) глобально отключает вообще все политики фильтрации (`not_following`, `new_accounts`, `bots`) для всех типов уведомлений, тогда как ответ в DM должен разрешать ответы только в рамках данного DM-треда.
  - *Защита от подмены `conversation_id` по ActivityPub:* При проверке входящего ответа в `NotifyService` проверяется:
    1. Что родительский статус `in_reply_to_id` реально существует и имеет тот же `conversation_id`, что и входящий статус (`target_status.in_reply_to&.conversation_id == target_status.conversation_id`).
    2. Что в `dm_thread_permissions` есть запись `(account_id: @recipient.id, target_account_id: @sender.id, conversation_id: target_status.conversation_id)`.

## Risks / Trade-offs

- **[Risk] Индексный и табличный bloat в `notification_groups` на вирусных постах (из-за обновления индексированного поля `most_recent_notification_id` отключается HOT-update)** → **Mitigation:** Установка `fillfactor = 70` на таблицу и индекс, агрессивные настройки `autovacuum_vacuum_scale_factor = 0.01`, `autovacuum_vacuum_cost_limit = 1000` специально для таблицы `notification_groups`.
- **[Risk] Лаг репликации между записью в Primary и чтением в `with_read_replica`** → **Mitigation:** Чтение `notification_groups` и связанных `Notification` происходит в рамках одного и того же блока `with_read_replica` из одной реплики, что гарантирует внутреннюю консистентность снимка БД.
- **[Risk] Начальное наполнение (Backfill) таблицы `notification_groups` на живом инстансе** → **Mitigation:** Фоновая пост-миграция батчами по `account_id` за последние 90 дней с включением фича-флага чтения после завершения бэкфилла.

## Migration Plan

1. **Этап 1 (DDL):** Создание таблиц `notification_groups` и `dm_thread_permissions` с индексами.
2. **Этап 2 (Dual-Write):** Включение записи в `notification_groups` (в `NotifyService`, `UnfilterNotificationsWorker` и коллбэках удаления) и в `dm_thread_permissions` (при публикации исходящих `direct`-статусов).
3. **Этап 3 (Backfill):** Фоновый скрипт агрегирует существующие записи `notifications` и исходящие `direct`-посты в новые таблицы.
4. **Этап 4 (Switch Read Path):** Переключение `Api::V2::NotificationsController` и `NotifyService#statuses_that_mention_sender` на использование новых таблиц.
