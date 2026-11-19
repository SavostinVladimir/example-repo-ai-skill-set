## Why

В проекте уже реализованы множественные источники телеметрии (`prometheus_exporter` для Puma и Sidekiq, `@prometheus-io/client` в сервере стриминга, трассировка OpenTelemetry с прикладными спанами `MastodonOTELTracer`, статистика PostgreSQL / `PgHero`, Redis-трекеры `ActivityTracker` / `FeatureUsageTracker` / `DeliveryFailureTracker` и стендовые метрики `k6`), однако отсутствует единая система дашбордов для контроля пользовательских SLA конвейера уведомлений и оценки эффекта оптимизаций `ADR-1`, `ADR-2`, `ADR-3`. Создание трехуровневой иерархии дашбордов (пользовательские пути → обзор всех компонентов → индивидуальные компоненты с разделением системных и прикладных метрик) позволит связывать деградацию пользовательского опыта с конкретным звеном конвейера и причиной на уровне рантайма или логики приложения.

## What Changes

- **Формат и размещение артефактов:** Все дашборды специфицируются и создаются в формате декларативных моделей **Grafana Dashboard JSON (schema v10+)** в выделенной директории репозитория `monitoring/dashboards/`:
  - `monitoring/dashboards/user_journeys.json`
  - `monitoring/dashboards/components_overview.json`
  - `monitoring/dashboards/component_deep_dive.json`
- **Дашборд 1 — Дашборд пользовательских путей (`user-journey-dashboard`):** Проектируется сквозной мониторинг ключевых пользовательских сценариев работы с уведомлениями: первичные реакции и гарантии Optimistic UI, чтение и пагинация сгруппированной ленты API v2 (с декомпозицией по когортам, спанам группировки и сохранением видимости legacy-эндпоинта API v1), сквозная доставка в реальном времени и фильтрация глубоких DM-тредов, а также массовые мутации и удаление популярных статусов.
- **Дашборд 2 — Дашборд обзора всех компонентов системы (`system-components-overview-dashboard`):** Проектируется единый экран здоровья и насыщения (RED/USE) всех узлов конвейера (`Puma Web/API`, `Sidekiq Queues & Redis Broker`, `Sidekiq Notification Engine`, `PostgreSQL`, `Node.js Streaming`, `Outbound Push/Email Gateway`) с мета-мониторингом доступности скрап-таргетов (`up{job=...}`) и строгим разграничением агрегации: `max` для гейджей очередей/глобальной статистики и `sum by (class)` для локальных счетчиков воркеров Sidekiq.
- **Дашборд 3 — Дашборд индивидуального компонента (`component-deep-dive-dashboards`):** Проектируются детализированные представления для каждого компонента (`Puma`, `Sidekiq`, `Node.js Streaming`, `PostgreSQL`) со строгим разделением на **системные/рантайм-метрики** (процесс, память/GC, пулы потоков и соединений БД, кэш/I/O, event loop) и **метрики приложения** (тайминги контроллеров/воркеров, спаны и атрибуты группировки уведомлений, очереди и ретраи, каналы и подписки стриминга с раздельной группировкой по `channel`, `pg_stat_statements` и безопасный расчет доли HOT update в таблицах `ADR-1..3`).

## Capabilities

### New Capabilities
- `user-journey-dashboard`: Спецификация дашборда пользовательских путей, отслеживающего SLI/SLO реакций, чтения ленты API v2 (и API v1), доставки в реальном времени / Push / Email и мутаций на основе имеющихся метрик и трассировок проекта.
- `system-components-overview-dashboard`: Спецификация сводного дашборда всех компонентов конвейера с контролем пропускной способности, задержек, ошибок, очередей, пулов соединений, доступности скраперов (`up`) и защитой от искажения многопроцессных метрик.
- `component-deep-dive-dashboards`: Спецификация дашбордов глубокой диагностики индивидуальных компонентов (`Puma`, `Sidekiq`, `Node.js Streaming`, `PostgreSQL`) с явным разделением на системные метрики и метрики приложения.

### Modified Capabilities
<!-- Нет модифицируемых существующих спецификаций в openspec/specs/ -->

## Impact

- **Новые файлы артефактов дашбордов:** `monitoring/dashboards/user_journeys.json`, `monitoring/dashboards/components_overview.json`, `monitoring/dashboards/component_deep_dive.json`.
- **Существующая телеметрия и конфигурация Mastodon:** `mastodon/config/initializers/prometheus_exporter.rb`, `mastodon/config/puma.rb`, `mastodon/config/initializers/sidekiq.rb`, `mastodon/config/initializers/opentelemetry.rb`, `mastodon/lib/mastodon/middleware/prometheus_queue_time.rb`, `mastodon/lib/mastodon/prometheus_exporter/local_server.rb`, `mastodon/streaming/metrics.js`, `mastodon/streaming/index.js`, `mastodon/app/controllers/api/v2/notifications_controller.rb`, `mastodon/app/controllers/api/v1/notifications_controller.rb`, `mastodon/app/lib/activity_tracker.rb`, `mastodon/app/lib/feature_usage_tracker.rb`, `mastodon/app/lib/delivery_failure_tracker.rb`, `mastodon/app/lib/admin/metrics/`, `mastodon/app/workers/scheduler/pghero_scheduler.rb`.
- **Связанные спецификации и решения:** `ADR.md` (`ADR-1`, `ADR-2`, `ADR-3`), `openspec/changes/notification-system-components/`, `openspec/changes/postgres-notification-optimizations/`, `openspec/changes/notification-load-testing/`, `openspec/specs/favourite-interactions/spec.md`.
