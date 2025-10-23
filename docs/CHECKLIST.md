# Chessmate Command Checklist

Reference list of shell commands gathered from the documentation (`docs/`). Commands are grouped by typical workflows so you can mark each step as you verify it.

## Environment Setup
- [ ] `./bootstrap.sh`
- [ ] `cp .env.sample .env`
- [ ] `source .env`
- [ ] `set -a; source .env`
- [ ] `eval "$(opam env --set-switch)"`
- [ ] `export DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate`
- [ ] `export CHESSMATE_API_URL=http://localhost:8080`
- [ ] `export CHESSMATE_TEST_DATABASE_URL=postgres://chess:chess@localhost:5433/postgres`
- [ ] `export CHESSMATE_MAX_PENDING_EMBEDDINGS=400000`

## Bootstrap Services
- [ ] `docker compose up -d postgres qdrant redis`
- [ ] `./scripts/migrate.sh`
- [ ] `docker compose exec postgres psql -U chess -c "ALTER ROLE chess WITH CREATEDB;"`

## Run API & Background Tasks
- [ ] `dune exec -- chessmate-api -- --port 8080`
- [ ] `CHESSMATE_OPENAPI_SPEC=/tmp/openapi.yaml dune exec -- chessmate-api -- --port 8080`
- [ ] `dune exec -- chessmate-api -- --port 8080 &`
- [ ] `API_PID=$!`
- [ ] `sudo systemctl stop chessmate-api`

## Run Embedding Worker
- [ ] `OPENAI_API_KEY=dummy dune exec embedding_worker -- --workers 2 --poll-sleep 1.0`
- [ ] `OPENAI_API_KEY=dummy dune exec -- embedding_worker -- --workers 1`
- [ ] `OPENAI_API_KEY=dummy DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate dune exec -- embedding_worker -- --workers 1 --poll-sleep 1.0 --exit-after-empty 3`
- [ ] `OPENAI_API_KEY=real-key dune exec -- embedding_worker -- --workers 6 --poll-sleep 1.0 --exit-after-empty 3`
- [ ] `DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate QDRANT_URL=http://localhost:6333 dune exec -- embedding_worker -- --workers 3 --poll-sleep 1.0 --exit-after-empty 3`
- [ ] `OPENAI_API_KEY=dummy DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate dune exec -- embedding_worker -- --listen-prometheus 9102 --exit-after-empty 1 &`
- [ ] `WORKER_PID=$!`

## Ingest & Query (CLI)
- [ ] `dune exec -- chessmate -- config`
- [ ] `dune exec -- chessmate -- ingest test/fixtures/extended_sample_game.pgn`
- [ ] `dune exec -- chessmate -- ingest data/games/twic1611.pgn`
- [ ] `CHESSMATE_API_URL=http://localhost:8080 dune exec -- chessmate -- query --json "Show 5 random games"`
- [ ] `CHESSMATE_API_URL=http://localhost:8080 dune exec -- chessmate -- query --json --limit 5 --offset 0 "Show French Defense draws"`
- [ ] `CHESSMATE_API_URL=http://localhost:8080 dune exec -- chessmate -- query "Show King's Indian games"`
- [ ] `CHESSMATE_API_URL=http://localhost:8080 dune exec -- chessmate -- query "Find queenside majority attacks in King's Indian"`
- [ ] `AGENT_API_KEY=your-openai-key AGENT_REASONING_EFFORT=high CHESSMATE_API_URL=http://localhost:8080 dune exec -- chessmate -- query "Find queenside majority attacks in King's Indian"`
- [ ] `CHESSMATE_API_URL=http://localhost:8080 dune exec -- chessmate -- query "Explain thematic rook sacrifices"`
- [ ] `CHESSMATE_API_URL=http://localhost:8080 dune exec -- chessmate -- query --limit 5 --offset 10 "Find Queens Gambit games"`
- [ ] `CHESSMATE_API_URL=http://localhost:8080 dune exec -- chessmate -- query "Show 5 random games"`
- [ ] `CHESSMATE_API_URL=http://localhost:8080 for i in {1..70}; do dune exec -- chessmate -- query "Show 5 random games"; done`
- [ ] `dune exec -- chessmate -- --listen-prometheus 9101 ingest test/fixtures/sample_game.pgn &`
- [ ] `CLI_PID=$!`

## Testing & Verification
- [ ] `scripts/check_gpl_headers.sh`
- [ ] `dune fmt`
- [ ] `dune build`
- [ ] `dune runtest`
- [ ] `dune build && dune runtest`
- [ ] `dune exec test/test_main.exe -- test integration`

## Observability & Health
- [ ] `curl -s http://localhost:8080/health | jq`
- [ ] `PORT=${CHESSMATE_WORKER_HEALTH_PORT:-8081}`
- [ ] `curl -s "http://localhost:${PORT}/health" | jq`
- [ ] `curl -s "http://localhost:${CHESSMATE_WORKER_HEALTH_PORT:-8081}/health" | jq`
- [ ] `curl -s http://localhost:8080/health | jq '.checks[] | select(.name=="qdrant")'`
- [ ] `curl -s http://localhost:8080/health | jq '.status'`
- [ ] `curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/health`
- [ ] `curl http://localhost:8080/metrics`
- [ ] `curl http://localhost:8080/openapi.yaml`
- [ ] `curl -s http://localhost:8080/metrics | grep 'api_request_total{route='`
- [ ] `curl -s http://localhost:8080/metrics | head -n 5`
- [ ] `curl -s http://localhost:9101/metrics | head -n 5`
- [ ] `curl -s http://localhost:9102/metrics | head -n 5`
- [ ] `scripts/check_metrics.sh PORT=8080`
- [ ] `scripts/check_metrics.sh PORT=9101 HOST=localhost PATHNAME=/metrics`
- [ ] `scripts/check_metrics.sh PORT=9101 || true`
- [ ] `scripts/check_metrics.sh PORT=9102 || true`
- [ ] `scripts/run_prometheus.sh`
- [ ] `scripts/embedding_metrics.sh --interval 120`
- [ ] `scripts/embedding_metrics.sh --interval 120 --log logs/embedding-metrics.log`
- [ ] `printf 'GET /metrics"bad\\name HTTP/1.1\r\nHost: localhost:8080\r\n\r\n' | nc -N localhost 8080   # use '-q 1' on GNU netcat`
- [ ] `curl -sS -o /dev/null -w "%{http_code}\n" -g "http://localhost:8080/metrics%22bad%5Cname"`

## Load & Performance
- [ ] `PAYLOAD=$(jq -c . scripts/fixtures/load_test_query.json)`
- [ ] `DURATION=60s CONCURRENCY=50 TOOL=oha ./scripts/load_test.sh`
- [ ] `CONCURRENCY=80 DURATION=120s TOOL=vegeta TARGET_URL=http://localhost:8080/query ./scripts/load_test.sh`
- [ ] `TARGET_URL=http://localhost:8080/query PAYLOAD=scripts/fixtures/load_test_query.json DURATION=60s CONCURRENCY=50 TOOL=oha ./scripts/load_test.sh`
- [ ] `TOOL=oha DURATION=60s CONCURRENCY=50 ./scripts/load_test.sh`
- [ ] `TOOL=oha DURATION=60s CONCURRENCY=50 TARGET_URL=http://localhost:8080/query scripts/load_test.sh`
- [ ] `oha --duration 60s --connections 50 --method POST --header 'Content-Type: application/json' --body "$PAYLOAD" http://localhost:8080/query`
- [ ] `AGENT_API_KEY="" oha --duration 60s --concurrency 50 --header 'Content-Type: application/json' --body "$PAYLOAD" http://localhost:8080/query`
- [ ] `AGENT_API_KEY=sk-real-key oha --duration 60s --concurrency 30 --header 'Content-Type: application/json' --body "$PAYLOAD" http://localhost:8080/query`
- [ ] `echo "POST http://localhost:8080/query" | vegeta attack -body scripts/fixtures/load_test_query.json -header "Content-Type: application/json" -duration=60s -rate=0 -max-workers=50 | vegeta report`

## Snapshots & Recovery
- [ ] `dune exec -- chessmate -- collection snapshot --name nightly-backup --note "before bulk reindex"`
- [ ] `dune exec -- chessmate -- collection list`
- [ ] `dune exec -- chessmate -- collection restore --snapshot nightly-backup`
- [ ] `CHESSMATE_SNAPSHOT_LOG=/backups/qdrant/log.jsonl dune exec -- chessmate -- collection restore --snapshot nightly-backup`

## Maintenance & Cleanup
- [ ] `scripts/prune_pending_jobs.sh 2000`
- [ ] `docker compose stop postgres`
- [ ] `docker compose start postgres`
- [ ] `docker compose stop qdrant`
- [ ] `docker compose start qdrant`
- [ ] `docker compose stop redis`
- [ ] `docker compose start redis`
- [ ] `redis-cli --scan --pattern 'chessmate:agent:*'`
- [ ] `redis-cli --scan --pattern 'chessmate:agent:*' | xargs -r redis-cli del`
- [ ] `docker compose exec redis redis-cli --scan --pattern 'chessmate:agent:*'`
- [ ] `unset AGENT_API_KEY`
- [ ] `docker compose down`
- [ ] `rm -rf data/postgres data/qdrant data/redis`
- [ ] `kill $API_PID $CLI_PID $WORKER_PID`

## Operational Diagnostics
- [ ] `DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate psql "$DATABASE_URL" -c "SELECT 1"`
- [ ] `DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate psql "$DATABASE_URL" -c "SELECT COUNT(*) FROM positions WHERE vector_id IS NOT NULL"`
- [ ] `DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate psql "$DATABASE_URL" -c "SELECT status, COUNT(*) FROM embedding_jobs GROUP BY status"`
- [ ] `DATABASE_URL=postgres://chess:chess@localhost:5433/chessmate dune exec chessmate -- ingest data/games/twic1611.pgn`

## Profiling & Benchmarks
- [ ] `eval "$(opam env --set-switch)"`
- [ ] ```sh
  ocaml <<'EOF'
  # ... profiling script ...
  EOF
  ```
