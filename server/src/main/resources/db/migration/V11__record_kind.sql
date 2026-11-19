-- A record is either work or a gap: time deliberately not worked (lunch, dinner) that
-- the user has named. A gap record keeps the timeline honest without counting as work;
-- clients show it as a gap, and reports and totals skip it.
ALTER TABLE records ADD COLUMN kind TEXT NOT NULL DEFAULT 'work' CHECK (kind IN ('work', 'gap'));
