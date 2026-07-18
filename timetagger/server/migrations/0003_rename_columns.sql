-- Give the columns readable names. The API/DTOs/client keep the short field
-- names (key, st, mt, t1, t2, ds); PostgresItemDB maps them to these columns
-- (see server/_pg.py, _TABLES).

-- records ------------------------------------------------------------------
ALTER TABLE records RENAME COLUMN st TO server_time;
ALTER TABLE records RENAME COLUMN mt TO modified_time;
ALTER TABLE records RENAME COLUMN t1 TO start_time;
ALTER TABLE records RENAME COLUMN t2 TO stop_time;
ALTER TABLE records RENAME COLUMN ds TO description;
ALTER INDEX IF EXISTS idx_records_st RENAME TO idx_records_server_time;
ALTER INDEX IF EXISTS idx_records_t1 RENAME TO idx_records_start_time;
ALTER INDEX IF EXISTS idx_records_t2 RENAME TO idx_records_stop_time;

-- settings -----------------------------------------------------------------
ALTER TABLE settings RENAME COLUMN st TO server_time;
ALTER TABLE settings RENAME COLUMN mt TO modified_time;
ALTER INDEX IF EXISTS idx_settings_st RENAME TO idx_settings_server_time;

-- userinfo -----------------------------------------------------------------
ALTER TABLE userinfo RENAME COLUMN st TO server_time;
ALTER TABLE userinfo RENAME COLUMN mt TO modified_time;
ALTER INDEX IF EXISTS idx_userinfo_st RENAME TO idx_userinfo_server_time;

-- credentials --------------------------------------------------------------
ALTER TABLE credentials RENAME COLUMN mt TO modified_time;
