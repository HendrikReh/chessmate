-- Seed script for loading minimal sample data. Intended for local development only.
-- Usage: psql "$DATABASE_URL" -f scripts/seed_sample_games.sql

INSERT INTO players (name, fide_id, rating_peak)
VALUES
  ('Sample White', NULL, 2600)
ON CONFLICT (fide_id) DO NOTHING;

INSERT INTO players (name, fide_id, rating_peak)
VALUES
  ('Sample Black', NULL, 2500)
ON CONFLICT (fide_id) DO NOTHING;

WITH white AS (
  SELECT id FROM players WHERE name = 'Sample White'
), black AS (
  SELECT id FROM players WHERE name = 'Sample Black'
)
INSERT INTO games (
  white_player_id,
  black_player_id,
  event,
  site,
  round,
  played_on,
  eco_code,
  result,
  white_rating,
  black_rating,
  pgn
)
SELECT
  white.id,
  black.id,
  'Sample Event',
  'Lichess',
  '1',
  CURRENT_DATE,
  'A00',
  '1-0',
  2600,
  2500,
  '[Event "Sample"]\n[Site "Lichess"]\n[Result "1-0"]\n\n1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 1-0'
FROM white, black
ON CONFLICT DO NOTHING;
