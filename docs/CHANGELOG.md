# Documentation Changelog

## 2025-10-15 – Snapshot & Load-Testing Refresh
- README and Developer Handbook now highlight the `chessmate collection` snapshot workflow and the updated load-testing harness behaviour (JSON payload handling, Docker stats capture).
- Architecture, CLI odoc pages (`docs/cli.mld`, `docs/query.mld`, `docs/services.mld`) refreshed to reference snapshot tooling and hybrid executor optimisations.
- Runbook/operations docs remain current; `docs/OPERATIONS.md` already documents the snapshot restore order.
- Public interface docstrings (`lib/storage/repo_qdrant.mli`, `lib/cli/collection_command.mli`, `lib/query/hybrid_executor.mli`) now describe parameters and behaviour for snapshot helpers and caching.
