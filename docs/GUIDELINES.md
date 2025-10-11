# Collaboration & Quality Guidelines

This document complements the [Developer Handbook](DEVELOPER.md), [Testing Plan](TESTING.md), and [Operations Playbook](OPERATIONS.md). Use it as the concise checklist for how we collaborate and keep Chessmate in top shape.

---

## 1. Communication & Planning
- Track work in GitHub Issues; every PR references its parent issue.
- Record design decisions in `docs/ADR-<id>.md` with context and outcome.
- Share daily async updates (progress, blockers, next steps) in the team channel.

---

## 2. Branching & PR Hygiene
- Branch naming: `feature/<topic>`, `fix/<issue-id>`, `docs/<subject>`.
- Keep PRs under ~400 lines; split refactors into reviewable slices.
- PR template checklist: summary, testing evidence (`dune build`, `dune runtest`, integration steps if relevant), migration impact, rollback plan.
- Require at least one peer review focused on correctness, resiliency, and test coverage.
- No direct pushes to `main`; protected branch rules + required status checks enforce lint/tests.

---

## 3. Coding Standards
- **OCaml style**: use `open! Base`, provide `.mli` interfaces, avoid `Stdlib` unless necessary, prefer `Or_error.t` for recoverable failures.
- **Separation of concerns**: keep `lib/chess` pure; put side effects in `lib/storage`/services.
- Use pattern matching, avoid partial functions, and add concise comments for non-obvious logic.
- Add GPL notice headers to new source/interfaces (copy from existing modules).
- **Formatting**: run `dune fmt` (ocamlformat profile `conventional`, version `0.27.0`). CI runs `dune build @fmt`—mismatches fail the pipeline.

---

## 4. Testing Expectations
- Write Alcotest unit tests for new modules; store fixtures under `test/`.
- Integration tests (dockerised Postgres/Qdrant) should be tagged once we enable tagging; ensure `CHESSMATE_TEST_DATABASE_URL` has `CREATEDB` rights.
- Update curated natural-language queries when behaviour changes and document acceptance criteria.
- Never merge with red tests; if you must skip a test, file an issue with justification.

---

## 5. Documentation & Runbooks
- Update `docs/IMPLEMENTATION_PLAN.md` (roadmap) and `docs/ARCHITECTURE.md` (component/data flows) after major changes.
- Log incident retrospectives or service runbooks under `docs/`.
- Keep `README.md`, `COOKBOOK.md`, `COOKBOOK`, etc., in sync with new workflows.

---

## 6. Release Process
1. Branch: `release/<version>` once QA sign-off achieved.
2. Bump versions (opam, docs), update changelog/release notes.
3. Run full pipeline: unit + integration tests, smoke tests (ingest + query).
4. Tag the release, publish containers/binaries, communicate rollout instructions.

---

## 7. CI Expectations
- GitHub Actions must be green before merge; treat required status checks as gates.
- If a workflow fails, note the failure in the PR and summarise the root cause / fix.
- Re-run workflows after rebases or flakes; track flaky tests via issues for follow-up.

---

## 8. Quick Do / Don’t Checklist
- ✅ Encapsulate database access behind `Repo_*` modules.
- ✅ Write small, composable functions and favour explicit types.
- ✅ Run `dune fmt && dune build && dune runtest` before pushing.
- ❌ Don’t commit secrets or `.env`; rely on env vars or secret managers.
- ❌ Don’t merge failing pipelines or bypass code review.

---

Last updated: 2025-10-xx (v0.6.2). Keep this guide current alongside the roadmap.
