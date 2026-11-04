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

- Every PR and every push to `main` builds `.#flea` and runs the flake's defined checks
  (layout, service `Exec=` lines, module evaluation, formatting). That is the whole claim:
  upstream's test suite is off (#1 plan), so CI proves "builds and evaluates", not "works".
  A required check blocks merging, through branch protection.
- A scheduled job detects a new upstream release. It bumps the version, the source hash
  and the cargo git hashes, including a new `outputHashes` **key** when upstream's
  `Cargo.lock` changes a git crate's name or version. It confirms the patches still
  apply and opens a PR that runs the same checks.
- A bump that cannot resolve hashes or apply patches never advances `main`, and it never
  fails silently in a cron log. It opens or updates an issue or a draft PR saying which
  step failed.
- `nixpkgs` in `flake.lock` is refreshed on a schedule through the same PR + checks path.
- Built outputs (`flea` and `flea-unwrapped`, the expensive Rust build) are pushed to a
  public binary cache, and only after a successful build of a commit on `main`. A
  consumer that evaluates the same derivation downloads it instead of compiling it.
  CI verifies that the cache actually serves the pushed paths.
- "Use the latest build" means "follow `main`", with a stated guarantee: every `main`
  commit passed the PR checks, and its outputs are in the cache once the push job is
  green. A cache miss (upload not finished or failed, a different nixpkgs, an override)
  makes Nix compile locally. That is slower, not broken.

## Affected users and systems

- This repo: `.github/workflows/`, `flake.lock`, `nix/package.nix` (version and hashes
  only, changed by the bot), README (badge, cache instructions).
- GitHub Actions on hosted x86_64 runners, repo settings (branch protection, secrets).
- Consumers: nixarchy hosts, which gain a substituter entry.

## Constraints

- Depends on #1: the workflows run the flake that #1 produces, so this branch is based
  on `feat/flea-nix-package` and merges after it.
- Standard public Linux runners: 4 vCPU, 16 GB RAM, about 14 GB SSD **in total**, and a
  6-hour job limit. A cold LTO + `codegen-units = 1` build of the GPUI workspace, plus a
  closure with qt6-webengine, risks disk, RAM (LTO link) and time. A measured cold build
  within the chosen runner's limits is an acceptance condition before hosted CI counts
  as viable.
- Tokens: events caused by the default `GITHUB_TOKEN` traditionally do not start new
  workflow runs. That covers a bot PR's checks and the `push` run after a bot merge, which
  is what pushes to the cache. Reviewers disagree on whether GitHub now starts such PR runs
  pending approval. The spec settles it from current docs. Either way, a GitHub App or
  PAT is needed if bump PRs must be checked, merged and cached without you.
- **Trust boundary in a public repo:** PR code is untrusted, since a build runs whatever
  the PR's Nix says. PR workflows get no cache-write token, signing key or write-scoped
  token, and `pull_request_target` never builds PR code. Cache publication runs only on
  `push` to `main` (and release tags), from code already reviewed into `main`.
- Cache trust: consumers trust the cache's public signing key, and whoever holds the
  private key can serve them anything. The key lives only in repo secrets, is documented
  in the README, and is used only by the `main` publish job.
- Cache size: free tiers are small (Cachix free is 5 GB). Push only paths that are not
  already on `cache.nixos.org`, i.e. Flea's own outputs, not nixpkgs dependencies.
- Patch rot has two forms. A patch that fails to apply is caught by the build. A patch
  that applies but no longer covers new upstream code (a new jail, a new `/usr` check) is
  not. Each bump PR lists the upstream changes to `sandbox.rs`, `thumbbind.rs`,
  `shelfplugin.rs` and any new `"/usr` literal, for human review.
- Scheduled workflows are best effort. GitHub delays them, and disables them in public
  repos after 60 days without activity. Something must keep the schedule alive, or report
  that it stopped.
- The runtime checks from #1 (GUI, portal, gvfs, GPU) cannot run in CI. CI proves "builds
  and evaluates", not "works on the desktop", and the README must say so.
- Pin every Action to a commit SHA (supply-chain hygiene for a public repo).

## Open questions

0. **How should consumers get cache hits?** The #1 modules build Flea from the
   *consumer's* `pkgs` (`pkgs.callPackage`). Unless nixarchy's nixpkgs rev equals this
   flake's lock, every store path differs and the cache never hits. Options: (a) nixarchy
   sets `programs.flea.package = inputs.nixarchy-flea.packages.x86_64-linux.flea`, with no
   `nixpkgs.follows` (cache hits, a second nixpkgs in the closure); (b) keep `follows` and
   accept local builds; (c) change #1's module default to the flake's own package (a #1
   spec change). This decides whether the cache is worth having at all.

1. "Latest build": the latest upstream **release** (tags) only, or also a `flea-git`
   package that tracks upstream `main`?
2. Binary cache: who operates it and holds its key? Cachix (hosted, 5 GB free, an
   auth-token secret), FlakeHub Cache, or your own attic on p510 (needs public ingress
   and uptime fit for a public repo)?
3. Bump PRs: auto-merge when checks pass, or always wait for your review?
4. Schedule: how often to look for upstream releases (daily?) and to refresh nixpkgs
   (weekly?).
5. Bot identity, coupled with 3: with auto-merge and branch protection that requires a
   review, a PAT tied to your account cannot approve its own PR. A GitHub App (or a
   ruleset bypass for it) can. App, PAT, or neither (bump PRs wait for you, and checks run
   on your approval)?
6. Releases in this repo: tag each bump (e.g. `v0.4.0-1`) so consumers can pin a version,
   or is following `main` enough?
7. Cache roots: push both `.#flea` and `.#flea-unwrapped`, so the Rust build is reused
   when a consumer enables optional dependencies (only the cheap FHS wrapper rebuilds)?
