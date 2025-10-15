# Collaboration & Quality Guidelines

This document complements the [Developer Handbook](DEVELOPER.md), [Testing Plan](TESTING.md), and [Operations Playbook](OPERATIONS.md). Use it as the concise checklist for how we collaborate and keep Chessmate in top shape.

---

## 1. Communication & Planning
- Track work in GitHub Issues; every PR references its parent issue.
- Record design decisions in `ADR/` (template: `ADR-000-template.md`). Seeded ADR-001..004 cover language choice, hybrid retrieval, rate limiting, and Caqti adoption.
- Share daily async updates (progress, blockers, next steps) in the team channel.

---

## 2. Branching & PR Hygiene
- Branch naming: `feature/<topic>`, `fix/<issue-id>`, `docs/<subject>`.
- Keep PRs under ~400 lines; split refactors into reviewable slices.
- PR template checklist: summary, testing evidence (`dune build`, `dune runtest`, integration steps), migration impact, rollback plan.
- Require at least one peer review focused on correctness, resiliency, and test coverage.
- No direct pushes to `main`; protected branch rules + required status checks enforce lint/tests.

---

## 3. Coding Standards
- **Functional-first**: prefer pure functions, immutability, combinators (`List.map`, `Option.bind`, `Result.map`), and `Or_error.t` for recoverable failures. Avoid mutation unless there’s a clear justification.
- **OCaml style**: `open! Base`, provide `.mli` interfaces, avoid `Stdlib` unless necessary.
- **Separation of concerns**: keep `lib/chess` pure; place side effects (IO, DB, network) in `lib/storage` or service modules.
- Use pattern matching, avoid partial functions, add concise comments for non-obvious logic.
- Run `dune fmt` (ocamlformat profile `conventional`, version `0.27.0`) before committing. CI runs `dune build @fmt`.

---

## 4. Testing Expectations
- Write Alcotest unit tests for new modules; store fixtures under `test/`.
- Integration tests (dockerised Postgres/Qdrant) need tagged roles with `CREATEDB`; run via `dune exec test/test_main.exe -- test integration`.
- Update curated natural-language queries when behaviour changes and document acceptance criteria.
- Never merge with red tests; if you must skip a test, file an issue with justification.

---

## 5. Documentation & Runbooks
- Keep `IMPLEMENTATION_PLAN.md` and `ARCHITECTURE.md` current.
- Maintain `.mld` odoc pages (`docs/*.mld`) alongside Markdown docs; they feed the generated documentation site.
- Add runbooks under `runbooks/` and incident retrospectives under `INCIDENTS/`.

---

## 6. Release Process
1. Branch: `release/<version>` once QA sign-off achieved.
2. Bump versions (opam, docs), update changelog/release notes.
3. Run full pipeline: unit + integration tests, smoke tests (ingest + query).
4. Tag the release, publish containers/binaries, communicate rollout instructions.

---

## 7. CI Expectations
- GitHub Actions must be green before merge; treat required status checks as gates.
- If a workflow fails, note the failure in the PR and summarise the root cause/fix.
- Re-run workflows after rebases or flakes; track flaky tests via issues for follow-up.

---

## 8. Quick Do / Don’t Checklist
- ✅ Use functional idioms (pure functions, combinators, `Or_error.t`, pattern matching).
- ✅ Encapsulate database access behind `Repo_*` modules.
- ✅ Keep `.mld` odoc pages updated with doc changes.
- ✅ Run `dune fmt && dune build && dune runtest` before pushing.
- ❌ Don’t commit secrets or `.env`; rely on environment variables or secret managers.
- ❌ Don’t merge failing pipelines or bypass code review.

---

Last updated: 2025-10-xx (v0.6.3). Keep this guide current alongside the roadmap.
