"""
PostgreSQL storage backend for TimeTagger.

This replaces the former SQLite (itemdb) backend. All user data is stored
in a single PostgreSQL database; each row is scoped to a user via the
``user`` column. ``PostgresItemDB`` reads and writes typed DTOs (see
``server/_dtos.py``): each DTO knows its table and the field->column mapping,
so this layer never deals with loose per-field dicts.

The connection string is taken from ``config.db_uri`` (env
``TIMETAGGER_DB_URI``), e.g. ``postgresql://user:pass@host:5432/timetagger``.
"""

import re
import json
import asyncio
import itertools
import contextlib

import asyncpg

from .. import config

# %% Connection pool

# asyncpg pools are bound to the event loop that created them. TimeTagger
# normally runs in a single loop, but the test suite (and other embedders)
# may use several loops, so we keep one pool per running loop.
_pools = {}  # event loop -> asyncpg pool


async def _init_connection(conn):
    # Return jsonb values as Python objects (and accept Python objects).
    await conn.set_type_codec(
        "jsonb",
        encoder=json.dumps,
        decoder=json.loads,
        schema="pg_catalog",
    )


async def get_pool():
    """Get (and lazily create) the asyncpg pool for the running loop."""
    loop = asyncio.get_running_loop()
    pool = _pools.get(loop)
    if pool is None:
        dsn = (config.db_uri or "").strip()
        if not dsn:
            raise RuntimeError(
                "TimeTagger requires a PostgreSQL database. "
                "Set config.db_uri (env TIMETAGGER_DB_URI), e.g. "
                "'postgresql://user:pass@host:5432/timetagger'."
            )
        pool = await asyncpg.create_pool(
            dsn=dsn,
            init=_init_connection,
            min_size=1,
            max_size=10,
        )
        # Another coroutine on this loop may have created one meanwhile.
        if loop in _pools:
            await pool.close()
            pool = _pools[loop]
        else:
            _pools[loop] = pool
    return pool


async def close_pool():
    """Close the pool for the running loop (mainly useful for tests/CLI)."""
    loop = asyncio.get_running_loop()
    pool = _pools.pop(loop, None)
    if pool is not None:
        await pool.close()


# %% Query translation (itemdb/SQLite dialect -> PostgreSQL)


def _translate_where(query, dto_cls):
    """Translate an itemdb (SQLite) WHERE fragment to PostgreSQL.

    Field names are mapped to their physical column names (per the DTO), ``==``
    becomes ``=`` and the user-supplied ``?`` placeholders are renumbered to
    ``$2, $3, ...`` ($1 is reserved for the user filter the caller prepends).
    """
    q = query
    for field in dto_cls.model_fields:
        column = dto_cls.column_for(field)
        if field != column:
            q = re.sub(rf"\b{field}\b", f'"{column}"', q)
    q = q.replace("==", "=")
    counter = itertools.count(2)
    q = re.sub(r"\?", lambda m: f"${next(counter)}", q)
    return q


# %% The database class


class PostgresItemDB:
    """A per-user view on the shared PostgreSQL database.

    Works in terms of DTO classes/instances (see ``server/_dtos.py``):
    ``ensure_table(dto_cls)``, ``select(dto_cls, ...)``, ``select_one``,
    ``select_all(dto_cls)`` return DTOs, and ``put(*dtos)`` stores them.
    Also exposes the ``mtime`` property and works as an async transaction
    context manager (``async with db: ...``).
    """

    def __init__(self, username):
        self._user = username
        self._mtime = -1.0
        self._tx_conn = None  # connection while inside a transaction
        self._tx = None

    @classmethod
    async def open(cls, username):
        self = cls(username)
        await get_pool()  # fail fast if misconfigured
        return self

    @property
    def mtime(self):
        return self._mtime

    # -- connection handling

    @contextlib.asynccontextmanager
    async def _acquire(self):
        if self._tx_conn is not None:
            yield self._tx_conn
        else:
            pool = await get_pool()
            async with pool.acquire() as conn:
                yield conn

    async def __aenter__(self):
        if self._tx_conn is not None:
            return self  # already in a transaction (not expected, but safe)
        pool = await get_pool()
        self._tx_conn = await pool.acquire()
        self._tx = self._tx_conn.transaction()
        await self._tx.start()
        return self

    async def __aexit__(self, exc_type, exc, tb):
        tx, conn = self._tx, self._tx_conn
        self._tx = None
        self._tx_conn = None
        pool = await get_pool()
        try:
            if exc_type is not None:
                await tx.rollback()
            else:
                await tx.commit()
        finally:
            await pool.release(conn)

    # -- schema

    async def ensure_table(self, dto_cls):
        """Sync mtime for the given DTO's table.

        The schema itself is created centrally by the migrations (see
        ``server/_migrations.py``); the columns are described by the DTO.
        """
        await self._refresh_mtime(dto_cls)
        return self

    async def _refresh_mtime(self, dto_cls):
        st_col = dto_cls.column_for("st")
        table = dto_cls.table_name
        async with self._acquire() as conn:
            row = await conn.fetchrow(
                f'SELECT max("{st_col}") AS m FROM {table} WHERE "user" = $1',
                self._user,
            )
        if row is not None and row["m"] is not None:
            self._mtime = max(self._mtime, float(row["m"]))

    # -- reading

    @staticmethod
    def _collist(dto_cls):
        # Select physical columns, aliased back to the short field names.
        return ", ".join(
            f'"{dto_cls.column_for(f)}" AS "{f}"' for f in dto_cls.model_fields
        )

    async def select(self, dto_cls, query, *save_args):
        where = _translate_where(query, dto_cls)
        sql = (
            f"SELECT {self._collist(dto_cls)} FROM {dto_cls.table_name} "
            f'WHERE ("user" = $1) AND ({where})'
        )
        async with self._acquire() as conn:
            rows = await conn.fetch(sql, self._user, *save_args)
        return [dto_cls.from_row(row) for row in rows]

    async def select_one(self, dto_cls, query, *save_args):
        items = await self.select(dto_cls, query, *save_args)
        return items[0] if items else None

    async def select_all(self, dto_cls):
        sql = (
            f"SELECT {self._collist(dto_cls)} FROM {dto_cls.table_name} "
            f'WHERE "user" = $1'
        )
        async with self._acquire() as conn:
            rows = await conn.fetch(sql, self._user)
        return [dto_cls.from_row(row) for row in rows]

    # -- writing

    async def put(self, *items):
        if self._tx_conn is None:
            raise IOError("Can only use put() within a transaction.")

        for item in items:
            dto_cls = type(item)
            key_col = dto_cls.column_for(dto_cls.key_field)

            # Only write the columns the item actually sets (skips None), so
            # partial updates leave other columns untouched.
            row = item.to_row()
            columns = list(row.keys())
            cols = ['"user"'] + [f'"{c}"' for c in columns]
            values = [self._user] + [row[c] for c in columns]
            placeholders = ", ".join(f"${i + 1}" for i in range(len(values)))
            update_cols = ", ".join(
                f'"{c}" = EXCLUDED."{c}"' for c in columns if c != key_col
            )
            conflict = f"DO UPDATE SET {update_cols}" if update_cols else "DO NOTHING"
            sql = (
                f"INSERT INTO {dto_cls.table_name} ({', '.join(cols)}) "
                f"VALUES ({placeholders}) "
                f'ON CONFLICT ("user", "{key_col}") {conflict}'
            )
            await self._tx_conn.execute(sql, *values)

            if isinstance(item.st, (int, float)):
                self._mtime = max(self._mtime, float(item.st))
