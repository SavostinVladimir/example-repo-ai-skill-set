## 1. Конфигурация источников метрик и экспортеров

- [x] 1.1 Создать директорию `monitoring/dashboards/` для хранения JSON-моделей дашбордов Grafana (schema v10+)
- [x] 1.2 Сконфигурировать запуск коллектора `./bin/prometheus_exporter` (`PROMETHEUS_EXPORTER_HOST`/`PORT`) и переменные окружения для `Puma` и `Sidekiq` (`MASTODON_PROMETHEUS_EXPORTER_ENABLED=true`, профили `WEB_DETAILED_METRICS` и `SIDEKIQ_DETAILED_METRICS`, исключая `LOCAL=true` в кластерном режиме `Puma`)
- [x] 1.3 Настроить сбор метрик `Node.js Streaming` с эндпоинта `GET /metrics` (с учетом фактических имен из `streaming/metrics.js` без префикса `mastodon_streaming_`) и экспорт трассировок `OpenTelemetry` (`OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_SERVICE_NAME_PREFIX`)
- [x] 1.4 Включить и проверить доступность расширений и представлений PostgreSQL (`pg_stat_statements`, `pg_statio_user_tables`, `pg_stat_user_tables`, `pg_locks`), регулярный запуск `Scheduler::PgheroScheduler` и передачу тега `sidekiq_job_class` через `Mastodon::SidekiqMiddleware`
- [x] 1.5 Настроить сбор прикладных Redis-метрик (`ActivityTracker`, `FeatureUsageTracker`, `DeliveryFailureTracker`, `Admin::Metrics::Dimension::SpaceUsageDimension`), событий `rack_attack` и метрик стенда `k6` / Mock WebPush / SMTP

## 2. Реализация Дашборда 1: Дашборд пользовательских путей (`monitoring/dashboards/user_journeys.json`)

- [x] 2.1 Реализовать секцию пути «Социальное действие и Optimistic UI»: графики RPS, HTTP latency (P99 относительно 50 мс) и ошибок `4xx`/`5xx`/`429` (`PrometheusExporter::Middleware`, `PrometheusQueueTime`, события `rack_attack`), а также счетчики `ActivityTracker` (`activity:interactions`, `activity:statuses:local`) и `FeatureUsageTracker`
- [x] 2.2 Реализовать секцию пути «Чтение и группировка ленты API v2 и v1»: панели `p50`/`p95`/`p99` для `Api::V2::NotificationsController` (`index`, `unread_count`, `show`), legacy `Api::V1::NotificationsController` (`index`) и `MarkersController` в разрезе когорт (`Селебрити` vs `Активные читатели`), декомпозицию спанов `MastodonOTELTracer` (`#load_notifications`, `#load_grouped_notifications`, `#index rendering`) и атрибуты `app.notification_grouping.*`
- [x] 2.3 Реализовать секцию пути «Сквозная доставка и фильтрация DM»: панели `E2E WebSocket Latency` из `k6`, задержек и длительности `LocalNotificationWorker` и `UnfilterNotificationsWorker`, потока доставки `streaming` (`messages_sent_total`), очередей `push`/`mailers` и счетчиков Mock WebPush/SMTP
- [x] 2.4 Реализовать секцию пути «Мутации, удаление популярных статусов и очистка ленты»: панели ошибок и задержек `unfavourite`, `PUT /api/v1/statuses/:id`, `DELETE /api/v1/statuses/:id`, `clear`/`dismiss` в связке с длительностью `RemoveStatusService`/`BatchedRemoveStatusService` и ожиданиями блокировок в PostgreSQL
- [x] 2.5 Сформировать итоговый артефакт `monitoring/dashboards/user_journeys.json` и валидировать синтаксис JSON

## 3. Реализация Дашборда 2: Дашборд обзора всех компонентов системы (`monitoring/dashboards/components_overview.json`)

- [x] 3.1 Реализовать статусную строку мета-мониторинга доступности scrape-таргетов `up{job=~"puma|sidekiq|streaming|postgres"}`
- [x] 3.2 Реализовать сквозные RED-панели для `Puma Web/API`, `Sidekiq Notification Engine`, `Node.js Streaming` и `Outbound Push/Email Gateway` (`queue: 'push'`, `queue: 'mailers'`, `DeliveryFailureTracker`)
- [x] 3.3 Реализовать USE-панели насыщения ресурсов: потоки Puma (`backlog`, `running_threads`), очереди Sidekiq (`default`, `push`, `ingress`, `mailers`, `pull`, `scheduler`, `fasp`) с обязательной агрегацией `max by (queue)`, суммарный RPS воркеров через `sum by (job_class) (rate(...))`, память Redis (`used_memory`), пулы соединений БД (Puma + Sidekiq + Streaming `pg_pool_*`) и буферный кэш PostgreSQL
- [x] 3.4 Добавить блок контроля валидности нагрузки тестового стенда (`k6` CPU utilization и `dropped_iterations`)
- [x] 3.5 Сформировать итоговый артефакт `monitoring/dashboards/components_overview.json` и валидировать синтаксис JSON

## 4. Реализация Дашборда 3: Дашборд индивидуального компонента (`monitoring/dashboards/component_deep_dive.json`)

- [x] 4.1 Реализовать параметризацию дашборда по переменной `$component` (`puma`, `sidekiq`, `streaming`, `postgres`) с визуальным разделением на верхний блок «Системные метрики» и нижний блок «Метрики приложения»
- [x] 4.2 Настроить представление **Puma Web Server**: блок системных метрик (`Process{type="puma"}`, `Instrumentation::Puma`, `ActiveRecord{type="puma"}`) и блок метрик приложения (`PrometheusQueueTime`, контроллеры/статусы/тайминги, спаны `Api::V2::NotificationsController`, `rack_attack`)
- [x] 4.3 Настроить представление **Sidekiq Engine**: блок системных метрик (`Process{type="sidekiq"}`, `SidekiqProcess`, `ActiveRecord{type="sidekiq"}`) и блок метрик приложения (гейджи очередей `SidekiqQueue` через `max by (queue)`, счетчики `SidekiqStats` через `max`, пропускная способность и ошибки воркеров строго через `sum by (job_class) (rate(...))`)
- [x] 4.4 Настроить представление **Node.js Streaming**: блок системных метрик (`collectDefaultMetrics()` — event loop lag, heap/RSS, CPU, FDs; `pg_pool_total_connections`, `pg_pool_idle_connections`, `pg_pool_waiting_queries`) и блок метрик приложения (`connected_clients`, распределение подписок `sum by (channel) (connected_channels)`, `redis_subscriptions`, `redis_messages_received_total`, `messages_sent_total`)
- [x] 4.5 Настроить представление **PostgreSQL & PgHero**: блок системных метрик (`shared_blks_hit / NULLIF(shared_blks_hit + shared_blks_read, 0)`, `pg_locks`, `n_dead_tup`, `autovacuum_count`, `PgHero.capture_space_stats`) и блок метрик приложения (топ запросов `pg_stat_statements` с привязкой к `sidekiq_job_class`, безопасная доля HOT update `n_tup_hot_upd / NULLIF(n_tup_upd, 0)` и индексные сканирования для `notification_groups`, `notifications`, `dm_thread_permissions`)
- [x] 4.6 Сформировать итоговый артефакт `monitoring/dashboards/component_deep_dive.json` и валидировать синтаксис JSON

## 5. Верификация дашбордов на нагрузочном стенде

- [x] 5.1 Проверить отсутствие искажения метрик Sidekiq (проверить работу `max by (queue)` для очередей и `sum by (job_class)` для задач воркеров) и корректность сопоставления имен метрик `Node.js Streaming` при одновременном запуске нескольких процессов
- [x] 5.2 Провести контрольную проверку читаемости и срабатывания индикаторов всех трех дашбордов на прогонах `As-Is` и `To-Be` (Baseline, Viral Spike & Massacre, Breakpoint Ramp-Up) и зафиксировать подтверждение эффекта оптимизаций `ADR-1..3`
