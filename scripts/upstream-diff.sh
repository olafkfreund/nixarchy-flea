#!/usr/bin/env bash
set -euo pipefail

if (($# != 2)) || [[ ! $1 =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ || ! $2 =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo 'usage: upstream-diff.sh vX.Y.Z vX.Y.Z' >&2
  exit 2
fi

gh api "repos/thisisgm/flea/compare/$1...$2" | jq -r --arg old "$1" --arg new "$2" '
  def watched:
    .filename as $name |
    (["src/backend/sandbox.rs", "src/backend/thumbbind.rs", "src/backend/officepdf.rs",
      "src/backend/codereq.rs", "src/shelfplugin.rs", "crates/flea-gui/src/g2/pv3/sandbox.rs",
      "packaging/flea-bin/PKGBUILD", "Makefile"] | index($name)) != null
    or ($name | test("^packaging/[^/]*\\.service$"));
  .files as $files |
  ($files | map(select(watched))) as $watched |
  ([$files[] | select(.patch == null) | .filename]) as $missing |
  ([$files[] | select(.patch != null) | .filename as $name |
    .patch | split("\n")[] | select(startswith("+") and (startswith("+++") | not)) |
    select(contains("\"/usr") or contains("Command::new(\"")) |
    "- `\($name)`: `\(.)` "]) as $lines |
  "# Flea \($old) → \($new)",
  "", "[Release notes](https://github.com/thisisgm/flea/releases/tag/\($new)) · [Compare](https://github.com/thisisgm/flea/compare/\($old)...\($new))",
  "", "## Watched files changed", "",
  (if ($watched | length) == 0 then "none" else $watched[] | "- `\(.filename)` (+\(.additions)/−\(.deletions))" end),
  "", "## Added lines with `\"/usr` or `Command::new(\"`", "",
  (if ($lines | length) == 0 then "none" else $lines[:50][] end),
  (if ($lines | length) > 50 then "(+\(($lines | length) - 50) more)" else empty end),
  (if ($files | length) >= 300 or ($missing | length) > 0 then
    "", "## Inspection incomplete", "",
    (if ($files | length) >= 300 then "- Compare reached the GitHub 300-file limit." else empty end),
    ($missing[] | "- No patch for `\(.)`.")
   else empty end),
  "", "## Review checklist", "",
  "- [ ] Jail binds still use `/usr` and `/etc` only.",
  "- [ ] No new canonical-path trust check.",
  "- [ ] Install layout unchanged.",
  "- [ ] New runtime tools in `depends`?"
'
