-- Mac app usage from TimeTaggerUsage: one row per stretch in front of an app ('app', with the
-- window title) or away from the Mac ('away', bundle_id = idle/lock/sleep). The open stretch is
-- re-sent with a later stop, so the row with the latest stop per (user, device, start) wins: read with FINAL.
CREATE TABLE IF NOT EXISTS app_usage (
    user_id   UInt64,
    device    LowCardinality(String),
    kind      LowCardinality(String),
    bundle_id LowCardinality(String),
    app_name  LowCardinality(String),
    title     LowCardinality(String),
    start_at  DateTime64(3, 'UTC'),
    stop_at   DateTime64(3, 'UTC')
)
ENGINE = ReplacingMergeTree(stop_at)
PARTITION BY toYYYYMM(start_at)
ORDER BY (user_id, device, start_at)
