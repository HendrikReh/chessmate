-- Migration: 0001_init
-- Creates core tables for players, games, positions, annotations, and embedding jobs.

BEGIN;

CREATE TABLE IF NOT EXISTS players (
  id             SERIAL PRIMARY KEY,
  name           TEXT NOT NULL,
  fide_id        TEXT UNIQUE,
  rating_peak    INTEGER,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS games (
  id               BIGSERIAL PRIMARY KEY,
  white_player_id  INTEGER REFERENCES players(id),
  black_player_id  INTEGER REFERENCES players(id),
  event            TEXT,
  site             TEXT,
  round            TEXT,
  played_on        DATE,
  eco_code         TEXT,
  result           TEXT,
  white_rating     INTEGER,
  black_rating     INTEGER,
  tags             JSONB DEFAULT '{}'::JSONB,
  pgn              TEXT NOT NULL,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_games_white_rating ON games(white_rating);
CREATE INDEX IF NOT EXISTS idx_games_black_rating ON games(black_rating);
CREATE INDEX IF NOT EXISTS idx_games_eco_code ON games(eco_code);

CREATE TABLE IF NOT EXISTS positions (
  id             BIGSERIAL PRIMARY KEY,
  game_id        BIGINT NOT NULL REFERENCES games(id) ON DELETE CASCADE,
  ply            INTEGER NOT NULL,
  move_number    INTEGER,
  side_to_move   TEXT,
  fen            TEXT NOT NULL,
  san            TEXT,
  eval_cp        INTEGER,
  vector_id      TEXT,
  tags           JSONB DEFAULT '{}'::JSONB,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(game_id, ply)
);

CREATE INDEX IF NOT EXISTS idx_positions_vector_id ON positions(vector_id);
CREATE INDEX IF NOT EXISTS idx_positions_fen ON positions USING GIN (to_tsvector('english', fen));

CREATE TABLE IF NOT EXISTS annotations (
  id           BIGSERIAL PRIMARY KEY,
  position_id  BIGINT NOT NULL REFERENCES positions(id) ON DELETE CASCADE,
  author       TEXT,
  body         TEXT NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS embedding_jobs (
  id             BIGSERIAL PRIMARY KEY,
  position_id    BIGINT REFERENCES positions(id) ON DELETE CASCADE,
  fen            TEXT NOT NULL,
  status         TEXT NOT NULL DEFAULT 'pending',
  attempts       INTEGER NOT NULL DEFAULT 0,
  last_error     TEXT,
  enqueued_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  started_at     TIMESTAMPTZ,
  completed_at   TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_embedding_jobs_status ON embedding_jobs(status);

COMMIT;
