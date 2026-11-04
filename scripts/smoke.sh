#!/usr/bin/env bash
# Headless proof that the packaged prebuilt binary loads and runs inside the FHS env and an inner jail.
# On ubuntu-latest, first: sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
set -euo pipefail

fhs=$(nix build --no-link --print-out-paths .#packages.x86_64-linux.flea.fhs)
run() { "$fhs/bin/flea-fhs" sh -c "$1"; }

run "! ldd /usr/bin/flea /usr/bin/flea-gui | grep 'not found'"
want=$(nix eval --raw .#flea-bin.version)
got=$(run '/usr/bin/flea --version')
[[ $got == "$want" ]] || { echo "version: got '$got', want '$want'" >&2; exit 1; }
run 'test -f /usr/bin/bat -a ! -L /usr/bin/bat'
[[ $(run 'command -v bwrap') == /usr/bin/bwrap ]] || { echo "bwrap is not the shim" >&2; exit 1; }
run 'grep -q -- "--ro-bind /nix/store /nix/store" /usr/bin/bwrap'
jailed=$(run 'bwrap --ro-bind /usr /usr --ro-bind /etc /etc --symlink usr/lib /lib --ro-bind-try /lib64 /lib64 --proc /proc --dev /dev --unshare-all -- /usr/bin/flea --version')
[[ $jailed == "$want" ]] || { echo "jailed version: got '$jailed', want '$want'" >&2; exit 1; }
echo "smoke ok ($want)"
