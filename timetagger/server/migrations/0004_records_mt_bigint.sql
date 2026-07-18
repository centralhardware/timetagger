-- modified_time is an integer for records/settings (the client sends whole
-- seconds), so make those columns bigint to match the typed DTOs. userinfo
-- keeps double precision, because there modified_time is set to st (a
-- fractional unix timestamp).

ALTER TABLE records
    ALTER COLUMN modified_time TYPE bigint USING modified_time::bigint;
ALTER TABLE settings
    ALTER COLUMN modified_time TYPE bigint USING modified_time::bigint;
