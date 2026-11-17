## 1. Миграции базы данных и модели (DDL & Schema)

- [ ] 1.1 Создать миграцию для таблицы `notification_groups` (`account_id`, `group_key`, `type`, `most_recent_notification_id`, `min_notification_id`, `notifications_count`, `sample_account_ids`, `latest_notification_at`) с параметром `fillfactor = 70`, уникальным индексом `(account_id, group_key)` и индексом пагинации `(account_id, most_recent_notification_id DESC, type)`
- [ ] 1.2 Создать миграцию для таблицы `dm_thread_permissions` (`account_id`, `target_account_id`, `conversation_id`, `created_at`) с составным первичным ключом `(account_id, target_account_id, conversation_id)`
- [ ] 1.3 Создать ActiveRecord-модели `NotificationGroupRecord` (или обновить `NotificationGroup`) и `DmThreadPermission` с валидациями и связями

## 2. Сценарий 1: Write-Time Grouping и плоская пагинация ленты API v2

- [ ] 2.1 Реализовать атомарный метод `NotificationGroupRecord.upsert_from_notification!(notification)` с поддержкой как группируемых (`group_key`), так и негруппируемых (`ungrouped-{id}`) уведомлений при `filtered = false`
- [ ] 2.2 Интегрировать вызов `upsert_from_notification!` в `NotifyService` и пакетную материализацию групп в `UnfilterNotificationsWorker` при разблокировке принятых запросов
- [ ] 2.3 Реализовать метод плоской пагинации по таблице `notification_groups` (по `most_recent_notification_id`, с фильтрацией `types[]`, `exclude_types[]` и `without_suspended`) и прозрачный fallback на `notifications` для кастомных `grouped_types[]` и `include_filtered=true`
- [ ] 2.4 Переключить `Api::V2::NotificationsController#index` и `#unread_count` на использование `notification_groups`

## 3. Сценарий 2: Материализация и консистентная инвалидация агрегатов групп

- [ ] 3.1 Реализовать в SQL-выражении `UPSERT` дедуплицированное обновление массива авторов `(ARRAY_PREPEND($from_id, array_remove(sample_account_ids, $from_id)))[1:8]`, инкремент `notifications_count` и обновление граничных ID (`min_notification_id`, `most_recent_notification_id`)
- [ ] 3.2 Убрать вызов `unnest($3::text[])` с 5 подзапросами в `NotificationGroup.load_groups_data` при стандартном чтении из `notification_groups`
- [ ] 3.3 Реализовать синхронизацию и пересчет строки `notification_groups` при удалении уведомления (`after_destroy`, `dismiss`), блокировке аккаунта/домена (`AfterBlockService`, `AfterBlockDomainFromAccountService`) и удалении аккаунта (`DeleteAccountService`)
- [ ] 3.4 Добавить защиту от `nil` и `suspended`-аккаунтов при сборке `sample_accounts` в `NotificationGroup` и `GroupedNotificationsPresenter`

## 4. Сценарий 3: Индексированная проверка разрешений в цепочках личных сообщений (`dm_thread_permissions`)

- [ ] 4.1 Добавить запись в `dm_thread_permissions` при публикации пользователем исходящего статуса с `visibility = direct` для всех активных (`silent = false`) упоминаний
- [ ] 4.2 Заменить рекурсивный CTE `statuses_that_mention_sender` в `NotifyService::BaseCondition` на индексную проверку существования записи в `dm_thread_permissions` с верификацией совпадения `conversation_id` у `in_reply_to`-статуса
- [ ] 4.3 Реализовать отзыв разрешений из `dm_thread_permissions` в `AfterBlockService`, `AfterBlockDomainFromAccountService` и при удалении/редактировании исходящего личного сообщения

## 5. Тестирование и верификация

- [ ] 5.1 Написать RSpec-тесты для `notification_groups` (пагинация `max_id`/`min_id`/`since_id`, фильтрация `types[]`, разблокировка в `UnfilterNotificationsWorker`, отмена лайков и суспенд авторов из `sample_account_ids`)
- [ ] 5.2 Написать RSpec-тесты для `dm_thread_permissions` (защита от инъекции спамера в групповом DM, блокировка новых тредов `in_reply_to_id: nil`, игнорирование публичных ответов, сохранение работы фильтров `not_following` и `new_accounts`)
