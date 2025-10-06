# Collaboration & Quality Guidelines

## Communication
- Use GitHub Issues for roadmap items and bug reports; link every PR to its parent issue.
- Capture design decisions in `docs/ADR-<id>.md`; summarize outcome and trade-offs.
- Daily async updates: share progress, blockers, next steps in the team channel.

## Branching & PR Hygiene
- Branch naming: `feature/<topic>`, `fix/<issue-id>`, `docs/<subject>`.
- Keep PRs under ~400 lines; split large efforts into reviewable slices.
- PR template must include: summary, testing evidence (`dune build`, `dune test`, integration steps), migration impact, rollback plan.
- Require at least one peer review; reviewers focus on correctness, resiliency, and test coverage.
- No direct pushes to `main`; use protected branch rules and status checks (lint, tests) before merge.

## Coding Standards
- OCaml: `open! Base`, explicit interfaces (`.mli`), no `Stdlib` unless necessary; prefer `Or_error.t` for recoverable failures.
- CLI/services: centralize side effects in `lib/storage` modules, keep `lib/chess` pure.
- Use pattern matching, avoid partial functions, add concise comments for non-obvious logic.
- Apply `dune fmt` before commits; ensure `dune build` and `dune test` pass locally.
- Keep GPL notice headers at the top of every source/interface file; copy the template from existing modules when adding new files.

## Testing Expectations
- Unit tests with Alcotest for each new module; co-locate fixtures under `test/`.
- Integration tests require dockerized Postgres/Qdrant; mark with `[@tags "integration"]` once tagging is wired.
- Regression suite: update curated NL queries when behavior changes, and document acceptance criteria.
- Broken tests must be fixed or skipped with justification in issue tracker, never left red on `main`.

## Documentation
- Keep `docs/IMPLEMENTATION_PLAN.md` updated after major milestones or scope changes.
- Update `docs/ARCHITECTURE.md` when component boundaries or data flows evolve.
- Add service runbooks or incident retrospectives under `docs/` as issues arise.

## Release Process
1. Cut release branch `release/<version>` once QA sign-off achieved.
2. Bump version numbers (opam, docs) and update changelog.
3. Run full pipeline: unit + integration tests, end-to-end smoke (embedding + query).
4. Tag release, publish containers, and notify stakeholders with deployment instructions.

## Coding Do/Don’t Quick List
- Do encapsulate database access behind `Repo_*` modules.
- Do write small, composable functions and favour explicit types.
- Don’t commit secrets or `.env` files; rely on environment variables or secret managers.
- Don’t merge failing pipelines or bypass code review.

## Continuous Integration Expectations
- GitHub Actions must be green before merge; enable required status checks on `main`.
- Include CI badge in PR descriptions if the pipeline fails, along with a summary of the root cause and remediation plan.
- Re-run workflows via the Actions tab after rebases or flaky failures; document flakes in an issue for follow-up.
