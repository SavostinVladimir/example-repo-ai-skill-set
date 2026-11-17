## ADDED Requirements

### Requirement: Материализация счетчика и дедуплицированного списка авторов в строке группы
Система ДОЛЖНА (SHALL) хранить в каждой записи таблицы `notification_groups` предвычисленные агрегаты: `notifications_count (bigint, default: 1, not null)`, `sample_account_ids (bigint[], default: '{}', not null)`, `min_notification_id (bigint, not null)`, `most_recent_notification_id (bigint, not null)` и `latest_notification_at (datetime, not null)`, обновляя их атомарно при поступлении новых уведомлений и полностью исключая выполнение 5 коррелированных подзапросов через `unnest` при чтении ленты.

#### Scenario: Атомарное обновление счетчика и массива авторов без дубликатов
- **WHEN** в существующую группу добавляется новое уведомление от аккаунта `$from_account_id`
- **THEN** система атомарно увеличивает `notifications_count = notifications_count + 1` и обновляет `sample_account_ids` по формуле `(ARRAY_PREPEND($from_account_id, array_remove(sample_account_ids, $from_account_id)))[1:8]`, гарантируя отсутствие дублирующихся ID аккаунтов и максимальную длину массива в 8 элементов

#### Scenario: Чтение агрегатов группы за 0 дополнительных подзапросов
- **WHEN** `Api::V2::NotificationsController#index` или `#show` формирует объекты `NotificationGroup`
- **THEN** значения `notifications_count`, `sample_account_ids`, `most_recent_notification_id`, `page_min_id` (`min_notification_id`) и `latest_page_notification_at` (`latest_notification_at`) считываются напрямую из уже загруженных строк `notification_groups` без выполнения SQL-запроса `SELECT ... FROM unnest($group_keys)`

---

### Requirement: Консистентный пересчет агрегатов и защита от пустых ссылок при удалении и блокировках
Система ДОЛЖНА (SHALL) поддерживать целостность `notifications_count`, `sample_account_ids` и `most_recent_notification_id` при удалении уведомлений (отмена лайка/репоста, `dismiss`, блокировка пользователя/домена через `AfterBlockService`, удаление аккаунта) и защищать сериализаторы от `nil`-значений.

#### Scenario: Удаление единственного или всех уведомлений в группе
- **WHEN** последнее оставшееся уведомление в группе удаляется (при отмене реакции или вызове `dismiss`)
- **THEN** соответствующая запись в `notification_groups` физически удаляется из базы данных, предотвращая появление в ленте карточек с `notifications_count = 0` или пустым `sample_account_ids`

#### Scenario: Добор участников в `sample_account_ids` при отмене реакции одним из топ-8 авторов
- **WHEN** уведомление удаляется из группы, в которой `notifications_count > 1`, и после удаления автора из `sample_account_ids` длина массива становится меньше `LEAST(8, notifications_count)` (либо удалено уведомление с `id == most_recent_notification_id`)
- **THEN** система пересчитывает `most_recent_notification_id`, `notifications_count` и `sample_account_ids` (топ-8 `from_account_id`) для данного `(account_id, group_key)` одним индексным запросом к `notifications`

#### Scenario: Защита сериализатора от удаленных или приостановленных аккаунтов в `sample_account_ids`
- **WHEN** один из аккаунтов, чей ID сохранен в `sample_account_ids`, был приостановлен (`suspended`) или физически удален в фоновом режиме (`delete_all`)
- **THEN** при сборке `NotificationGroup` невалидные или отсутствующие в `accounts_map` записи отфильтровываются (`.compact`), а в случае пустого списка авторов при живых уведомлениях запускается синхронный пересчет группы или её скрытие без возбуждения `NoMethodError` (`500 Internal Server Error`)
