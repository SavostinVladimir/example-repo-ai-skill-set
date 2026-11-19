#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# new-worker.sh <feature-name>
#
# 1. Creates a git worktree INSIDE mastodon/worktrees/ named w-<feature-name>
#    Path: <mastodon-dir>/worktrees/w-<feature-name>
# 2. Places an agent rules file (AGENTS.md and GEMINI.md) in the new worktree:
#    - Agent works ONLY in this worktree (exact path)
#    - Logical commit organization for clear reading and review
#    - Test environment isolation (avoid collisions with other agents)
#    - Uses <feature-name> as prefix for artifacts and launched applications
# ==============================================================================

if [ -z "${1:-}" ]; then
  echo "Ошибка: Не указано имя фичи (feature-name)." >&2
  echo "Использование: $0 <feature-name>" >&2
  echo "Пример: $0 auth-oauth2" >&2
  exit 1
fi

RAW_FEATURE="$1"
# Remove leading 'w-' if the user inadvertently included it
FEATURE_NAME="${RAW_FEATURE#w-}"

# Sanitize feature name (lowercase, replace spaces/special chars with hyphens)
FEATURE_NAME="$(echo "${FEATURE_NAME}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g' | sed -E 's/^-+|-+$//g')"

if [ -z "${FEATURE_NAME}" ]; then
  echo "Ошибка: Некорректное имя фичи '${RAW_FEATURE}'." >&2
  exit 1
fi

WORKTREE_NAME="w-${FEATURE_NAME}"

# Locate the Mastodon repository
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CANDIDATE_ROOTS=(
  "$(pwd)"
  "$(cd "${SKILL_ROOT}/../../.." && pwd)"
)

MASTODON_DIR=""

for candidate in "${CANDIDATE_ROOTS[@]}"; do
  if [ -d "${candidate}/mastodon/.git" ] || [ -f "${candidate}/mastodon/.git" ]; then
    MASTODON_DIR="${candidate}/mastodon"
    break
  elif [ -d "${candidate}/.git" ] || [ -f "${candidate}/.git" ]; then
    if [ "$(basename "${candidate}")" = "mastodon" ]; then
      MASTODON_DIR="${candidate}"
      break
    fi
  fi
done

if [ -z "${MASTODON_DIR}" ] || [ ! -d "${MASTODON_DIR}" ]; then
  echo "Ошибка: Не удалось найти репозиторий mastodon." >&2
  echo "Проверены пути: ${CANDIDATE_ROOTS[*]}" >&2
  exit 1
fi

# Worktree is located inside mastodon/worktrees/
WORKTREES_BASE_DIR="${MASTODON_DIR}/worktrees"
mkdir -p "${WORKTREES_BASE_DIR}"
WORKTREE_PATH="${WORKTREES_BASE_DIR}/${WORKTREE_NAME}"

# Ensure worktrees/ is excluded in mastodon git so worktrees are not treated as untracked files
EXCLUDE_FILE="${MASTODON_DIR}/.git/info/exclude"
if [ -f "${EXCLUDE_FILE}" ]; then
  if ! grep -qxF "worktrees/" "${EXCLUDE_FILE}" 2>/dev/null; then
    echo "worktrees/" >> "${EXCLUDE_FILE}"
  fi
fi

echo "=================================================="
echo "🚀 Создание нового worker-окружения для: ${FEATURE_NAME}"
echo "📁 Репозиторий Mastodon : ${MASTODON_DIR}"
echo "🌿 Ветка worktree       : ${WORKTREE_NAME}"
echo "📂 Путь к worktree      : ${WORKTREE_PATH}"
echo "=================================================="

# Check if worktree directory already exists
if [ -d "${WORKTREE_PATH}" ]; then
  echo "Предупреждение: Директория '${WORKTREE_PATH}' уже существует."
  echo "Проверяем наличие зарегистрированного worktree..."
  if git -C "${MASTODON_DIR}" worktree list | grep -F "${WORKTREE_PATH}" >/dev/null 2>&1; then
    echo "Worktree уже зарегистрирован в git."
  else
    echo "Ошибка: Директория существует, но не зарегистрирована как worktree." >&2
    exit 1
  fi
else
  # Check if branch already exists
  if git -C "${MASTODON_DIR}" rev-parse --verify --quiet "${WORKTREE_NAME}" >/dev/null 2>&1; then
    echo "Ветка '${WORKTREE_NAME}' уже существует. Подключаем существующую ветку..."
    git -C "${MASTODON_DIR}" worktree add "${WORKTREE_PATH}" "${WORKTREE_NAME}"
  else
    echo "Создаем новую ветку '${WORKTREE_NAME}' и подключаем worktree..."
    git -C "${MASTODON_DIR}" worktree add -b "${WORKTREE_NAME}" "${WORKTREE_PATH}" HEAD
  fi
fi

# ==============================================================================
# Генерация файла правил для агентов (AGENTS.md и GEMINI.md)
# ==============================================================================
RULES_CONTENT=$(cat <<EOF
# Правила и ограничения для агента (Фича: ${FEATURE_NAME})

## 1. Строгая рабочая директория (Strict Working Directory)
- **Точный разрешенный путь**: \`${WORKTREE_PATH}\`
- Агент имеет право читать, изменять, создавать файлы и выполнять команды **ИСКЛЮЧИТЕЛЬНО** внутри этой рабочей директории:
  \`${WORKTREE_PATH}\`
- **СТРОГО ЗАПРЕЩЕНО**: обращаться к родительскому репозиторию (\`${MASTODON_DIR}\`), соседним ворктри (\`../w-*\` или \`worktrees/*\`) или каталогам выше. Вся деятельность, создание файлов и запуск команд должны быть строго изолированы в границах данного worktree.

## 2. Организация коммитов (Commit Discipline & Code Review)
- Организовывать коммиты логично, атомарно и структурированно для удобного чтения и код-ревью:
  - Один коммит — одно логическое изменение или этап задачи.
  - Использовать понятные сообщения коммитов в стиле Conventional Commits (\`feat: ...\`, \`fix: ...\`, \`refactor: ...\`, \`test: ...\`, \`docs: ...\`).
  - Разделять рефакторинг/форматирование и изменения функциональности на разные коммиты.
  - Порядок коммитов должен отражать последовательную эволюцию решения для комфортной проверки ревьюером.
  - Запрещено коммитить временные файлы, дампы отладки, логи тестов, артефакты сборки и секреты.

## 3. Изоляция тестового окружения (Test Environment Isolation)
- **Полная изоляция от других агентов**: одновременно на машине могут работать другие агенты над другими фичами. Запуск тестов и сервисов должен исключать любые конфликты ресурсов.
- **База данных**:
  - Запрещено использовать стандартные базы \`mastodon_test\` или \`mastodon_development\`.
  - Все тестовые базы данных должны иметь префикс или имя: \`mastodon_test_${FEATURE_NAME}\` (или \`${FEATURE_NAME}_test\`).
- **Сетевые порты**:
  - Не использовать дефолтные порты (Rails/Puma: 3000, Vite: 5173/3035, Streaming: 4000, Postgres: 5432, Redis: 6379).
  - При запуске локальных серверов/сервисов выделять уникальные свободные порты (например, со смещением или свободный динамический порт) с указанием переменных окружения \`PORT\`, \`STREAMING_CLUSTER_NUM\`, и т.д.
- **Redis и кэш**:
  - Использовать отдельный номер базы данных Redis либо ключ-пространство с префиксом \`${FEATURE_NAME}\`.
- **Временные файлы**:
  - В качестве \`TMPDIR\` использовать локальную поддиректорию внутри ворктри (например, \`${WORKTREE_PATH}/tmp\`) либо \`/tmp/${FEATURE_NAME}-tmp\`.

## 4. Префиксы артефактов и запущенных приложений (Prefixing)
- **Обязательный префикс**: Использовать значение \`${FEATURE_NAME}\` в качестве префикса для всех создаваемых артефактов и запущенных процессов:
  - **Docker Compose**: Использовать проектное имя \`COMPOSE_PROJECT_NAME=${FEATURE_NAME}\` (или ключ \`-p ${FEATURE_NAME}\`), чтобы контейнеры, сети и тома не пересекались с другими проектами:
    - Контейнеры: \`${FEATURE_NAME}-web\`, \`${FEATURE_NAME}-db\`, \`${FEATURE_NAME}-redis\`, \`${FEATURE_NAME}-streaming\`, \`${FEATURE_NAME}-sidekiq\`
  - **Запущенные процессы и сокеты**: Все фоновые службы, PID-файлы и unix-сокеты должны именоваться с префиксом \`${FEATURE_NAME}\` (например, \`/tmp/${FEATURE_NAME}-puma.sock\`, \`${WORKTREE_PATH}/tmp/pids/${FEATURE_NAME}-puma.pid\`).
  - **Артефакты тестов и сборки**: Файлы логов, отчетов покрытия кода (coverage), скриншоты тестов и временные дампы именовать с префиксом \`${FEATURE_NAME}\` (например, \`${FEATURE_NAME}-rspec.log\`, \`${FEATURE_NAME}-coverage/\`, \`${FEATURE_NAME}-test-results.xml\`).
EOF
)

echo "Записываем файл правил AGENTS.md..."
echo "${RULES_CONTENT}" > "${WORKTREE_PATH}/AGENTS.md"

echo "Записываем файл правил GEMINI.md..."
echo "${RULES_CONTENT}" > "${WORKTREE_PATH}/GEMINI.md"

echo ""
echo "✅ Успешно создано рабочее окружение!"
echo "--------------------------------------------------"
echo "📍 Рабочая директория (Worktree): ${WORKTREE_PATH}"
echo "🌿 Git ветка                    : ${WORKTREE_NAME}"
echo "📝 Файлы правил агента          : ${WORKTREE_PATH}/AGENTS.md"
echo "                                  ${WORKTREE_PATH}/GEMINI.md"
echo "🔖 Префикс для тестов и служб   : ${FEATURE_NAME}"
echo "--------------------------------------------------"
echo "Чтобы начать работу в новом окружении:"
echo "  cd \"${WORKTREE_PATH}\""
echo "=================================================="
