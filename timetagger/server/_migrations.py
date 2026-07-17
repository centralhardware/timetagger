"""
Centralized database migrations for TimeTagger.

The schema is defined by numbered SQL files in the ``migrations`` package
(``0001_init.sql``, ``0002_....sql``, ...). At startup ``migrate()`` applies
every migration that has not been applied yet, in order, and records it in the
``schema_migrations`` table. Each migration runs in its own transaction.

This is the single source of truth for the schema: the rest of the server code
assumes the tables already exist and never issues DDL.
"""

import logging
from importlib import resources

from ._pg import get_pool

logger = logging.getLogger("asgineer")

_MIGRATIONS_PKG = "timetagger.server.migrations"


def _load_migrations():
    """Return a sorted list of ``(version, name, sql)`` migration tuples."""
    migrations = []
    for entry in resources.files(_MIGRATIONS_PKG).iterdir():
        name = entry.name
        if not name.endswith(".sql"):
            continue
        try:
            version = int(name.split("_", 1)[0])
        except ValueError:
            raise ValueError(f"Migration file {name!r} must start with a number.")
        migrations.append((version, name, entry.read_text(encoding="utf-8")))
    migrations.sort(key=lambda m: m[0])
    return migrations


async def migrate():
    """Apply all pending migrations. Safe to call repeatedly."""
    pool = await get_pool()
    async with pool.acquire() as conn:
        await conn.execute(
            "CREATE TABLE IF NOT EXISTS schema_migrations ("
            "version integer PRIMARY KEY, "
            "applied_at timestamptz NOT NULL DEFAULT now())"
        )
        applied = {
            row["version"]
            for row in await conn.fetch("SELECT version FROM schema_migrations")
        }
        for version, name, sql in _load_migrations():
            if version in applied:
                continue
            async with conn.transaction():
                await conn.execute(sql)
                await conn.execute(
                    "INSERT INTO schema_migrations (version) VALUES ($1)", version
                )
            logger.info(f"Applied database migration {name}")
