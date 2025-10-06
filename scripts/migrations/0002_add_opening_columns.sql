-- Migration: 0002_add_opening_columns
-- Adds opening metadata (name + slug) to games table.

BEGIN;

ALTER TABLE games ADD COLUMN IF NOT EXISTS opening_name TEXT;
ALTER TABLE games ADD COLUMN IF NOT EXISTS opening_slug TEXT;

CREATE INDEX IF NOT EXISTS idx_games_opening_slug ON games(opening_slug);

COMMIT;
