## ADDED Requirements

### Requirement: Разделение дашборда каждого компонента на системные метрики и метрики приложения
Дашборд индивидуального компонента SHALL предоставлять специализированное представление для каждого ключевого компонента (`Puma`, `Sidekiq`, `Node.js Streaming`, `PostgreSQL`) со строгим визуальным разделением на блок системных/рантайм-метрик и блок метрик приложения.

#### Scenario: Переход к диагностике проблемного компонента
- **WHEN** инженер выбирает конкретный компонент для анализа причины деградации
- **THEN** дашборд раздельно отображает системное состояние среды исполнения (память, GC, потоки, event loop, дисковый кэш, блокировки, пулы соединений) и прикладную телеметрию (эндпоинты, воркеры, очереди, каналы стриминга, SQL-запросы и таблицы подсистемы уведомлений)

---

### Requirement: Глубокая диагностика компонентов Puma и Sidekiq
Дашборды компонентов `Puma` и `Sidekiq` SHALL отображать процессные и пуловые метрики Ruby/Rails в системном блоке и детальную статистику маршрутов, очередей, спанов OpenTelemetry и фоновых классов в прикладном блоке.

#### Scenario: Диагностика компонента Puma Web Server
- **WHEN** открыт дашборд компонента `Puma`
- **THEN** в системном блоке отображаются RSS, слоты кучи и счетчики GC (`Process{type="puma"}`), потоки и backlog сокета (`Instrumentation::Puma`) и состояние пула `ActiveRecord{type="puma"}`, а в прикладном блоке — `queue_time`, RPS/ошибки/латентность по контроллерам (v2 и legacy v1), спаны `Api::V2::NotificationsController` с атрибутами `app.notification_grouping.*` и события `rack_attack`

#### Scenario: Диагностика компонента Sidekiq Background Engine
- **WHEN** открыт дашборд компонента `Sidekiq`
- **THEN** в системном блоке отображаются память и GC процесса (`Process{type="sidekiq"}`), занятость потоков (`SidekiqProcess`) и пул `ActiveRecord{type="sidekiq"}`, а в прикладном блоке — размер и латентность каждой очереди (`SidekiqQueue` через `max by (queue)`), глобальные счетчики `SidekiqStats` через `max`, а также пропускная способность и ошибки воркеров через `sum by (job_class) (rate(...))` (`LocalNotificationWorker`, `UnfilterNotificationsWorker`, `ThreadResolveWorker`, `Web::PushNotificationWorker`, `NotificationMailer`)

---

### Requirement: Глубокая диагностика компонента Node.js Streaming
Дашборд компонента `Node.js Streaming` SHALL использовать фактические метрики эндпоинта `/metrics` процесса стриминга, разделяя системные показатели Node.js/PG-пула и метрики каналов реального времени.

#### Scenario: Диагностика компонента Node.js Streaming
- **WHEN** открыт дашборд компонента `Node.js Streaming`
- **THEN** в системном блоке отображаются метрики рантайма из `collectDefaultMetrics()` (event loop lag, V8 heap, RSS, CPU, открытые дескрипторы) и состояния пула базы данных (`pg_pool_total_connections`, `pg_pool_idle_connections`, `pg_pool_waiting_queries`), а в прикладном блоке — `connected_clients`, распределение подписок по каналам `sum by (channel) (connected_channels)` (с учетом правила инкремента на `2` для канала `system`), `redis_subscriptions`, скорость `redis_messages_received_total` и `messages_sent_total` по типам `websocket` и `eventsource`

---

### Requirement: Глубокая диагностика компонента PostgreSQL и таблиц оптимизации уведомлений
Дашборд компонента `PostgreSQL` SHALL отображать состояние буферного кэша, блокировок, MVCC и дискового пространства в системном блоке, а также статистику SQL-запросов и целевых таблиц оптимизаций `ADR-1..3` в прикладном блоке.

#### Scenario: Диагностика компонента PostgreSQL и эффектов ADR-1..3
- **WHEN** открыт дашборд компонента `PostgreSQL`
- **THEN** в системном блоке отображаются соотношение `shared_blks_hit` и `shared_blks_read` (с защитой от деления на ноль через `NULLIF`), активные ожидания блокировок (`pg_locks` / `pg_stat_activity`), показатели `n_dead_tup` / `autovacuum` и объем хранения (`PgHero.capture_space_stats` / `SpaceUsageDimension`), а в прикладном блоке — топ запросов из `pg_stat_statements` с привязкой к `sidekiq_job_class`, безопасный расчет доли `HOT update` (`n_tup_hot_upd / NULLIF(n_tup_upd, 0)`) и индексных сканирований для `notification_groups`, `notifications` и `dm_thread_permissions`
