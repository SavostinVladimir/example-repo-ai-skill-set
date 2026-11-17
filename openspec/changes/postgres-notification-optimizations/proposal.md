## Why

Подсистема уведомлений Mastodon создает критическую нагрузку на PostgreSQL в трех ключевых точках: рекурсивная группировка ленты на лету через `WITH RECURSIVE ... LATERAL` в API v2, выполнение до 200 скалярных подзапросов через `unnest` при сборке метаданных групп (`load_groups_data`) и рекурсивный обход дерева ответов глубиной до 100 шагов при проверке антиспам-политики для личных сообщений (`statuses_that_mention_sender`). Переход к предварительной материализации групп, агрегатов и разрешений тредов на этапе записи позволит сократить потребление CPU и дискового I/O базы данных на порядок при полном сохранении пользовательских сценариев и контрактов безопасности.

## What Changes

- **Сценарий 1 (Write-Time Grouping для пагинации API v2):** Вводится выделенная таблица `notification_groups` для предварительной группировки уведомлений на этапе записи (`NotifyService` и `UnfilterNotificationsWorker`) с поддержкой фильтрации по типам, признаку карантина (`filtered`), блокировкам (`without_suspended`), динамическому `grouped_types[]` и курсорной пагинации по `most_recent_notification_id`.
- **Сценарий 2 (Материализация агрегатов групп):** В таблице `notification_groups` материализуются счетчик уведомлений (`notifications_count`), дедуплицированный массив последних участников (`sample_account_ids bigint[8]`) и граничные курсоры (`min_notification_id`, `most_recent_notification_id`, `latest_notification_at`), устраняя 200 коррелированных подзапросов и `COUNT(*)` при чтении страницы, с механизмом консистентного добора участников при отмене реакций и банах аккаунтов.
- **Сценарий 3 (Индексированный реестр разрешений DM-тредов):** Вводится узкая таблица `dm_thread_permissions` с составным B-Tree индексом для фиксации факта отправки пользователем личного сообщения (`visibility = direct`) конкретному собеседнику в рамках ветки диалога, заменяющая рекурсивный CTE `statuses_that_mention_sender` на точечный `Index Only Scan` без риска инъекции спамеров через групповые чаты.

## Capabilities

### New Capabilities
- `notification-groups-pagination`: Материализация и пагинация сгруппированных уведомлений в PostgreSQL (`notification_groups`) взамен рекурсивного CTE с `LATERAL` в API v2.
- `notification-groups-aggregates`: Предварительный расчет, хранение и консистентная инвалидация агрегатов группы (`notifications_count`, `sample_account_ids`, курсоры страницы) взамен множественных подзапросов через `unnest`.
- `dm-thread-permissions`: Индексированная проверка права на ответ в цепочке личных сообщений через таблицу `dm_thread_permissions` взамен рекурсивного обхода предков `statuses_that_mention_sender`.

### Modified Capabilities
<!-- Нет модифицируемых существующих спецификаций в openspec/specs/ -->

## Impact

- **Схема базы данных (`db/schema.rb`, миграции):** Создание таблиц `notification_groups` (с `fillfactor = 70` и составными индексами) и `dm_thread_permissions`.
- **Модели и сервисы:** `Notification`, `Notification::Groups`, `NotificationGroup`, `NotifyService`, `FanOutOnWriteService`, `UnfilterNotificationsWorker`, `AfterBlockService`, `AfterBlockDomainFromAccountService`, `DeleteAccountService`.
- **Контроллеры и сериализаторы:** `Api::V2::NotificationsController`, `GroupedNotificationsPresenter`, `REST::NotificationGroupSerializer`.
