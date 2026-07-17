-- Initial TimeTagger schema.
--
-- All user data lives in a handful of shared tables, scoped per user via the
-- "user" column. Each row keeps the full item as a jsonb blob in _ob; a few
-- typed columns duplicate indexed fields for the primary key and lookups.

CREATE TABLE IF NOT EXISTS records (
    "user" text NOT NULL,
    _ob jsonb NOT NULL,
    "key" text NOT NULL,
    st double precision,
    t1 bigint,
    t2 bigint,
    PRIMARY KEY ("user", "key")
);
CREATE INDEX IF NOT EXISTS idx_records_st ON records (st);
CREATE INDEX IF NOT EXISTS idx_records_t1 ON records (t1);
CREATE INDEX IF NOT EXISTS idx_records_t2 ON records (t2);

CREATE TABLE IF NOT EXISTS settings (
    "user" text NOT NULL,
    _ob jsonb NOT NULL,
    "key" text NOT NULL,
    st double precision,
    PRIMARY KEY ("user", "key")
);
CREATE INDEX IF NOT EXISTS idx_settings_st ON settings (st);

CREATE TABLE IF NOT EXISTS userinfo (
    "user" text NOT NULL,
    _ob jsonb NOT NULL,
    "key" text NOT NULL,
    st double precision,
    PRIMARY KEY ("user", "key")
);
CREATE INDEX IF NOT EXISTS idx_userinfo_st ON userinfo (st);

CREATE TABLE IF NOT EXISTS credentials (
    username text PRIMARY KEY,
    pw_hash text NOT NULL,
    mt double precision
);
