---
name: new-worker
description: >-
  Creates an isolated Git worktree inside the Mastodon directory named mastodon/worktrees/w-<feature-name>
  and configures an agent rules file (AGENTS.md) with exact path isolation, commit hygiene standards,
  isolated test environment rules, and resource prefixing. Use whenever the user asks to create a new worker,
  spawn a worktree for a feature (e.g. "new-worker <feature-name>"), or prepare an isolated workspace
  for an agent inside mastodon.
---

# New Worker Skill (`new-worker <feature-name>`)

Этот скилл создает изолированное рабочее дерево (Git worktree) **внутри папки `mastodon/worktrees/`** для параллельной или изолированной работы агента над отдельной функциональностью (`<feature-name>`), а также генерирует файлы правил для агента (`AGENTS.md` и `GEMINI.md`).

---

## Что делает скилл

1. **Создает Git worktree в `mastodon/worktrees/`**:
   - Ветка: `w-<feature-name>`
   - Каталог worktree: `/Users/freemike/Projects/mast/mastodon/worktrees/w-<feature-name>`.
   - Исключение из git: автоматически добавляет `worktrees/` в `.git/info/exclude`, чтобы ворктри не отображались как untracked files в основном репозитории `mastodon`.
   - Команда:
     ```bash
     git -C /Users/freemike/Projects/mast/mastodon worktree add -b w-<feature-name> /Users/freemike/Projects/mast/mastodon/worktrees/w-<feature-name> HEAD
     ```

2. **Создает файлы правил для агента (`AGENTS.md` и `GEMINI.md`)**:
   - **Точный путь**: Фиксирует точный абсолютный путь `/Users/freemike/Projects/mast/mastodon/worktrees/w-<feature-name>` как единственную разрешенную рабочую область для агента. Агенту строго запрещено выходить за пределы своего worktree или модифицировать родительский репозиторий `mastodon`.
   - **Организация коммитов**: Требование структурировать коммиты логично, атомарно и понятно для последующего чтения и код-ревью (Conventional Commits, разделение рефакторинга и функциональных изменений).
   - **Изоляция тестового окружения**: Запуск тестовых сред и баз данных без пересечений с другими агентами (уникальные порты, изолированная тестовая БД).
   - **Префикс артефактов и приложений**: Значение `<feature-name>` подставляется в качестве обязательного префикса для:
     - `COMPOSE_PROJECT_NAME=<feature-name>`
     - Запущенных сервисов/контейнеров (`<feature-name>-web`, `<feature-name>-db`, `<feature-name>-redis`, `<feature-name>-streaming`)
     - Баз данных (`mastodon_test_<feature-name>`)
     - Артефактов тестов, логов и отчетов (`<feature-name>-*.log`, `<feature-name>-coverage/`).

---

## Способы выполнения

### Способ 1: Запуск встроенного скрипта (Рекомендуемый)

Скилл включает автоматизированный исполняемый скрипт [new-worker.sh](./scripts/new-worker.sh):

```bash
/Users/freemike/Projects/mast/.agents/skills/new-worker/scripts/new-worker.sh <feature-name>
```

Скрипт автоматически:
- Валидирует и нормализует имя `<feature-name>`.
- Находит репозиторий `mastodon`.
- Добавляет `worktrees/` в `.git/info/exclude`.
- Создает каталог `mastodon/worktrees/` при необходимости.
- Создает git worktree с веткой `w-<feature-name>` по пути `mastodon/worktrees/w-<feature-name>`.
- Генерирует `AGENTS.md` и `GEMINI.md` с точными подставленными путями и префиксами.

---

### Способ 2: Пошаговое выполнение агентом

Если запуск скрипта невозможен или требуется ручное выполнение:

#### Шаг 1: Нормализация имени фичи
Извлеките `<feature-name>`, очистите от префикса `w-` (если пользователь передал `w-auth` -> `auth`) и приведите к безопасному виду (строчные буквы, дефисы):
```bash
FEATURE_NAME="<feature-name>"
WORKTREE_NAME="w-${FEATURE_NAME}"
MASTODON_DIR="/Users/freemike/Projects/mast/mastodon"
WORKTREES_BASE_DIR="${MASTODON_DIR}/worktrees"
WORKTREE_PATH="${WORKTREES_BASE_DIR}/${WORKTREE_NAME}"
```

#### Шаг 2: Обеспечение исключения из Git и создание каталога
```bash
mkdir -p "${WORKTREES_BASE_DIR}"
grep -qxF "worktrees/" "${MASTODON_DIR}/.git/info/exclude" || echo "worktrees/" >> "${MASTODON_DIR}/.git/info/exclude"
```

#### Шаг 3: Создание Git Worktree
```bash
# Если ветка еще не существует:
git -C "${MASTODON_DIR}" worktree add -b "${WORKTREE_NAME}" "${WORKTREE_PATH}" HEAD

# Если ветка уже существует:
git -C "${MASTODON_DIR}" worktree add "${WORKTREE_PATH}" "${WORKTREE_NAME}"
```

#### Шаг 4: Запись файла правил `AGENTS.md` и `GEMINI.md`
Запишите следующий контент в `${WORKTREE_PATH}/AGENTS.md` и `${WORKTREE_PATH}/GEMINI.md`:

```markdown
# Правила и ограничения для агента (Фича: <feature-name>)

## 1. Строгая рабочая директория (Strict Working Directory)
- **Точный разрешенный путь**: `/Users/freemike/Projects/mast/mastodon/worktrees/w-<feature-name>`
- Агент имеет право читать, изменять, создавать файлы и выполнять команды **ИСКЛЮЧИТЕЛЬНО** внутри этой рабочей директории:
  `/Users/freemike/Projects/mast/mastodon/worktrees/w-<feature-name>`
- **СТРОГО ЗАПРЕЩЕНО**: обращаться к родительскому репозиторию (`/Users/freemike/Projects/mast/mastodon`), соседним ворктри (`../w-*` или `worktrees/*`) или каталогам выше. Вся деятельность должна быть строго изолирована в границах данного worktree.

## 2. Организация коммитов (Commit Discipline & Code Review)
- Организовывать коммиты логично, атомарно и структурированно для удобного чтения и код-ревью:
  - Один коммит — одно логическое изменение или этап задачи.
  - Использовать понятные сообщения коммитов в стиле Conventional Commits (`feat: ...`, `fix: ...`, `refactor: ...`, `test: ...`, `docs: ...`).
  - Разделять рефакторинг/форматирование и изменения функциональности на разные коммиты.
  - Порядок коммитов должен отражать последовательную эволюцию решения для комфортной проверки ревьюером.
  - Запрещено коммитить временные файлы, дампы отладки, логи тестов, артефакты сборки и секреты.

## 3. Изоляция тестового окружения (Test Environment Isolation)
- **Полная изоляция от других агентов**: одновременно на машине могут работать другие агенты над другими фичами. Запуск тестов и сервисов должен исключать любые конфликты ресурсов.
- **База данных**:
  - Запрещено использовать стандартные базы `mastodon_test` или `mastodon_development`.
  - Все тестовые базы данных должны иметь префикс или имя: `mastodon_test_<feature-name>`.
- **Сетевые порты**:
  - Не использовать дефолтные порты (Rails/Puma: 3000, Vite: 5173/3035, Streaming: 4000, Postgres: 5432, Redis: 6379).
  - При запуске локальных серверов/сервисов выделять уникальные свободные порты с указанием переменных окружения `PORT`, `STREAMING_CLUSTER_NUM`, и т.д.
- **Redis и кэш**:
  - Использовать отдельный номер базы данных Redis либо ключ-пространство с префиксом `<feature-name>`.
- **Временные файлы**:
  - В качестве `TMPDIR` использовать локальную поддиректорию внутри ворктри (например, `/Users/freemike/Projects/mast/mastodon/worktrees/w-<feature-name>/tmp`) либо `/tmp/<feature-name>-tmp`.

## 4. Префиксы артефактов и запущенных приложений (Prefixing)
- **Обязательный префикс**: Использовать значение `<feature-name>` в качестве префикса для всех создаваемых артефактов и запущенных процессов:
  - **Docker Compose**: Использовать проектное имя `COMPOSE_PROJECT_NAME=<feature-name>` (или ключ `-p <feature-name>`), чтобы контейнеры, сети и тома не пересекались с другими проектами:
    - Контейнеры: `<feature-name>-web`, `<feature-name>-db`, `<feature-name>-redis`, `<feature-name>-streaming`, `<feature-name>-sidekiq`
  - **Запущенные процессы и сокеты**: Все фоновые службы, PID-файлы и unix-сокеты должны именоваться с префиксом `<feature-name>` (например, `/tmp/<feature-name>-puma.sock`, `/Users/freemike/Projects/mast/mastodon/worktrees/w-<feature-name>/tmp/pids/<feature-name>-puma.pid`).
  - **Артефакты тестов и сборки**: Файлы логов, отчетов покрытия кода (coverage), скриншоты тестов и временные дампы именовать с префиксом `<feature-name>` (например, `<feature-name>-rspec.log`, `<feature-name>-coverage/`, `<feature-name>-test-results.xml`).
```

*(Обязательно заменить `<feature-name>` на фактическое значение фичи)*.

---

## Шаг 5: Верификация

После создания проверьте:
1. `git -C /Users/freemike/Projects/mast/mastodon worktree list` содержит новый путь внутри `mastodon/worktrees/`.
2. В каталоге `/Users/freemike/Projects/mast/mastodon/worktrees/w-<feature-name>` созданы и заполнены файлы `AGENTS.md` и `GEMINI.md`.
3. Сообщите пользователю точный путь и подсказку для переключения:
   ```bash
   cd /Users/freemike/Projects/mast/mastodon/worktrees/w-<feature-name>
   ```
