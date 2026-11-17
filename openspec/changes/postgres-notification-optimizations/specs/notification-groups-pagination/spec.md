## ADDED Requirements

### Requirement: Write-Time материализация записей групп в таблице `notification_groups`
Система ДОЛЖНА (SHALL) материализовать каждую группу уведомлений (включая одиночные негруппируемые уведомления с ключом `ungrouped-{id}`) в выделенной таблице PostgreSQL `notification_groups` в момент создания видимого уведомления (`filtered = false`) или его разблокировки из карантина. Таблица ДОЛЖНА содержать поля `account_id`, `group_key`, `type`, `most_recent_notification_id`, `min_notification_id`, `latest_notification_at` и быть проиндексирована по `(account_id, most_recent_notification_id DESC)` с параметром хранения `fillfactor = 70` для снижения MVCC/index bloat при частых обновлениях.

#### Scenario: Создание новой группы или одиночного уведомления
- **WHEN** `NotifyService` сохраняет новое уведомление с `filtered = false` и вычисленным `group_key` (или `ungrouped-{id}` для негруппируемых типов)
- **THEN** система выполняет атомарный `INSERT ... ON CONFLICT (account_id, group_key) DO UPDATE` в таблицу `notification_groups`, устанавливая `most_recent_notification_id = notification.id`, `min_notification_id = COALESCE(notification_groups.min_notification_id, notification.id)` и `type = notification.type`

#### Scenario: Поднятие существующей группы наверх ленты при новой реакции
- **WHEN** в существующую 12-часовую группу поступает новое уведомление с более высоким `notification.id`
- **THEN** `most_recent_notification_id` и `latest_notification_at` строки в `notification_groups` обновляются до значений нового уведомления, перемещая группу наверх индексной сортировки `ORDER BY most_recent_notification_id DESC`

#### Scenario: Изоляция отфильтрованных уведомлений и их публикация при одобрении запроса
- **WHEN** создается уведомление с `filtered = true`
- **THEN** оно НЕ записывается в `notification_groups` до тех пор, пока пользователь не примет запрос (`AcceptNotificationRequestService`), после чего `UnfilterNotificationsWorker` вычисляет `group_key` для разблокированных записей и выполняет пакетный `UPSERT` в `notification_groups`

---

### Requirement: Плоская индексная пагинация ленты API v2 без рекурсивного CTE
При стандартных запросах к `/api/v2/notifications` и `/api/v2/notifications/unread_count` система ДОЛЖНА (SHALL) выполнять выборку страниц путем прямого индексного сканирования таблицы `notification_groups` по `most_recent_notification_id` вместо выполнения рекурсивного запроса `WITH RECURSIVE ... LATERAL` по таблице `notifications`.

#### Scenario: Загрузка первой и последующих страниц ленты с фильтрацией по типам
- **WHEN** клиент запрашивает `GET /api/v2/notifications` с параметрами `types[]`, `exclude_types[]`, `max_id`, `min_id` или `since_id` (при стандартном наборе `grouped_types`)
- **THEN** система выполняет `SELECT` из `notification_groups WHERE account_id = $1` с фильтрацией по колонке `type` и диапазону `most_recent_notification_id` (`< max_id`, `> min_id`, `> since_id`) и сортировкой `ORDER BY most_recent_notification_id DESC LIMIT $limit`

#### Scenario: Fallback при кастомном `grouped_types[]` или `include_filtered=true`
- **WHEN** клиент явно передает нестандартный список `grouped_types[]` (требующий разгруппировки базовых группируемых типов `favourite`, `reblog`, `follow`) или параметр `include_filtered=true`
- **THEN** система прозрачно переключает выполнение запроса на чтение из таблицы `notifications`, сохраняя 100% обратную совместимость контракта API v2

#### Scenario: Подсчет непрочитанных групп (`unread_count`)
- **WHEN** клиент запрашивает `GET /api/v2/notifications/unread_count`
- **THEN** система подсчитывает количество записей в `notification_groups` с `most_recent_notification_id > last_read_id` через быстрый `Index Only Scan` с лимитом `limit`, не запуская рекурсивный CTE

---

### Requirement: Исключение групп от заблокированных и приостановленных аккаунтов (`without_suspended`)
Система ДОЛЖНА (SHALL) гарантировать, что группы уведомлений, все авторы которых были приостановлены (`suspended_at IS NOT NULL`) или удалены, не возвращаются в выдаче API v2 и не искажают размер страницы пагинации.

#### Scenario: Фильтрация групп при суспенде единственного автора
- **WHEN** единственный автор группы уведомлений получает статус `suspended`
- **THEN** при выборке страницы из `notification_groups` или фоновой обработке суспенда такая группа исключается из выдачи пользователя
