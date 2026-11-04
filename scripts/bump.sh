#!/usr/bin/env bash
set -euo pipefail

dry_run=false
pretend_current=
output=
while (($#)); do
  case $1 in
    --dry-run) dry_run=true; shift ;;
    --pretend-current) pretend_current=${2:?missing version}; shift 2 ;;
    --output) output=${2:?missing output file}; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

package=nix/package.nix
package_fields() {
  awk '
    /^[[:space:]]*flea-bin[[:space:]]*=/ && !started { started = 1; inside = 1; next }
    inside && /^  };$/ { closed = 1; inside = 0; next }
    inside && /^[[:space:]]*version[[:space:]]*=/ {
      versions++
      if ($0 !~ /^[[:space:]]*version[[:space:]]*=[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+";[[:space:]]*$/) bad = 1
      version = $0; sub(/^[^"]*"/, "", version); sub(/";.*/, "", version)
    }
    inside && /^[[:space:]]*hash[[:space:]]*=/ {
      hashes++
      if ($0 !~ /^[[:space:]]*hash[[:space:]]*=[[:space:]]*"sha256-[^"]+";[[:space:]]*$/) bad = 1
      hash = $0; sub(/^[^"]*"/, "", hash); sub(/";.*/, "", hash)
    }
    END {
      if (!started || !closed || versions != 1 || hashes != 1 || bad) {
        print "flea-bin version/hash not found exactly once in a closed region" > "/dev/stderr"
        exit 2
      }
      print version "\n" hash
    }
  ' "$1"
}

fields=$(package_fields "$package") || exit 2
current=${fields%%$'\n'*}
if [[ -n $pretend_current ]]; then
  [[ $pretend_current =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "invalid current version: $pretend_current" >&2; exit 2; }
  current=$pretend_current
fi

release=$(gh release view -R thisisgm/flea --json tagName,isDraft,isPrerelease)
if [[ $(jq -r '.isDraft or .isPrerelease' <<< "$release") == true ]]; then
  echo 'latest is draft/prerelease' >&2
  [[ -z $output ]] || printf 'updated=false\n' >> "$output"
  exit 0
fi
tag=$(jq -r '.tagName' <<< "$release")
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "invalid release tag: $tag" >&2; exit 3; }
new=${tag#v}
if [[ $new == "$current" || $(printf '%s\n%s\n' "$current" "$new" | sort -V | tail -1) != "$new" ]]; then
  echo "up to date ($current)" >&2
  [[ -z $output ]] || printf 'updated=false\n' >> "$output"
  exit 0
fi

asset="flea-$tag-linux-x86_64.tar.gz"
checksum=$(gh release download "$tag" -R thisisgm/flea -p "$asset.sha256" -O -)
hex=${checksum%%[[:space:]]*}
[[ $hex =~ ^[0-9a-f]{64}$ ]] || { echo 'invalid published sha256' >&2; exit 4; }
published=$(nix hash convert --hash-algo sha256 --to sri "$hex")
url="https://github.com/thisisgm/flea/releases/download/$tag/$asset"
actual=$(nix hash convert --hash-algo sha256 --to sri "$(nix-prefetch-url --type sha256 "$url")")
[[ $published == "$actual" ]] || { printf 'checksum mismatch: published=%s actual=%s\n' "$published" "$actual" >&2; exit 5; }

if $dry_run; then
  printf 'version = "%s";\nhash = "%s";\n' "$new" "$published" >&2
else
  tmp=$(mktemp "$package.XXXXXX")
  trap 'rm -f "$tmp"' EXIT
  awk -v version="$new" -v hash="$published" '
    /^[[:space:]]*flea-bin[[:space:]]*=/ && !started { started = 1; inside = 1 }
    inside && /^  };$/ { inside = 0 }
    inside && /^[[:space:]]*version[[:space:]]*=/ { sub(/"[^"]*"/, "\"" version "\"") }
    inside && /^[[:space:]]*hash[[:space:]]*=/ { sub(/"[^"]*"/, "\"" hash "\"") }
    { print }
  ' "$package" > "$tmp"
  [[ $(package_fields "$tmp") == "$new"$'\n'"$published" ]] || { echo 'rewritten flea-bin fields failed validation' >&2; exit 2; }
  chmod --reference="$package" "$tmp"
  mv "$tmp" "$package"
fi

[[ -z $output ]] || printf 'updated=true\nold=%s\nnew=%s\nhash=%s\n' "$current" "$new" "$published" >> "$output"
printf 'old=%s new=%s hash=%s\n' "$current" "$new" "$published" >&2
