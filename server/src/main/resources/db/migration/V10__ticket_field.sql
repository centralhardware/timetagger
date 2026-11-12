-- The ticket key (SM-1176, CORE-2517) gets its own column instead of riding along as a tag.
-- Backfill: the first SM-/CORE- key among a record's tags, else the first one in its
-- description. A key taken from the tags leaves record_tags; one taken from the
-- description stays in the text, unless the text was only the key. Every filled record
-- gets a new revision so clients pick the change up.
ALTER TABLE records ADD COLUMN ticket TEXT;

WITH from_tags AS (
    SELECT DISTINCT ON (t.record_id) t.record_id, upper(t.tag) AS ticket
    FROM record_tags t
    WHERE t.tag ~ '^(sm|core)-[0-9]+$'
    ORDER BY t.record_id, t.tag
)
UPDATE records r
SET ticket = f.ticket
FROM from_tags f
WHERE r.id = f.record_id;

UPDATE records
SET ticket = upper(substring(description FROM '(?i)\m((?:sm|core)-[0-9]+)\M'))
WHERE ticket IS NULL AND description ~* '\m(sm|core)-[0-9]+\M';

DELETE FROM record_tags t
USING records r
WHERE r.id = t.record_id AND r.ticket IS NOT NULL AND upper(t.tag) = r.ticket;

UPDATE records
SET description = ''
WHERE ticket IS NOT NULL AND upper(btrim(description)) = ticket;

UPDATE records
SET updated_at = now(), revision = nextval('revision_seq')
WHERE ticket IS NOT NULL;
