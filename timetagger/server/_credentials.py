"""
User credentials stored in PostgreSQL.

This replaces the former approach of listing users and password hashes in
the `TIMETAGGER_CREDENTIALS` environment variable. Credentials now live in a
`credentials` table and are managed via the CLI (see `python -m timetagger
user-add ...`). For a smooth migration, credentials still present in the env
var are seeded into the table on first use (without overwriting existing rows).
"""

import time
import logging

import bcrypt

from ._pg import get_pool, close_pool

logger = logging.getLogger("asgineer")


async def ensure_credentials_table():
    pool = await get_pool()
    async with pool.acquire() as conn:
        await conn.execute(
            "CREATE TABLE IF NOT EXISTS credentials ("
            "username text PRIMARY KEY, "
            "pw_hash text NOT NULL, "
            "mt double precision)"
        )


async def set_password(username, password):
    """Create or update a user with the given plain-text password."""
    username = (username or "").strip()
    if not username:
        raise ValueError("Username must not be empty")
    if not password:
        raise ValueError("Password must not be empty")
    pw_hash = bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()
    await _upsert_hash(username, pw_hash, overwrite=True)


async def _upsert_hash(username, pw_hash, overwrite):
    await ensure_credentials_table()
    pool = await get_pool()
    if overwrite:
        sql = (
            "INSERT INTO credentials (username, pw_hash, mt) VALUES ($1, $2, $3) "
            "ON CONFLICT (username) DO UPDATE SET "
            "pw_hash = EXCLUDED.pw_hash, mt = EXCLUDED.mt"
        )
    else:
        sql = (
            "INSERT INTO credentials (username, pw_hash, mt) VALUES ($1, $2, $3) "
            "ON CONFLICT (username) DO NOTHING"
        )
    async with pool.acquire() as conn:
        await conn.execute(sql, username, pw_hash, time.time())


async def verify_password(username, password):
    """Return True if the username/password combination is valid."""
    username = (username or "").strip()
    if not username or not password:
        return False
    await ensure_credentials_table()
    pool = await get_pool()
    async with pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT pw_hash FROM credentials WHERE username = $1", username
        )
    if not row:
        return False
    try:
        return bcrypt.checkpw(password.encode(), row["pw_hash"].encode())
    except Exception:
        return False


async def delete_user(username):
    """Remove a user. Returns True if a user was removed."""
    await ensure_credentials_table()
    pool = await get_pool()
    async with pool.acquire() as conn:
        res = await conn.execute(
            "DELETE FROM credentials WHERE username = $1", (username or "").strip()
        )
    return res.upper().endswith(" 1")


async def list_users():
    """Return a sorted list of usernames."""
    await ensure_credentials_table()
    pool = await get_pool()
    async with pool.acquire() as conn:
        rows = await conn.fetch("SELECT username FROM credentials ORDER BY username")
    return [r["username"] for r in rows]


async def seed_from_env_credentials(credentials_str):
    """Seed pre-hashed credentials from the (legacy) env var into the table.

    The format is "user1:hash1,user2:hash2" where each hash is a bcrypt hash.
    Existing rows are never overwritten, so DB edits always win.
    """
    for part in (credentials_str or "").replace(";", ",").split(","):
        part = part.strip()
        if not part:
            continue
        name, _, pw_hash = part.partition(":")
        name, pw_hash = name.strip(), pw_hash.strip()
        if name and pw_hash:
            try:
                await _upsert_hash(name, pw_hash, overwrite=False)
            except Exception as err:
                logger.warning(f"Could not seed credential for {name!r}: {err}")


async def close():
    """Close the shared connection pool (for CLI use)."""
    await close_pool()
