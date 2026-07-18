"""
PostgreSQL storage backend for TimeTagger.

This replaces the former SQLite (itemdb) backend. All user data is stored
in a single PostgreSQL database; each row is scoped to a user via the
``user`` column. The public class ``PostgresItemDB`` mimics the small
subset of the itemdb API that TimeTagger uses, so that the rest of the
server code can stay agnostic of the storage details.

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


# %% Table schema

# Mapping of item field name -> physical database column, per table. The API,
# the DTOs and the client all speak the short field names (key, st, mt, t1, t2,
# ds); the database uses readable column names. "value" columns are jsonb and
# hold arbitrary JSON; "key" is the per-user primary key. This is the single
# source of truth in code; the physical schema is created by the migrations
# (see server/_migrations.py) and must stay in sync.
_TABLES = {
    "records": {
        "key": "key",
        "st": "server_time",
        "mt": "modified_time",
        "t1": "start_time",
        "t2": "stop_time",
        "ds": "description",
        "deleted": "deleted",
    },
    "settings": {
        "key": "key",
        "st": "server_time",
        "mt": "modified_time",
        "value": "value",
    },
    "userinfo": {
        "key": "key",
        "st": "server_time",
        "mt": "modified_time",
        "value": "value",
    },
}


# %% Query translation (itemdb/SQLite dialect -> PostgreSQL)


def _translate_where(query, fieldmap):
    """Translate an itemdb (SQLite) WHERE fragment to PostgreSQL.

    Field names are mapped to their physical column names, ``==`` becomes ``=``
    and the user-supplied ``?`` placeholders are renumbered to ``$2, $3, ...``
    ($1 is reserved for the user filter that the caller prepends).
    """
    q = query
    for field, column in fieldmap.items():
        if field != column:
            q = re.sub(rf"\b{field}\b", f'"{column}"', q)
    q = q.replace("==", "=")
    counter = itertools.count(2)
    q = re.sub(r"\?", lambda m: f"${next(counter)}", q)
    return q


# %% The database class


class PostgresItemDB:
    """A per-user view on the shared PostgreSQL database.

    Presents the subset of the itemdb API that TimeTagger relies on:
    ``ensure_table``, ``select``, ``select_one``, ``select_all``,
    ``put``, ``put_one``, the ``mtime`` property and use as an async
    transaction context manager (``async with db: ...``).
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

    async def ensure_table(self, table_name, *indices):
        """Sync mtime for a table.

        The schema itself is created centrally by the migrations (see
        ``server/_migrations.py``) and the columns are described by
        ``_TABLES``; the ``indices`` argument is accepted for API
        compatibility but ignored.
        """
        if table_name not in _TABLES:
            raise KeyError(f"Unknown table {table_name!r}.")
        # Keep mtime in sync with what is currently in the table.
        await self._refresh_mtime(table_name)
        return self

    async def _refresh_mtime(self, table_name):
        st_col = _TABLES[table_name]["st"]
        async with self._acquire() as conn:
            row = await conn.fetchrow(
                f'SELECT max("{st_col}") AS m FROM {table_name} WHERE "user" = $1',
                self._user,
            )
        if row is not None and row["m"] is not None:
            self._mtime = max(self._mtime, float(row["m"]))

    # -- reading

    def _fieldmap(self, table_name):
        fieldmap = _TABLES.get(table_name)
        if fieldmap is None:
            raise KeyError(f"Unknown table {table_name!r}.")
        return fieldmap

    @staticmethod
    def _row_to_item(fieldmap, row):
        """Reconstruct a field-named item dict from a row, dropping NULLs."""
        item = {}
        for field in fieldmap:
            val = row[field]
            if val is not None:
                item[field] = val
        return item

    def _collist(self, fieldmap):
        # Select physical columns, aliased back to the short field names.
        return ", ".join(f'"{col}" AS "{field}"' for field, col in fieldmap.items())

    async def select(self, table_name, query, *save_args):
        fieldmap = self._fieldmap(table_name)
        where = _translate_where(query, fieldmap)
        sql = (
            f"SELECT {self._collist(fieldmap)} FROM {table_name} "
            f'WHERE ("user" = $1) AND ({where})'
        )
        async with self._acquire() as conn:
            rows = await conn.fetch(sql, self._user, *save_args)
        return [self._row_to_item(fieldmap, row) for row in rows]

    async def select_one(self, table_name, query, *save_args):
        items = await self.select(table_name, query, *save_args)
        return items[0] if items else None

    async def select_all(self, table_name):
        fieldmap = self._fieldmap(table_name)
        sql = f'SELECT {self._collist(fieldmap)} FROM {table_name} WHERE "user" = $1'
        async with self._acquire() as conn:
            rows = await conn.fetch(sql, self._user)
        return [self._row_to_item(fieldmap, row) for row in rows]

    # -- writing

    async def put(self, table_name, *items):
        if self._tx_conn is None:
            raise IOError("Can only use put() within a transaction.")

        fieldmap = self._fieldmap(table_name)
        key_col = fieldmap["key"]

        for item in items:
            if not isinstance(item, dict):
                raise TypeError("Expecting each item to be a dict")
            if "key" not in item:
                raise IndexError("Item does not have required field 'key'")

            # Only write the columns that the item actually provides, so that
            # partial updates leave other columns untouched.
            present = [f for f in fieldmap if f in item]
            cols = ['"user"'] + [f'"{fieldmap[f]}"' for f in present]
            values = [self._user] + [item[f] for f in present]
            placeholders = ", ".join(f"${i + 1}" for i in range(len(values)))
            update_cols = ", ".join(
                f'"{fieldmap[f]}" = EXCLUDED."{fieldmap[f]}"'
                for f in present
                if f != "key"
            )
            conflict = f"DO UPDATE SET {update_cols}" if update_cols else "DO NOTHING"
            sql = (
                f"INSERT INTO {table_name} ({', '.join(cols)}) "
                f"VALUES ({placeholders}) "
                f'ON CONFLICT ("user", "{key_col}") {conflict}'
            )
            await self._tx_conn.execute(sql, *values)

            st = item.get("st")
            if isinstance(st, (int, float)):
                self._mtime = max(self._mtime, float(st))

    async def put_one(self, table_name, **item):
        await self.put(table_name, item)
