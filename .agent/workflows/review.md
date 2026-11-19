---
description: Мультиагентное ревью кода и спецификаций с классификацией дефектов
---

# Мультиагентное ревью кода и спецификаций (/review)

Этот воркфлоу запускает параллельное ревью кода и спецификаций с помощью команды специализированных агентов из папки `reviewers/` с последующей агрегацией, ранжированием и классификацией дефектов финальным триажером.

## Входные данные
Опционально укажите цель ревью (например, `/review mastodon/app/models/notification.rb` или `/review openspec/changes/notification-system-components`). Если цель не указана, будет проверен текущий git diff или активный OpenSpec change.

## Шаги исполнения
1. **Определение скоупа**: собирает измененные файлы кода, спецификаций (`openspec/specs/**`, `openspec/changes/**`), ADR и загружает `known-review-gaps.md`. Определяет наличие спецификаций в скоупе.
2. **Запуск ревьюверов**:
   - *Универсальные ревьюверы (код и спецификации)*:
     - `PostgreSQL & Codebase Reviewer` (`reviewers/postgresql-codebase-reviewer.md`)
     - `User Journey & Spec Compliance Reviewer` (`reviewers/user-journey-spec-compliance-reviewer.md`)
     - `Critical Architecture Adversary (Red Team)` (`reviewers/critical-architecture-adversary.md`)
   - *Ревьюверы спецификаций (запускаются **только** при наличии спецификаций в скоупе)*:
     - `Spec Goal & Alignment Reviewer` (`reviewers/spec-goal.md`)
     - `Spec Abstraction & Anti-Bloat Reviewer` (`reviewers/spec-undetail.md`)
     - `Spec Fact-Checker & Claims Verifier` (`reviewers/spec-claims.md`)
     - `Spec Feasibility & Codebase Compatibility Reviewer` (`reviewers/spec-coder.md`)
     - `Spec AI-Authored Antipatterns Reviewer` (`reviewers/spec-ai-authored.md`)
     - `Task Decomposition & Verifiability Reviewer` (`reviewers/spec-tasks.md`)
3. **Агрегация и приоритезация**: ранжирует все находки от Blocker до Info.
4. **Финальный триаж**: запускает `Final Reviewer & Defect Triage Arbiter` (`reviewers/final-triage-reviewer.md`) для классификации каждой проблемы:
   - 🔴 **Реальный новый дефект**
   - 🟡 **уже существовавший старый дефект**
   - ⚪ **сомнительный дефект, требуется валидация**
5. **Итоговый отчет**: выводит сводную статистику, таблицу и детальный план действий.
