"""SQLite migration helpers for Memory Core."""

from __future__ import annotations

from pathlib import Path
import sqlite3

MIGRATION_VERSION = 3
MIGRATION_NAME = "003_reinforcement_updates"
MIGRATIONS = (
    (1, "001_initial_memory_core", "001_initial_memory_core.sql"),
    (2, "002_priority_ingest_and_promotion", "002_priority_ingest_and_promotion.sql"),
    (3, "003_reinforcement_updates", "003_reinforcement_updates.sql"),
)


def migrations_dir() -> Path:
    return Path(__file__).resolve().parents[2] / "migrations"


def apply_migrations(connection: sqlite3.Connection) -> None:
    for version, name, filename in MIGRATIONS:
        if get_schema_version(connection) >= version:
            continue
        connection.executescript((migrations_dir() / filename).read_text(encoding="utf-8"))
        connection.execute(
            "INSERT OR IGNORE INTO schema_version(version, name) VALUES (?, ?)",
            (version, name),
        )
        connection.commit()


def get_schema_version(connection: sqlite3.Connection) -> int:
    try:
        row = connection.execute("SELECT MAX(version) AS version FROM schema_version").fetchone()
    except sqlite3.OperationalError:
        return 0
    if row is None or row[0] is None:
        return 0
    return int(row[0])
