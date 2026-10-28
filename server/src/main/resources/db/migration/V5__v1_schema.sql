-- The v1 schema: one users table, real timestamps, tags in their own table,
-- and a revision counter for sync. Converts the v2 data, then drops the v2
-- tables (and the Python server's schema_migrations).

CREATE SEQUENCE revision_seq;

CREATE TABLE users (
    id             bigserial PRIMARY KEY,
    username       text NOT NULL UNIQUE,
    password_hash  text,
    -- A new seed revokes every token of that kind.
    web_token_seed text,
    api_token_seed text,
    created_at     timestamptz NOT NULL DEFAULT now()
);

INSERT INTO users (username, password_hash)
SELECT username, pw_hash FROM credentials;

INSERT INTO users (username)
SELECT DISTINCT "user" FROM (
    SELECT "user" FROM records UNION SELECT "user" FROM settings UNION SELECT "user" FROM userinfo
) u
ON CONFLICT (username) DO NOTHING;

UPDATE users SET
    web_token_seed = (SELECT value #>> '{}' FROM userinfo i WHERE i."user" = users.username AND i."key" = 'webtoken_seed'),
    api_token_seed = (SELECT value #>> '{}' FROM userinfo i WHERE i."user" = users.username AND i."key" = 'apitoken_seed');

CREATE TABLE records_v1 (
    id          bigserial PRIMARY KEY,
    user_id     bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    -- The client-chosen id, unique per user.
    "key"       text NOT NULL,
    start_at    timestamptz NOT NULL,
    -- NULL while the record is running.
    stop_at     timestamptz,
    description text NOT NULL DEFAULT '',
    -- Set when deleted; the row stays so other clients learn of the delete.
    deleted_at  timestamptz,
    -- When the client last edited it; the newest edit wins.
    modified_at timestamptz NOT NULL,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    revision    bigint NOT NULL DEFAULT nextval('revision_seq'),
    UNIQUE (user_id, "key"),
    CHECK (stop_at IS NULL OR stop_at >= start_at)
);

-- Revisions follow the old server-time order, so the history keeps its order.
INSERT INTO records_v1 (user_id, "key", start_at, stop_at, description, deleted_at, modified_at, updated_at, revision)
SELECT u.id, r."key",
       to_timestamp(r.start_time),
       CASE WHEN r.stop_time = r.start_time THEN NULL ELSE to_timestamp(greatest(r.stop_time, r.start_time)) END,
       coalesce(r.description, ''),
       CASE WHEN r.deleted = 1 THEN to_timestamp(r.modified_time) END,
       to_timestamp(r.modified_time),
       to_timestamp(coalesce(r.server_time, r.modified_time)),
       nextval('revision_seq')
FROM (SELECT * FROM records ORDER BY server_time NULLS FIRST) r
JOIN users u ON u.username = r."user";

CREATE INDEX records_user_start ON records_v1 (user_id, start_at);
CREATE INDEX records_user_revision ON records_v1 (user_id, revision);

CREATE TABLE record_tags (
    record_id bigint NOT NULL REFERENCES records_v1 (id) ON DELETE CASCADE,
    tag       text NOT NULL,
    PRIMARY KEY (record_id, tag)
);
CREATE INDEX record_tags_tag ON record_tags (tag, record_id);

INSERT INTO record_tags (record_id, tag)
SELECT DISTINCT r.id, lower(m[1])
FROM records_v1 r, regexp_matches(r.description, '#([^\s#,]+)', 'g') AS m;

CREATE TABLE settings_v1 (
    user_id     bigint NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    "key"       text NOT NULL,
    value       jsonb NOT NULL,
    modified_at timestamptz NOT NULL,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    revision    bigint NOT NULL DEFAULT nextval('revision_seq'),
    PRIMARY KEY (user_id, "key")
);

INSERT INTO settings_v1 (user_id, "key", value, modified_at, updated_at)
SELECT u.id, s."key", coalesce(s.value, 'null'::jsonb), to_timestamp(s.modified_time), to_timestamp(coalesce(s.server_time, s.modified_time))
FROM settings s JOIN users u ON u.username = s."user";

DROP TABLE records, settings, userinfo, credentials;
DROP TABLE IF EXISTS schema_migrations;

ALTER TABLE records_v1 RENAME TO records;
ALTER TABLE settings_v1 RENAME TO settings;
