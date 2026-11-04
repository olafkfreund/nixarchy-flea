---
status: approved
issue: 2
spec: spec/2026-11-04-2-ci-build-update.md
coders:
  1: codex   # bump.sh: tag validation, checksum cross-check, scoped single-match rewrite (small tricky logic)
  2: codex   # upstream-diff.sh: compare API, truncation/no-patch detection
  3: coder   # check.yml: mechanical YAML
  4: coder   # bump.yml + lock.yml: mechanical YAML around the scripts
  5: agy     # README section: prose
reviewers:
  - agy      # reviews steps 1-2, which codex wrote
  - codex    # reviews steps 3-4, which it did not write
---

# Plan: CI that builds, checks and auto-updates Flea

## Deviations: review corrections (committed with step 1's code)

Codex (gpt-6-sol) and agy reviewed the approved plan. Each correction below fixes a bug
in it without changing an approved decision, and **overrides the step text below** where
the two differ:

- **D1 (steps 1, 4) Outputs.** `bump.sh` writes machine output only to the file named by
  `--output FILE`, one `key=value` per line: `updated=true|false`, and when true, also
  `old=`, `new=` and `hash=`. Human messages go to stderr. The workflow passes
  `--output "$GITHUB_OUTPUT"` and gates later steps with
  `if: steps.bump.outputs.updated == 'true'`. `lock.yml` gates the same way, on
  `steps.lock.outputs.changed`.
- **D2 (step 1) `v` prefix.** After validating the tag, use `new=${tag#v}`, and compare
  and rewrite with the bare `X.Y.Z`.
- **D3 (step 1) Scope.** The `flea-bin` region starts at the first line matching
  `^[[:space:]]*flea-bin[[:space:]]*=` and ends at the **first following** line matching
  `^  };` (its closing brace; lines 81–156 today). If either is missing, exit 2. Count
  `version`/`hash` lines only inside that region. This survives `nixfmt` wrapping and
  names like `sevenzip7z`.
- **D4 (step 3) Format.** Use the flake's formatter, not the registry's:
  `nix run .#formatter.x86_64-linux -- --check $(git ls-files '*.nix')`.
- **D5 (step 3) Fresh-repo health.** No skip. Step 7 dispatches `bump.yml` once before
  protection goes on, so "never run" afterwards is a real failure. On #2's own PR,
  `schedule-health` may be red, which is expected because that job is not required.
- **D6 (step 7) Protection payload.** Send typed JSON, with `gh api -X PUT … --input -`:
  `{"required_status_checks":{"strict":false,"contexts":["check"]},"enforce_admins":false,"required_pull_request_reviews":{"required_approving_review_count":0},"restrictions":null}`.
  Send the Actions endpoint the same way:
  `{"default_workflow_permissions":"read","can_approve_pull_request_reviews":true}`.
- **D7 (steps 7–8) Merge order and the bot-PR test.** `check.yml` cannot run on #1's PR,
  because #2 brings it. #2's branch contains all of #1, so `check.yml` on **#2's PR** is
  the run that builds #1's flake (this replaces the spec's "on the #1 PR"). The merge-box
  test uses the **first lock PR**: same dispatch mechanism, and nixpkgs nearly always
  moves within a week. `--pretend-current` on `main` gives an empty diff, so it is a
  script self-check only. The first real bump PR confirms it again.

## Approved decisions (from spec, self-contained)

- Three workflows, two scripts, README, and repo settings. Built-in `GITHUB_TOKEN` only,
  no secrets, no binary cache, no `pull_request_target`, every Action pinned by SHA.
- Releases only; one bump PR targets the newest upstream release; you review and merge
  every bot PR (procedure, not enforced); no tags; consumers follow `main`.
- Schedules: bump daily `17 5 * * *`, lock weekly `47 5 * * 1` (UTC).
- `check.yml` job `check` is the one required status. It runs build, `nix flake check`,
  smoke (after `sysctl kernel.apparmor_restrict_unprivileged_userns=0`) and format. A
  second non-required job, `schedule-health`, has `actions: read`.
- Bump/lock jobs: `contents|pull-requests|issues|actions: write`. They build, check and
  smoke before opening a PR, then `gh workflow run check.yml --ref <branch>`. On failure
  they open or update one issue (`bump-failed` / `lock-failed`), and close it on the next
  success.
- Branch protection: require `check` and a PR, with no required review. Actions default
  token read-only, and Actions may create PRs.

Pinned Actions (checked 2026-11-04):
- `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1` (v7.0.1, 2026-07-20)
- `cachix/install-nix-action@448cde739abec1eaf0646249e3d25bb8d9bc7702` (v31.11.2,
  2026-10-14; v31.11.3 is newer but under two weeks old)

Facts the steps depend on (from #1, plan rev. 2):
- `nix/package.nix` has `flea-bin = stdenvNoCC.mkDerivation rec { pname = "flea-bin"; version = "0.4.0"; src = fetchurl { url = …; hash = "sha256-…"; }; … }`.
  Those are the only `version`/`hash` lines inside `flea-bin`.
- The FHS env is `.#packages.x86_64-linux.flea.fhs`. Its runner is `$fhs/bin/flea-fhs`.
- Upstream assets: `flea-v$V-linux-x86_64.tar.gz` and `flea-v$V-linux-x86_64.tar.gz.sha256`
  (`<64 hex>  <name>`).

Repo traps:
- This branch (`ci/2-build-update-workflows`) must be rebased onto
  `feat/flea-nix-package` once #1's step 3 lands, because `check.yml` builds `.#flea`.
- Every script is `#!/usr/bin/env bash` with `set -euo pipefail`, and is shellcheck-clean.
- Every commit names its step and ends with the session's attribution lines.

## Steps

1. **`scripts/bump.sh`** (new)
   - Flags: `--dry-run` (print, write nothing), `--pretend-current X.Y.Z` (use instead of
     the file's version; for the self-check). Environment: `GH_TOKEN` comes from the job;
     locally, your `gh` login.
   - Read the current version: `awk` between `/flea-bin = stdenvNoCC.mkDerivation/` and the
     first following line matching `^  [a-zA-Z-]+ =` at the same indent, or the end of the
     `let`. Exactly one `version = "…";` there, otherwise exit 2 with "flea-bin version
     not found exactly once".
   - Latest release: `gh release view -R thisisgm/flea --json tagName,isDraft,isPrerelease`.
     Refuse a draft or prerelease (exit 0, "latest is draft/prerelease"). Validate
     `^v[0-9]+\.[0-9]+\.[0-9]+$`, else exit 3.
   - Newer? `printf '%s\n%s\n' "$cur" "$new" | sort -V | tail -1` equals `$new`, and
     `$new != $cur`. Otherwise print "up to date ($cur)" and exit 0.
   - Checksum: download the `.sha256` asset (`gh release download … -p '*.tar.gz.sha256' -O -`).
     The first field must match `^[0-9a-f]{64}$`, else exit 4. Then
     `published=$(nix hash convert --hash-algo sha256 --to sri "$hex")`,
     `actual=$(nix hash convert --hash-algo sha256 --to sri "$(nix-prefetch-url --type sha256 "$url")")`.
     Unequal → exit 5 with both values.
   - Rewrite (skipped with `--dry-run`, which prints both new lines instead): in the same
     scoped region, replace the single `version = "…";` and the single `hash = "sha256-…";`,
     asserting the counts again after the edit.
   - Print `old=$cur new=$new hash=$published` as the last line (for `$GITHUB_OUTPUT`).
   → verify (me): `scripts/bump.sh --dry-run` → `up to date (0.4.0)`, exit 0;
     `scripts/bump.sh --dry-run --pretend-current 0.3.12` → prints the 0.4.0 lines and
     `hash=sha256-76RmxJFiKMrW43T58zshbvI29TUVdY/dxQLGly9cUNc=`, exit 0, and `git status` is clean;
     `nix run nixpkgs#shellcheck -- scripts/bump.sh` is clean.
   Traps: `nix-prefetch-url` prints Nix32. Convert it; never compare the raw strings.

2. **`scripts/upstream-diff.sh OLD NEW`** (new; both are `vX.Y.Z`, validated the same way)
   - `gh api "repos/thisisgm/flea/compare/$OLD...$NEW"` → JSON.
   - Watched files: `src/backend/sandbox.rs`, `src/backend/thumbbind.rs`,
     `src/backend/officepdf.rs`, `src/backend/codereq.rs`, `src/shelfplugin.rs`,
     `crates/flea-gui/src/g2/pv3/sandbox.rs`, `packaging/flea-bin/PKGBUILD`, `Makefile`,
     and `packaging/*.service` (glob match in `jq`).
   - Output Markdown, written to stdout:
     - a header with links to the release notes and the compare page
     - "Watched files changed": each with +/− counts, or "none"
     - "Added lines with `\"/usr` or `Command::new(\"`": from each file's `patch`, `+`
       lines only, capped at 50 with "(+N more)"
     - **"Inspection incomplete"** when `.files | length >= 300`, or when any changed
       file lacks `.patch`, naming those files
     - the checklist: jail binds still `/usr`+`/etc` only; no new canonical-path trust
       check; install layout unchanged; new runtime tools in `depends`?
   → verify (me): `scripts/upstream-diff.sh v0.3.12 v0.4.0` exits 0 and prints the
     sections; shellcheck clean.
   Traps: one `gh api` call (no pagination; the cap is the point). `jq -r` with
   `--arg`s, never string-built filters.

3. **`.github/workflows/check.yml`** (new), as the spec's "check.yml", with:
   - `on: pull_request`, `push: branches: [main]`, `workflow_dispatch`
   - top-level `permissions: contents: read`, and
     `concurrency: { group: check-${{ github.ref }}, cancel-in-progress: true }`
   - job `check` (`runs-on: ubuntu-latest`, `timeout-minutes: 30`): checkout → install-nix
     (with `extra_nix_config: experimental-features = nix-command flakes`) →
     `nix build .#flea -L` → `nix flake check -L` → smoke → format
     - smoke is one step, `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0`,
       then the #1 plan step 3 in-env checks. Version: compare `/usr/bin/flea --version`
       with `nix eval --raw .#flea-bin.version`.
     - format: `nix run nixpkgs#nixfmt -- --check $(git ls-files '*.nix')`
   - job `schedule-health` (`permissions: actions: read`, `continue-on-error: false`, not
     required): `gh api repos/${{ github.repository }}/actions/workflows/bump.yml -q .state`
     must be `active`. `gh run list -w bump.yml -s success -L 1 --json createdAt` must be
     newer than 3 days. **Skip both** while `bump.yml` has never run (fresh repo), with a
     notice.
   → verify (me): `nix run nixpkgs#actionlint` is clean.
   Traps: `env: GH_TOKEN: ${{ github.token }}` for `gh`. No `${{ }}` inside `run:` scripts
   other than via `env:` (injection hygiene).

4. **`.github/workflows/bump.yml` and `lock.yml`** (new)
   - bump: `on: schedule` (`17 5 * * *`) and `workflow_dispatch` (inputs:
     `pretend_current`, optional). Permissions as decided. Steps:
     - checkout `main`, install-nix
     - `scripts/bump.sh` (passing `--pretend-current` when the input is set), output to
       `$GITHUB_OUTPUT`; if "up to date", end successfully
     - build, flake check, smoke (same commands as check.yml)
     - `scripts/upstream-diff.sh "v$old" "v$new" > body.md`
     - `git switch -C "bump/flea-v$new"`, commit as `github-actions[bot]`
       ("flea: $old -> $new"), `git push -f origin HEAD`
     - `gh pr create … --body-file body.md`, or `gh pr edit` if the PR exists
     - `gh workflow run check.yml --ref "bump/flea-v$new"`
     - on success: close an open `bump-failed` issue with a comment
     - `if: failure()`: create or comment on the `bump-failed` issue with the step name and
       `$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID`
   - lock: `on: schedule` (`47 5 * * 1`) and `workflow_dispatch`. Same shape:
     `nix flake update`; `git diff --quiet flake.lock` → end; build/check/smoke; branch
     `chore/flake-lock`; PR "flake.lock: update nixpkgs" with the `nix flake metadata`
     diff as the body; dispatch check; `lock-failed` issue.
   - `concurrency: bump` / `concurrency: lock`, not cancelling.
   → verify (me): actionlint clean; a read-through that `scripts/bump.sh` output parsing
     matches its last line.
   Traps: `git config user.name github-actions[bot]` and
   `user.email 41898282+github-actions[bot]@users.noreply.github.com`.

5. **`README.md`**: add a "CI and updates" section to #1's README: the badge
   (`actions/workflows/check.yml/badge.svg`); what CI proves (build, eval, smoke, format;
   not GUI, portal, gvfs or GPU); how updates arrive (bot PR, review the listed upstream
   changes, merge); "inspection incomplete" meaning; the manual liveness check
   `gh run list -R olafkfreund/nixarchy-flea -w bump.yml -L 3`; the fallback if a bot PR
   shows no check (close and reopen it).
   → verify: every command in it has been run once by me in step 6 or 8.

6. **Local verification** (me): rebase onto `feat/flea-nix-package` (after #1 step 3),
   actionlint, shellcheck, step 1 and 2 checks, and `act`-free dry runs of each workflow's
   shell by hand.

7. **Merge order and repo settings** (me, after you approve each merge):
   1. merge #1's PR (there is no protection yet)
   2. open #2's PR. `check.yml` runs on it, and you merge
   3. then apply settings with `gh api`:
      - `PUT repos/olafkfreund/nixarchy-flea/branches/main/protection` with
        `required_status_checks.contexts=["check"]`, `strict=false`,
        `required_pull_request_reviews` set to require a PR with 0 approvals,
        `enforce_admins=false`
      - `PUT repos/…/actions/permissions/workflow` with
        `default_workflow_permissions=read`, `can_approve_pull_request_reviews=true`
      - `gh label create bump-failed` and `lock-failed`

8. **Live verification** (me): dispatch `check.yml` on `main` (green, including smoke);
   dispatch `bump.yml` ("up to date"); dispatch `lock.yml` (a PR or "no change"). If a
   lock PR opens, check the merge box: `check` must be satisfied by the dispatched run.
   This is spec verification 5's bot-PR test. If it fails, the fallback (close and reopen)
   goes in the README and in this plan. Record results in the PR.

9. **Review and PR** (me): fresh Opus review of `git diff` against this plan; agy reviews
   steps 1–2, Codex reviews steps 3–4 (read-only). The PR links intent, spec and plan, and
   says which steps each coder did.

## Tests

| Command | Expected |
|---|---|
| `scripts/bump.sh --dry-run` | `up to date (0.4.0)`, exit 0, tree clean |
| `scripts/bump.sh --dry-run --pretend-current 0.3.12` | 0.4.0 lines + the known SRI hash, exit 0, tree clean |
| `scripts/upstream-diff.sh v0.3.12 v0.4.0` | sections printed, exit 0 |
| `nix run nixpkgs#shellcheck -- scripts/*.sh` | clean |
| `nix run nixpkgs#actionlint` | clean |
| `check.yml` on GitHub | green: build, flake check, smoke, format |
| dispatched `bump.yml` / `lock.yml` | "up to date" / a PR or no change; no failure issue |

## Rollback

Delete `.github/workflows/*` and `scripts/*`, or revert the merge. Remove branch protection
with `gh api -X DELETE repos/olafkfreund/nixarchy-flea/branches/main/protection`, and put
the Actions setting back. Close any bot PRs and issues. Nothing outside this repo changes.
