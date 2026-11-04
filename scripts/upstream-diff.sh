#!/usr/bin/env bash
set -euo pipefail

tag='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
if (($# != 2)) || [[ ! $1 =~ $tag || ! $2 =~ $tag ]]; then
  echo 'usage: upstream-diff.sh vX.Y.Z vX.Y.Z' >&2
  exit 2
fi

# Upstream text is untrusted Markdown: backticks and angle brackets are replaced, lines are cut
# at 200 characters, and lines from watched files come first so a cap never hides them.
gh api "repos/thisisgm/flea/compare/$1...$2" | jq -r --arg old "$1" --arg new "$2" '
  def clean: gsub("[`<>]"; "\u0027") | .[0:200];
  def watchlist: ["src/backend/sandbox.rs", "src/backend/thumbbind.rs", "src/backend/officepdf.rs",
      "src/backend/codereq.rs", "src/shelfplugin.rs", "crates/flea-gui/src/g2/pv3/sandbox.rs",
      "packaging/flea-bin/PKGBUILD", "Makefile"];
  def watchedname: . as $n | (watchlist | index($n)) != null or ($n | test("^packaging/[^/]*\\.service$"));
  def watched: (.filename | watchedname) or ((.previous_filename // "") | watchedname);
  .files as $files |
  ($files | map(select(watched))) as $watched |
  ([$files[] | select(.patch == null) | .filename | clean]) as $missing |
  def hits: [.[] | select(.patch != null) | (.filename | clean) as $name |
    .patch | split("\n")[] | select(startswith("+") and (startswith("+++") | not)) |
    select(contains("\"/usr") or contains("Command::new(\"")) | "- `\($name)`: `\(clean)`"];
  ($files | map(select(watched)) | hits) as $wlines |
  ($files | map(select(watched | not)) | hits) as $olines |
  ($wlines + $olines) as $lines |
  ($lines | length > 50) as $capped |
  "# Flea \($old) → \($new)",
  "", "[Release notes](https://github.com/thisisgm/flea/releases/tag/\($new)) · [Compare](https://github.com/thisisgm/flea/compare/\($old)...\($new))",
  "", "## Watched files changed", "",
  (if ($watched | length) == 0 then "none" else $watched[] |
     "- `\(.filename | clean)`\(if .previous_filename then " (renamed from `\(.previous_filename | clean)`)" else "" end) (+\(.additions)/−\(.deletions))" end),
  "", "## Added lines with \u0027\"/usr\u0027 or \u0027Command::new(\"\u0027 (watched files first)", "",
  (if ($lines | length) == 0 then "none" else $lines[:50][] end),
  (if $capped then "(+\(($lines | length) - 50) more, not shown)" else empty end),
  (if ($files | length) >= 300 or ($missing | length) > 0 or $capped then
    "", "## Inspection incomplete", "",
    (if ($files | length) >= 300 then "- Compare reached the GitHub 300-file limit." else empty end),
    (if $capped then "- More than 50 matching lines; only the first 50 are listed." else empty end),
    ($missing[] | "- No patch for `\(.)`.")
   else empty end),
  "", "## Review checklist", "",
  "- [ ] Jail binds still use /usr and /etc only.",
  "- [ ] No new canonical-path trust check.",
  "- [ ] Install layout unchanged.",
  "- [ ] New runtime tools in depends?"
' | head -c 60000
