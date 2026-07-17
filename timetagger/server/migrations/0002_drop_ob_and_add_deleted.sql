-- Normalize the storage: replace the _ob json blob with typed columns, and
-- replace the legacy "HIDDEN <desc>" soft-delete hack with a real tombstone
-- column (deleted). Backfills existing rows, then drops _ob.

-- Note: mt is double precision, not bigint. Records/settings carry an integer
-- mt, but userinfo rows store mt = st (a fractional unix timestamp), so the
-- column must hold floats.

-- records ------------------------------------------------------------------
ALTER TABLE records ADD COLUMN IF NOT EXISTS mt double precision;
ALTER TABLE records ADD COLUMN IF NOT EXISTS ds text;
ALTER TABLE records ADD COLUMN IF NOT EXISTS deleted smallint NOT NULL DEFAULT 0;

UPDATE records
SET
    mt = (_ob->>'mt')::double precision,
    ds = _ob->>'ds',
    deleted = CASE WHEN (_ob->>'ds') LIKE 'HIDDEN%' THEN 1 ELSE 0 END
WHERE _ob IS NOT NULL;

-- Strip the legacy "HIDDEN " prefix from the description of deleted records.
UPDATE records
SET ds = btrim(substring(ds FROM 7))
WHERE deleted = 1 AND ds LIKE 'HIDDEN%';

ALTER TABLE records DROP COLUMN IF EXISTS _ob;
CREATE INDEX IF NOT EXISTS idx_records_deleted ON records (deleted);

-- settings -----------------------------------------------------------------
ALTER TABLE settings ADD COLUMN IF NOT EXISTS mt double precision;
ALTER TABLE settings ADD COLUMN IF NOT EXISTS value jsonb;

UPDATE settings
SET mt = (_ob->>'mt')::double precision, value = _ob->'value'
WHERE _ob IS NOT NULL;

ALTER TABLE settings DROP COLUMN IF EXISTS _ob;

-- userinfo -----------------------------------------------------------------
ALTER TABLE userinfo ADD COLUMN IF NOT EXISTS mt double precision;
ALTER TABLE userinfo ADD COLUMN IF NOT EXISTS value jsonb;

UPDATE userinfo
SET mt = (_ob->>'mt')::double precision, value = _ob->'value'
WHERE _ob IS NOT NULL;

ALTER TABLE userinfo DROP COLUMN IF EXISTS _ob;
