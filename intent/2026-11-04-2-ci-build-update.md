---
status: draft
issue: 2
author: olafkfreund
---

# Intent: CI that builds, tests and auto-updates Flea, and publishes the latest build

## Problem

The repo (github.com/olafkfreund/nixarchy-flea, public) has no CI. Nothing proves that
`main` builds, that the modules evaluate, or that a change did not break the package.

Upstream `thisisgm/flea` releases often: v0.3.11 on 2026-10-15, v0.3.12 on 2026-10-16,
v0.4.0 on 2026-11-03. Each bump means a new version, a source hash, and a cargo
`outputHashes` entry when the GPUI fork rev moves. The two `.patch` files may also stop
applying. Done by hand, this falls behind quickly.

A consumer (nixarchy) that takes this flake as an input would compile Flea locally on
every update. That is the GPUI workspace with LTO and one codegen unit, so it is slow. It
also has no signal that a given `main` commit is known to build.

## Proposed outcome

- Every PR and every push to `main` runs `nix flake check` and builds `.#flea`. A red
  check blocks merging.
- A scheduled job detects a new upstream release. It bumps the version and hashes,
  confirms the patches still apply, and opens a PR that runs the same checks. The PR
  says plainly when a patch no longer applies.
- `nixpkgs` in `flake.lock` is refreshed on a schedule through the same PR + checks path.
- Built outputs are pushed to a public binary cache. A consumer on the latest `main`
  downloads Flea instead of compiling it.
- `main` is always buildable, so "use the latest build" means "follow `main`".

## Affected users and systems

- This repo: `.github/workflows/`, `flake.lock`, `nix/package.nix` (version and hashes
  only, changed by the bot), README (badge, cache instructions).
- GitHub Actions on hosted x86_64 runners, repo settings (branch protection, secrets).
- Consumers: nixarchy hosts, which gain a substituter entry.

## Constraints

- Depends on #1: the workflows run the flake that #1 produces, so this branch is based
  on `feat/flea-nix-package` and merges after it.
- Hosted runners have a disk limit (about 14 GB free on the standard image). The closure,
  with qt6-webengine and the GPUI build, may need cleanup or a larger runner.
- PRs opened with the default `GITHUB_TOKEN` do not trigger workflows. The bump PR needs a
  GitHub App token or a fine-grained PAT, stored as a secret.
- No secret may appear in logs or in the public repo. Cache signing keys and tokens live in
  repo secrets only.
- The runtime checks from #1 (GUI, portal, gvfs, GPU) cannot run in CI. CI proves "builds
  and evaluates", not "works on the desktop", and the README must say so.
- Pin every Action to a commit SHA (supply-chain hygiene for a public repo).

## Open questions

1. "Latest build": the latest upstream **release** (tags) only, or also a `flea-git`
   package that tracks upstream `main`?
2. Binary cache: Cachix (a free public cache; needs an account and an auth-token secret),
   FlakeHub Cache, or your own (e.g. attic on p510)?
3. Bump PRs: auto-merge when checks pass, or always wait for your review?
4. Schedule: how often to look for upstream releases (daily?) and to refresh nixpkgs
   (weekly?).
5. Bot identity: a GitHub App (preferred, scoped) or a fine-grained PAT for opening PRs?
6. Releases in this repo: tag each bump (e.g. `v0.4.0-1`) so consumers can pin a version,
   or is following `main` enough?
