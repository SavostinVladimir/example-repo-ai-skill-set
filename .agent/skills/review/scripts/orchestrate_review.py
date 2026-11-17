#!/usr/bin/env python3
"""
Orchestration and aggregation helper for the multi-agent code & spec review skill.
Scans reviewers/ directory, collects scope, priorities findings, and prepares data for final triage.
"""

import os
import sys
import json
import glob
import re

SEVERITY_ORDER = {
    "BLOCKER": 1,
    "CRITICAL": 2,
    "MAJOR": 3,
    "MINOR": 4,
    "INFO": 5,
}

VALID_CATEGORIES = [
    "Реальный новый дефект",
    "уже существовавший старый дефект",
    "сомнительный дефект, требуется валидация",
]

def load_reviewers(reviewers_dir="reviewers"):
    """
    Scans the reviewers directory and returns a dictionary of active reviewer files
    excluding the final triage reviewer.
    """
    if not os.path.exists(reviewers_dir):
        return {}, None

    active_reviewers = {}
    final_reviewer = None

    for fpath in sorted(glob.glob(os.path.join(reviewers_dir, "*.md"))):
        fname = os.path.basename(fpath)
        if fname.lower() in ("readme.md",):
            continue
        if "final" in fname.lower() or "triage" in fname.lower():
            with open(fpath, "r", encoding="utf-8") as f:
                final_reviewer = {
                    "path": fpath,
                    "filename": fname,
                    "content": f.read()
                }
        else:
            with open(fpath, "r", encoding="utf-8") as f:
                content = f.read()
                name_match = re.search(r"^name:\s*([^\n]+)", content, re.MULTILINE)
                role_match = re.search(r"^role:\s*([^\n]+)", content, re.MULTILINE)
                name = name_match.group(1).strip().strip('"\'') if name_match else fname.replace(".md", "")
                role = role_match.group(1).strip().strip('"\'') if role_match else name
                active_reviewers[name] = {
                    "path": fpath,
                    "filename": fname,
                    "name": name,
                    "role": role,
                    "content": content
                }

    return active_reviewers, final_reviewer

def sort_findings(findings):
    """
    Sorts findings by severity (Blocker -> Critical -> Major -> Minor -> Info).
    """
    def key_func(item):
        sev = str(item.get("severity", "INFO")).upper()
        return SEVERITY_ORDER.get(sev, 99)

    return sorted(findings, key=key_func)

def load_known_gaps(filepath="known-review-gaps.md"):
    """Loads known false positives and review gaps if the file exists."""
    if os.path.exists(filepath):
        with open(filepath, "r", encoding="utf-8") as f:
            return f.read().strip()
    return ""

def format_intermediate_report(findings):
    """
    Formats the intermediate aggregated findings report into Markdown.
    """
    sorted_items = sort_findings(findings)
    lines = []
    lines.append("# Промежуточный сводный отчет находок ревью\n")
    lines.append(f"Всего выявлено замечаний: **{len(sorted_items)}**\n")
    lines.append("| ID | Критичность | Ревьювер | Файл:Строки | Название |")
    lines.append("|---|---|---|---|---|")

    for item in sorted_items:
        fid = item.get("id", "N/A")
        sev = item.get("severity", "Info")
        reviewer = item.get("reviewer", "General")
        loc = f"`{item.get('file', 'N/A')}:{item.get('lines', '')}`"
        title = item.get("title", "")
        lines.append(f"| {fid} | **{sev}** | {reviewer} | {loc} | {title} |")

    lines.append("\n## Детализация находок\n")
    for item in sorted_items:
        lines.append(f"### [{item.get('id', 'N/A')}] {item.get('title', '')}")
        lines.append(f"- **Критичность**: `{item.get('severity', 'Info')}`")
        lines.append(f"- **Ревьювер**: {item.get('reviewer', 'General')}")
        lines.append(f"- **Локация**: `{item.get('file', 'N/A')}:{item.get('lines', '')}`")
        lines.append(f"- **Описание**: {item.get('description', '')}")
        lines.append(f"- **Влияние (Impact)**: {item.get('impact', '')}")
        if item.get("evidence"):
            lines.append(f"- **Факты (Evidence)**:\n```\n{item.get('evidence', '')}\n```")
        lines.append(f"- **Рекомендация**: {item.get('recommendation', '')}")
        lines.append("")

    return "\n".join(lines)

def format_final_report(triaged_findings):
    """
    Formats the final triaged report with classification into Markdown.
    """
    lines = []
    lines.append("# Итоговый отчет ревью с классификацией дефектов\n")

    counts = {
        "new": 0,
        "existing": 0,
        "dubious": 0,
    }

    for item in triaged_findings:
        cat = item.get("classification", "").lower()
        if "новый" in cat or "real" in cat:
            counts["new"] += 1
        elif "старый" in cat or "существовавший" in cat:
            counts["existing"] += 1
        else:
            counts["dubious"] += 1

    lines.append("## Сводная статистика классификации\n")
    lines.append(f"- 🔴 **Реальные новые дефекты**: {counts['new']} (требуют обязательного исправления)")
    lines.append(f"- 🟡 **Уже существовавшие старые дефекты**: {counts['existing']} (выносятся в техдолг)")
    lines.append(f"- ⚪ **Сомнительные дефекты / требуют валидации**: {counts['dubious']} (ложные срабатывания / дискуссионные)")
    lines.append("")

    lines.append("## Таблица классификации находок\n")
    lines.append("| ID | Исходная важность | Классификация | Файл | Вердикт / Действие |")
    lines.append("|---|---|---|---|---|")

    for item in triaged_findings:
        fid = item.get("id", "N/A")
        sev = item.get("severity", "Info")
        cat = item.get("classification", "Требуется валидация")
        fpath = f"`{item.get('file', 'N/A')}:{item.get('lines', '')}`"
        action = item.get("action", item.get("verdict", ""))
        lines.append(f"| {fid} | {sev} | **{cat}** | {fpath} | {action} |")

    lines.append("\n## Детальный разбор находок по категориям\n")

    # Group by category
    categories_map = [
        ("🔴 Реальные новые дефекты (Блокируют мерж)", lambda c: "новый" in c.lower()),
        ("🟡 Уже существовавшие старые дефекты (Техдолг)", lambda c: "старый" in c.lower() or "существовавший" in c.lower()),
        ("⚪ Сомнительные дефекты / Требуется валидация", lambda c: not ("новый" in c.lower() or "старый" in c.lower() or "существовавший" in c.lower()))
    ]

    for cat_title, filter_fn in categories_map:
        group_items = [it for it in triaged_findings if filter_fn(it.get("classification", ""))]
        if not group_items:
            continue
        lines.append(f"### {cat_title}\n")
        for item in group_items:
            lines.append(f"#### [{item.get('id', 'N/A')}] {item.get('title', '')}")
            lines.append(f"- **Локация**: `{item.get('file', 'N/A')}:{item.get('lines', '')}`")
            lines.append(f"- **Первоначальная критичность**: `{item.get('severity', 'Info')}`")
            lines.append(f"- **Обоснование классификации**: {item.get('justification', item.get('description', ''))}")
            lines.append(f"- **Необходимое действие**: {item.get('action', item.get('recommendation', ''))}")
            lines.append("")

    return "\n".join(lines)

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "list":
        active, final = load_reviewers()
        print(json.dumps({
            "active_reviewers": [{ "name": r["name"], "role": r["role"], "file": r["filename"] } for r in active.values()],
            "final_reviewer": final["filename"] if final else None
        }, indent=2, ensure_ascii=False))
    else:
        print("Review orchestration helper loaded.")
