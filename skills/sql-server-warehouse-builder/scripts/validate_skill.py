#!/usr/bin/env python3
"""Offline structure/smoke validator for SQL Server Warehouse Builder.

Does NOT parse T-SQL, execute SQL, connect to a database, or guarantee
production readiness. Dependency-free by design (Python stdlib only).
"""
from __future__ import annotations

import pathlib
import re
import sys

NAME_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
LINK_RE = re.compile(r"\[[^\]]+\]\(([^)]+)\)")


def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parents[1]).resolve()
    errors: list[str] = []
    checked = 0

    skill_path = root / "SKILL.md"
    if not skill_path.is_file():
        print("FAIL: SKILL.md missing")
        return 1
    content = skill_path.read_text(encoding="utf-8")
    parts = content.split("---\n", 2)
    if len(parts) < 3 or parts[0] != "":
        errors.append("SKILL.md needs top YAML frontmatter fenced by --- lines")
        front = ""
    else:
        front = parts[1]
    metadata: dict[str, str] = {}
    for line in front.splitlines():
        if not line.strip():
            continue
        if ":" not in line:
            errors.append(f"Malformed frontmatter line: {line}")
            continue
        k, v = line.split(":", 1)
        metadata[k.strip()] = v.strip().strip("'\"")
    checked += 1
    name = metadata.get("name", "")
    desc = metadata.get("description", "")
    if not name or not NAME_RE.fullmatch(name) or len(name) > 64 or name != root.name:
        errors.append("Invalid skill name or directory-name mismatch")
    if not desc or len(desc) > 1024:
        errors.append("Missing or overly long skill description")
    checked += 2

    required = [
        "README.md", "EVALUATION.md", "references/intake-and-modeling.md",
        "references/sql-server-engineering.md", "references/validation-and-testing.md",
        "references/quality-and-delivery.md", "references/cross-project-pitfalls.md",
        "references/query-patterns.md",
        "assets/project-brief.template.md", "assets/fact-ddl.template.sql",
        "assets/fact-loader.template.sql", "assets/scd2-pattern.sql",
        "examples/retail-orders.md", "scripts/validate_skill.py",
    ]
    for rel in required:
        p = root / rel
        if not p.is_file() or not p.read_text(encoding="utf-8").strip():
            errors.append(f"Required package file missing or empty: {rel}")
        checked += 1

    for rel in LINK_RE.findall(content):
        if rel.startswith(("http://", "https://", "#", "mailto:")):
            continue
        target = (root / rel.split("#", 1)[0]).resolve()
        if not target.is_relative_to(root) or not target.exists():
            errors.append(f"Broken/out-of-skill markdown link: {rel}")
        checked += 1

    for rel, needles in {
        "assets/fact-ddl.template.sql": ["CREATE TABLE", "PRIMARY KEY"],
        "assets/fact-loader.template.sql": [
            "CREATE OR ALTER PROCEDURE", "SET XACT_ABORT ON",
            "BEGIN TRANSACTION", "ROLLBACK TRANSACTION", "EXEC dbo.",
        ],
        "assets/scd2-pattern.sql": [
            "CREATE TABLE", "CREATE OR ALTER PROCEDURE", "valid_from",
            "valid_to", "is_current", "version_number", "EXEC dbo.",
        ],
    }.items():
        sql = (root / rel).read_text(encoding="utf-8")
        for needle in needles:
            if needle not in sql:
                errors.append(f"SQL example missing expected pattern '{needle}': {rel}")
            checked += 1

    for needle in ["Full snapshot", "SCD", "financial", "score", "GO"]:
        if needle.lower() not in content.lower():
            errors.append(f"Missing operational concept in SKILL.md: {needle}")
        checked += 1

    if errors:
        print(f"FAIL: {len(errors)} problems in {checked} checks, root={root}")
        for err in errors:
            print(" -", err)
        return 1
    print(f"PASS: {checked} offline structure/smoke checks; root={root}")
    print("NOT TESTED: SQL compilation, SQL Server behavior, database integration, or ETL correctness")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
