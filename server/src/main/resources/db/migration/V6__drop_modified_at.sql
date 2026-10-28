-- Conflicts are now detected by revision, so the client's clock is no longer stored.
ALTER TABLE records DROP COLUMN modified_at;
ALTER TABLE settings DROP COLUMN modified_at;
