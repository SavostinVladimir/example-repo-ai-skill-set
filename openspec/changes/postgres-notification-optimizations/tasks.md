## 1. Миграции БД, модели и динамические рубильники (DDL & Foundation)

- [ ] 1.1 Создать Zero-Downtime миграцию таблицы `notification_groups` (включая `target_status_id`, параметры хранения и конкурентные индексы пагинации и по статусу) согласно разделу 1.1 `design.md`
- [ ] 1.2 Создать Zero-Downtime миграцию таблицы `dm_thread_permissions` (с вторичным индексом по `target_account_id`) и частичного покрывающего индекса пересчёта на `notifications` согласно разделам 1.1 и 3.1 `design.md`
- [ ] 1.3 Реализовать модели `NotificationGroupRecord` (нативный составной PK без переопределения `id`, Symbol-чтение `type`, связь в `Account::Associations`) и `DmThreadPermission`, а также безопасное делегирование в `NotificationGroup` (раздел 1.2 `design.md`)
- [ ] 1.4 Реализовать динамические Redis-рубильники (`write_enabled` и канареечный `read_rollout_pct`) с локальным кэшированием и безопасным fallback раздельно для `notification_groups` и `dm_thread_permissions` (раздел Rollout Plan `design.md`)

## 2. Сценарий 1: Write-Time Grouping, пагинация и `unread_count` API v2

- [ ] 2.1 Реализовать транзакционный `NotificationGroupRecord.upsert_from_notification!` и интегрировать его в транзакцию `NotifyService` (с материализацией `admin.sign_up` как `ungrouped-<id>`) согласно разделу 1.3 `design.md`
- [ ] 2.2 Обновить `UnfilterNotificationsWorker`: проверка двустороннего окна бакета, атомарный переход из карантина и детерминированный многострочный `UPSERT` с полным слиянием авторов в одной транзакции (раздел 1.3 `design.md`)
- [ ] 2.3 Реализовать плоскую пагинацию по `notification_groups` в `Api::V2::NotificationsController#index` (обе стороны, валидные `Link`-заголовки, fallback для нестандартного `grouped_types[]`/`include_filtered` и маршрутизация на границе `backfill_cutoff_id` без дублей и лишних сканов) согласно разделу 1.4 `design.md`
- [ ] 2.4 Переключить `Api::V2::NotificationsController#unread_count` на `notification_groups` с поддержкой отсутствующего маркера и границы `backfill_cutoff_id` (раздел 1.4 `design.md`)

## 3. Сценарий 2: Агрегаты, консистентная инвалидация и отказоустойчивость

- [ ] 3.1 Обновить `NotificationGroup.from_notifications` и `GroupedNotificationsPresenter`: точный расчёт `page_min_id` (с точечным добором для граничных групп на полных и неполных страницах, включая `since_id`/`min_id`), контракт `#show` без курсоров, очистка `nil` авторов и защита от сериализации осиротевших групп (разделы 1.2 и 1.4 `design.md`)
- [ ] 3.2 Реализовать `RecomputeNotificationGroupWorker` с транзакционной блокировкой группы, фильтрацией по активным аккаунтам и валидными параметрами дедупликации и TTL, а также защиту от постановки задач при лаге репликации (раздел 2.4 `design.md`)
- [ ] 3.3 Обновить `Api::V2::NotificationsController#dismiss` и создать `DismissNotificationGroupWorker`: синхронный путь для малых групп, асинхронный путь с `cutoff_id`, сбросом бакета и обновлением `NotificationRequest` для крупных, обработка `ungrouped-<id>` для группируемых типов (раздел 2.1 `design.md`)
- [ ] 3.4 Интегрировать пакетную очистку `notification_groups` в `RemoveStatusService` (включая подавление пересчёта в `remove_reblogs` и `original_removed`), `BatchedRemoveStatusService`, `Api::V1::NotificationsController#clear`, `Api::V2::NotificationsController#clear` и `LocalNotificationWorker` (разделы 2.2 и 2.3 `design.md`)
- [ ] 3.5 Интегрировать асинхронную синхронизацию `without_suspended` и сбор затронутых ключей до удаления уведомлений в `Account` (`suspend!`, `unsuspend!`, `mark_deleted!`), `AfterBlockService`, `AfterBlockDomainFromAccountService`, `DeleteAccountService`, `BlockDomainService` (включая ретроактивные обновления) и `Scheduler::SelfDestructScheduler` с ограничением параллелизма (раздел 2.5 `design.md`)

## 4. Сценарий 3: Индексированный реестр разрешений DM (`dm_thread_permissions`)

- [ ] 4.1 Интегрировать транзакционную выдачу `dm_thread_permissions` в `PostStatusService` (внутри транзакции сохранения статуса) и в `ProcessMentionsService` (и выдача при редактировании в `UpdateStatusService`, и конкурентно-безопасный отзыв при деактивации) согласно разделу 3.2 `design.md`
- [ ] 4.2 Обновить `Status#set_conversation`, `ActivityPub::Activity::Create` и `ThreadResolveWorker`: безусловное наследование диалога от родителя, блокировка спуфинга локальных/активных DM-диалогов без поломки `ConversationMute`, каскадное обновление потомков, синхронизация `AccountConversation` и вывод отфильтрованных DM из карантина под общей блокировкой с `DistributionWorker` (раздел 3.2 `design.md`)
- [ ] 4.3 Переключить `NotifyService::BaseCondition#response_to_recipient?` на проверку `dm_thread_permissions` строго по родительскому диалогу (без OR-массива и без постоянного рекурсивного fallback, под управлением DM Kill-Switch) согласно разделу 3.2 `design.md`
- [ ] 4.4 Интегрировать конкурентно-безопасный отзыв `dm_thread_permissions` в `RemoveStatusService` (включая мягкое удаление), `BatchedRemoveStatusService`, `AfterBlockService` (только при блокировке, не при mute), `AfterBlockDomainFromAccountService` (проверка блокировки домена) и `DeleteAccountService` (по обеим сторонам пары) согласно разделу 3.2 `design.md`

## 5. Бэкфилл, эксплуатация, тестирование и бенчмарки

- [ ] 5.1 Реализовать идемпотентные фоновые задачи бэкфилла (полная история для `dm_thread_permissions` и 90 дней с watermark `backfill_cutoff_id` для `notification_groups`) и плановую задачу retention/pruning (раздел 4 и Rollout Plan `design.md`)
- [ ] 5.2 Добавить shadow-reconciliation задачу сверки данных и метрики Prometheus/StatsD для обоих контуров (чтение, fallback, `UPSERT`, `DismissNotificationGroupWorker`, `dm_thread_permissions`, `mismatch_total`) согласно разделу Observability `design.md`
- [ ] 5.3 Написать RSpec-тесты для `notification_groups`: пагинация (`max_id`, `min_id`, `since_id`), точный `page_min_id` на полных и неполных страницах, стык `backfill_cutoff_id`, `admin.sign_up`, `#show`, `#clear` v1/v2, `LocalNotificationWorker`, конкурентный `#dismiss` с новой реакцией, `RemoveStatusService#remove_reblogs`, ретраи воркеров, суспенд/блок домена, реплика с осиротевшей группой и Kill-Switch
- [ ] 5.4 Написать RSpec-тесты для `dm_thread_permissions`: выдача при публикации и редактировании, «Троянский конь», кросс-тредовый и корневой спуфинг, сохранность `ConversationMute`, гонка `ThreadResolveWorker` + `DistributionWorker` при `:filter`, конкурентный отзыв при удалении/редактировании, блокировка аккаунта/домена vs mute, удаление аккаунта и Kill-Switch
- [ ] 5.5 Провести бенчмарки `EXPLAIN (ANALYZE, BUFFERS)` на Read Path (пагинация, `unread_count`, пересчёт, `dm_thread_permissions`) и Write Path (`INSERT` в `notifications` с новым покрывающим индексом, `UPSERT` в `notification_groups`, WAL и bloat) для подтверждения чистого выигрыша по CPU и I/O PostgreSQL
