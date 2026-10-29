-- Tags are no longer parsed out of the description: record_tags (already filled from
-- the #tags) becomes the only place they live, and the #tags leave the text. Each
-- rewritten record gets a new revision so clients pick up the clean description.
INSERT INTO record_tags (record_id, tag)
SELECT DISTINCT r.id, lower(m[1])
FROM records r, regexp_matches(r.description, '#([^\s#,]+)', 'g') AS m
ON CONFLICT DO NOTHING;

UPDATE records
SET description = btrim(regexp_replace(regexp_replace(description, '#[^\s#,]+', '', 'g'), '\s+', ' ', 'g')),
    updated_at  = now(),
    revision    = nextval('revision_seq')
WHERE description ~ '#[^\s#,]+';
