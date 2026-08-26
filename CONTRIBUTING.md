<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 lituus-lab -->
# Contributing

## License

Apache-2.0 (`LICENSE`).

## DCO

Every commit signs off the [Developer Certificate of Origin](https://developercertificate.org/):

```bash
git commit -s
```

Commits without a `Signed-off-by` trailer are not accepted.

## Conventional commits

Commit subjects and the PR title follow [Conventional Commits 1.0](https://www.conventionalcommits.org/):

```
<type>(scope)!: <description>
```

`type` is one of `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`,
`build`, `ci`, `chore`, `revert`, `bump`. `scope` and `!` (breaking change) are
optional. A space separates the colon from the description.

```
feat(catalog): add incremental scan
fix(undo): refuse a destination whose hash changed
docs: explain the library-root invariant
feat(store)!: migrate batch operation states
```

The `commitizen` CI job checks the PR title, and the commit message too when the
PR holds exactly one commit. The title matters because a squash-merge folds the
whole PR into one commit whose subject is the title. Every commit message is
checked locally by the pre-commit hook below.

## Workflow

1. Branch from `main`, one logical change per commit.
2. Pass the gates: `nimble testAll`, `nimble lint`, `nimble checkVGraph`.
3. Open a PR; CI runs the 3-OS Nim matrix, docs, lint and dependency graph checks.

## Pre-commit

The CI gates also run locally via [pre-commit](https://pre-commit.com):

```bash
pip install pre-commit
pre-commit install
```

`pre-commit install` sets up the pre-commit, pre-push and commit-msg hooks at
once. Hooks: hygiene (trailing whitespace, EOF, yaml/toml, large files),
`nimble lint` on `*.nim`, `nimble checkVGraph` before push, Conventional Commits
via `cz check` on the commit message, and a DCO sign-off check. Run everything
manually:

```bash
pre-commit run --all-files
```

## Conventions

See `ADRs/0004` and `AGENTS.md`. English comments, terse, describe what is done.
NimContracts compile away under `-d:release`. ADR-0003 records why no C/Python
surface is frozen yet.
