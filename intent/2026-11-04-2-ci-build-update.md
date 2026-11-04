---
status: draft
issue: 2
author: olafkfreund
---

# Intent: CI that builds, checks and auto-updates Flea

> **Revision 2 (2026-11-04):** #1 switched to upstream's prebuilt release binaries (#1 spec
> rev. 2), so nothing heavy is compiled. The binary cache, its signing key and quota, and
> the runner disk and time limits are gone from scope. Upstream's tarball is the
> "prebuilt" artifact, and GitHub serves it.

## Problem

The repo (github.com/olafkfreund/nixarchy-flea, public) has no CI. Nothing proves that
`main` builds, that the modules evaluate, or that a change did not break the package.

Upstream `thisisgm/flea` releases often: v0.3.11 on 2026-10-15, v0.3.12 on 2026-10-16,
v0.4.0 on 2026-11-03. Each release means a new version and a new tarball hash in
`nix/package.nix`. A release can also change the tarball layout, which breaks `installPhase`,
or add code that the packaging fixes don't cover: a new jail, a new `/usr` trust check, a
new thumbnailer. Done by hand, this falls behind quickly, and nixarchy stays on an old
Flea.

## Proposed outcome

- Every PR and every push to `main` builds `.#flea` and runs `nix flake check` (layout,
  service `Exec=` lines, module evaluation, formatting). That is the whole claim. CI
  proves "builds and evaluates", not "works on the desktop", and the README says so.
  A required check blocks merging, through branch protection.
- A scheduled job detects a new upstream release. It sets the version and the tarball hash,
  cross-checked against upstream's published `.sha256`. It builds and checks, then opens a
  PR. The PR body lists what changed upstream in the files the packaging fixes depend on
  (`src/backend/sandbox.rs`, `thumbbind.rs`, `officepdf.rs`, `codereq.rs`, `shelfplugin.rs`,
  `crates/flea-gui/src/g2/pv3/sandbox.rs`, `packaging/flea-bin/PKGBUILD`) and any new
  `"/usr` literal, for human review.
- A bump that fails (hash mismatch, layout change, a failing check) never advances `main`.
  It never fails silently in a cron log either: it opens or updates one issue saying which
  step failed.
- `nixpkgs` in `flake.lock` is refreshed on a schedule through the same PR + checks path.
- "Use the latest build" means "follow `main`". Every `main` commit passed the checks,
  and a consumer's rebuild is a tarball download plus the FHS env assembly. No
  compiling, so no binary cache is needed.

## Affected users and systems

- This repo: `.github/workflows/`, `flake.lock`, `nix/package.nix` (version and hash only,
  changed by the bot), README (badge, "what CI proves").
- GitHub Actions on hosted x86_64 runners, repo settings (branch protection, Actions
  permission to create PRs).
- Consumers: nixarchy, which follows `main`. Nothing to configure.

## Constraints

- Depends on #1: the workflows run the flake that #1 produces, so this branch is based on
  `feat/flea-nix-package` and merges after it.
- Tokens: events caused by the default `GITHUB_TOKEN` traditionally do not start new
  workflow runs. That affects a bot PR's checks. The rev. 1 reviewers disagreed on whether
  GitHub now starts them pending approval, and the spec settles it from current docs.
  Either way, a GitHub App or a PAT is needed if bump PRs must be checked and merged
  without you.
- **Trust boundary in a public repo:** PR code is untrusted. PR workflows get only a
  read-only token, and `pull_request_target` never builds PR code. With no cache, no
  workflow holds a publishing secret. Only the bump job writes (a branch and a PR), and it
  runs on `schedule`/`workflow_dispatch` from `main`'s own code.
- Upstream supply chain: the tarball is upstream's binary, which runs on your desktop. The
  bump verifies it against upstream's `.sha256` from the same release. That proves
  integrity, not provenance: upstream signs nothing. Auto-merging a bump means trusting
  upstream's release account. That is open question 2.
- Scheduled workflows are best effort. GitHub delays them, and disables them in public
  repos after 60 days without activity. Something must keep the schedule alive, or report
  that it stopped.
- Pin every Action to a commit SHA (supply-chain hygiene for a public repo).

## Open questions

1. "Latest build": upstream **releases** only, or also a `flea-git` package built from
   upstream `main`? That would bring back the source build, a cache, and the 12-minute
   compile.
2. Bump PRs: auto-merge when checks pass (you trust upstream's releases as-is), or always
   wait for your review (the PR lists the upstream changes that matter)?
3. Bot identity, coupled with 2: auto-merge needs a GitHub App or a PAT. With "always
   review", the built-in token is enough, and checks run on your approval or when you
   push to the PR.
4. Schedule: look for upstream releases daily, and refresh nixpkgs weekly?
5. Tag each bump in this repo (e.g. `v0.4.0-1`) so consumers can pin, or is following
   `main` enough?
