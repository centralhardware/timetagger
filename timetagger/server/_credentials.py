"""
User credentials stored in PostgreSQL.

Credentials live in the ``credentials`` table (created by the migrations, see
``server/_migrations.py``) and are managed via the CLI (see ``python -m
timetagger user-add ...``).
"""

import time
import logging

import bcrypt

from ._pg import get_pool, close_pool

logger = logging.getLogger("asgineer")


async def set_password(username, password):
    """Create or update a user with the given plain-text password."""
    username = (username or "").strip()
    if not username:
        raise ValueError("Username must not be empty")
    if not password:
        raise ValueError("Password must not be empty")
    pw_hash = bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()
    pool = await get_pool()
    sql = (
        "INSERT INTO credentials (username, pw_hash, mt) VALUES ($1, $2, $3) "
        "ON CONFLICT (username) DO UPDATE SET "
        "pw_hash = EXCLUDED.pw_hash, mt = EXCLUDED.mt"
    )
    async with pool.acquire() as conn:
        await conn.execute(sql, username, pw_hash, time.time())


async def verify_password(username, password):
    """Return True if the username/password combination is valid."""
    username = (username or "").strip()
    if not username or not password:
        return False
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
    pool = await get_pool()
    async with pool.acquire() as conn:
        res = await conn.execute(
            "DELETE FROM credentials WHERE username = $1", (username or "").strip()
        )
    return res.upper().endswith(" 1")


async def list_users():
    """Return a sorted list of usernames."""
    pool = await get_pool()
    async with pool.acquire() as conn:
        rows = await conn.fetch("SELECT username FROM credentials ORDER BY username")
    return [r["username"] for r in rows]


async def close():
    """Close the shared connection pool (for CLI use)."""
    await close_pool()
