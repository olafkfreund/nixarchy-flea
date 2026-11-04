---
status: draft
issue: 2
intent: intent/2026-11-04-2-ci-build-update.md
---

# Spec: CI that builds, checks and auto-updates Flea

## Decisions (intent approved with the recommended defaults)

| # | Question | Decision |
|---|---|---|
| 1 | Latest build | Upstream releases only. No `flea-git`. |
| 2 | Bump PRs | Always wait for your review. No auto-merge. |
| 3 | Bot identity | Built-in `GITHUB_TOKEN`. No App, no PAT. |
| 4 | Schedule | Upstream release check daily (05:17 UTC). nixpkgs refresh weekly (Mon 05:47 UTC). |
| 5 | Tags | None. Consumers follow `main`. |

## Design

### Files

```
.github/workflows/check.yml   PR / push / dispatch: build + flake check + format
.github/workflows/bump.yml    daily + dispatch: new upstream release → PR, or an issue
.github/workflows/lock.yml    weekly + dispatch: nix flake update → PR, or an issue
scripts/bump.sh               the bump logic, runnable locally, used by bump.yml
scripts/upstream-diff.sh      the PR body: what changed upstream that packaging relies on
README.md                     badge + "what CI proves"
```

### `check.yml` (the required check)

- Triggers: `pull_request`, `push` to `main`, `workflow_dispatch`.
- `permissions: contents: read`. No secrets.
- One job, `check`, on `ubuntu-latest`. Steps:
  1. `actions/checkout`, pinned by SHA
  2. `cachix/install-nix-action`, pinned by SHA (no cache config, just Nix with flakes)
  3. `nix build .#flea -L`
  4. `nix flake check -L` (the #1 checks: layout, service `Exec=` lines, both module
     evals, hm-under-nixos)
  5. format: `nix fmt -- --ci` if the formatter supports it, else
     `nix run .#formatter.x86_64-linux -- --check $(git ls-files '*.nix')`. This is a CI
     step, not a flake check (Codex finding 2).
- No `pull_request_target`, anywhere in the repo.
- `concurrency: check-${{ github.ref }}`, cancel in progress.

### `bump.yml`

- Triggers: `schedule: "17 5 * * *"`, `workflow_dispatch`.
- `permissions: contents: write, pull-requests: write, issues: write, actions: write`.
- Runs `main`'s own code only. It never checks out a PR.
- Steps:
  1. checkout `main`, install Nix
  2. `scripts/bump.sh`, which:
     - reads the current version from `nix/package.nix` (the `version = "x.y.z";` line inside
       `flea-bin`)
     - gets the latest release with `gh release view -R thisisgm/flea --json tagName,isDraft,isPrerelease`,
       skipping drafts and prereleases
     - stops with "up to date" (exit 0) if it is not newer, comparing with `sort -V`
     - downloads `flea-v$V-linux-x86_64.tar.gz.sha256`, converts it with
       `nix hash convert --hash-algo sha256 --to sri`, and checks that it equals
       `nix-prefetch-url`'s hash of the tarball itself. The bytes must match the published
       checksum. That proves integrity only; the release is unsigned (Codex finding 4).
     - rewrites the `version` and `hash` lines (the tarball hash is the only
       `hash = "sha256-…"` in `flea-bin`; the script asserts exactly one match each)
     - runs `nix build .#flea -L` and `nix flake check -L` locally in the job
  3. `scripts/upstream-diff.sh v$OLD v$NEW` writes the PR body. It uses
     `gh api repos/thisisgm/flea/compare/v$OLD...v$NEW` and lists changes to the files the
     packaging fixes depend on: `src/backend/sandbox.rs`, `src/backend/thumbbind.rs`,
     `src/backend/officepdf.rs`, `src/backend/codereq.rs`, `src/shelfplugin.rs`,
     `crates/flea-gui/src/g2/pv3/sandbox.rs`, `packaging/flea-bin/PKGBUILD`, `Makefile`,
     `packaging/*.service`. It also lists added lines that contain `"/usr` or `Command::new("`,
     linking the release notes and a checklist ("jail binds still only /usr+/etc", "no new
     trust check", "install layout unchanged").
  4. Branch `bump/flea-v$NEW` (force-pushed, so a rerun updates the PR), then
     `gh pr create` or `gh pr edit` with the body.
  5. `gh workflow run check.yml --ref bump/flea-v$NEW`. `workflow_dispatch` is one of the
     two events a `GITHUB_TOKEN` may trigger, so this run starts without approval. It
     reports a `check` check run on the branch head, which is what branch protection asks
     for. The PR's own `pull_request` run, created by `GITHUB_TOKEN`, waits for your
     "Approve and run" (Codex finding 3). Either one satisfies the required check.
  6. `if: failure()`: `gh issue create` or `gh issue comment` on the one open issue with
     label `bump-failed`, naming the step and linking the run. When a later bump succeeds,
     it closes that issue.

### `lock.yml`

Same shape as `bump.yml`, with `schedule: "47 5 * * 1"`:
- `nix flake update`; stop if `flake.lock` is unchanged
- build + check
- branch `chore/flake-lock`, a PR titled "flake.lock: update nixpkgs", the dispatched check
- `if: failure()` uses label `lock-failed`

### Schedule liveness (Codex finding 1)

A disabled or dropped schedule cannot report itself, so the guarantee is narrowed:
**every failure after a job starts is reported. A stopped schedule is not, and is caught
by two independent means:**
- Activity keeps the schedule alive. The weekly lock PR (nixpkgs moves weekly) and the
  bump PRs push branches and open PRs. GitHub counts that as repository activity in most
  cases. This is unverified; the risk table carries it.
- `check.yml` on every push to `main` and every PR adds a step `schedule-health`. It
  fails, as a separate non-required job, when the last successful `bump.yml` run is older
  than 3 days or the workflow is `disabled_inactivity`
  (`gh api repos/:owner/:repo/actions/workflows/bump.yml`). A dead bot then shows up
  red on your next PR.
- The README names the one-line manual check:
  `gh run list -R olafkfreund/nixarchy-flea -w bump.yml -L 3`.

### Repo settings (applied once by the plan, via `gh api`)

- Branch protection on `main`: require status check `check`, require a PR, and no
  required approving review. The repo has one maintainer; with a required review you
  could not merge your own PRs without an admin bypass.
- Actions: `default_workflow_permissions = read` (each workflow raises its own), and
  `can_approve_pull_request_reviews = true` so the bot can open PRs. That is the
  "Allow GitHub Actions to create … pull requests" setting.
- Labels `bump-failed` and `lock-failed`.

### README

A badge for `check.yml`. "What CI proves": it builds and evaluates; it cannot run the
GUI, portal, gvfs or GPU checks. "Updates": the bot opens a PR per upstream release, you
review the listed upstream changes and merge, and nixarchy follows `main`. Plus the
manual schedule check.

## Alternatives rejected

- **A binary cache.** Nothing heavy compiles (#1 spec rev. 2). Consumers fetch a 27 MB
  tarball plus nixpkgs paths from `cache.nixos.org`. buildFHSEnv's small init and rootfs
  builder also build once, cold. A cache would add a key to protect and a quota, for
  minutes saved at most.
- **Auto-merge with a GitHub App.** Possible later. It means trusting upstream's unsigned
  releases unreviewed. Rejected by decision 2.
- **Renovate/Dependabot for the version bump.** Neither knows a Nix `fetchurl` hash plus
  upstream's `.sha256` cross-check, nor the upstream-diff PR body. `nix flake update` is
  one command; a bot adds config, not value.
- **`update-flake-lock` (a third-party Action) for `lock.yml`.** It is the same one command
  plus PR plumbing we already write for the bump. One fewer third-party Action holding a
  write token.
- **A formatting flake check instead of a CI step.** It would make `nix flake check` fail
  on style, locally too. A separate step keeps style separate from correctness.

## Risks

| Risk | Mitigation |
|---|---|
| Branch pushes may not count as "activity", and the schedule is disabled after 60 days. | The `schedule-health` job turns red on the next PR. The README check. Re-enable with `gh workflow enable bump.yml`. |
| Upstream renames the asset or drops the `.sha256`. | `bump.sh` fails at download, and the `bump-failed` issue names the step. |
| Upstream ships a release whose layout breaks `installPhase`, or adds code our fixes don't cover. | The build fails (layout), or the PR's upstream-diff list flags it for your review (coverage). The runtime checks in #1 stay manual. |
| `gh workflow run` on a branch: GitHub could change which events `GITHUB_TOKEN` may trigger. | The PR's own approval-required run still exists. The worst case is one extra click. |
| The dispatched check reports on the branch SHA, and a later force-push makes it stale. | The bot dispatches after every push. Branch protection evaluates the head SHA. |
| A pinned Action SHA goes stale. | Out of scope: bump them by hand. The README lists the pins. |

## Verification

1. `actionlint` (via `nix run nixpkgs#actionlint`) passes on all three workflows.
2. `scripts/bump.sh --dry-run` run locally at the current version prints "up to date" and
   exits 0.
3. Script self-check: `scripts/bump.sh --dry-run --pretend-current 0.3.12` finds 0.4.0,
   verifies the checksum, and prints the two rewritten lines without writing.
4. `scripts/upstream-diff.sh v0.3.12 v0.4.0` prints a non-empty file list that includes
   `src/backend/sandbox.rs` if it changed (or says none), with no API error.
5. On GitHub after merge:
   - `check.yml` runs green on the #1 PR
   - `bump.yml` dispatched by hand says "up to date"
   - `lock.yml` dispatched by hand opens a PR (or reports no change), and its dispatched
     check is green
   - the branch protection JSON shows `check` required
