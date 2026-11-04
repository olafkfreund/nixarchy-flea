---
status: approved
issue: 1
spec: spec/2026-11-04-0-flea-nix-package.md
coders:
  1: coder   # unpack derivation: mechanical, mirrors upstream's flea-bin package()
  3: codex   # bwrap shim, thumbnailer-derived copy list, profile chmod: small tricky logic
  4: coder   # NixOS module, short
  5: codex   # HM module: osConfig defaulting, assertions, conditional file generation
  6: coder   # flake.nix outputs and checks wire the files above together
  8: agy     # README: mechanical prose from the module options
reviewers:
  - codex    # reviews steps 1, 4 and 6, which it did not write
  - agy      # reviews steps 3 and 5, which codex wrote
---

# Plan: Nix package, flake and Home Manager module for Flea

> **Revision 2** follows spec revision 2 (prebuilt release binaries). Steps 1–3 are
> rewritten and step 2 is dropped. Steps 4–10 are unchanged except where marked. The rev. 1
> work (two patches, source build) is in git history up to `33d96d9`, and step 1 below
> deletes it from the tree.

## Approved decisions (from spec rev. 2, self-contained)

- Upstream: `thisisgm/flea` release `v0.4.0`, asset `flea-v0.4.0-linux-x86_64.tar.gz`, fetched
  with `fetchurl`. Hash `sha256-76RmxJFiKMrW43T58zshbvI29TUVdY/dxQLGly9cUNc=` (from upstream's
  `.sha256`: `efa466c4…50d7`, verified locally). Not a flake input.
- The only flake input is `nixpkgs` (`github:NixOS/nixpkgs/nixos-unstable`), plus
  `home-manager` used by `checks` only (`inputs.nixpkgs.follows`). System: `x86_64-linux` only.
- Two derivations. Flea itself is not compiled (buildFHSEnv's own small init and rootfs
  builder do build once, cold):
  - `flea-bin`: an unpacked release laid out like upstream's `packaging/flea-bin/PKGBUILD`
    `package()`, with `$out` as `/usr`. Binaries untouched.
  - `flea`: a `buildFHSEnv` runtime (`flea-fhs`) plus a thin output with `bin/`,
    `share/applications`, icons, `flea.portal`, and D-Bus `.service` files whose
    `Exec=` goes through `flea-fhs`.
- No source patches. Their four fixes move into packaging: a `bwrap` shim, real-file
  copies of trust-checked tools in the FHS `usr/bin`, and a shelf `chmod` in the FHS profile.
- NixOS module: registration and system services. HM module: per-user preferences.
  Dependency options live in both, and HM defers to `osConfig` when the NixOS module is on.
- No build-time tests (Flea is not compiled). Checks are `nix flake check` layout/eval checks
  plus host runtime checks.
- Defaults: optional deps off, HTML preview on. The shelf is owned by Flea. Hyprland binds
  go in `~/.config/hypr/flea-binds.lua`, loaded by a hand-added `pcall(require, "hypr.flea-binds")`.

Verified nixpkgs attributes (nixos-unstable, 2026-11-04): `quickjs-ng`, `_7zz` (ships `7zz`
only), `dropbox-cli`, `xdg-terminal-exec`, `quickshell`, `libheif`, `poppler` (= poppler-glib),
`poppler-utils`, `ffmpegthumbnailer`, `libarchive`, `libreoffice`, `zoxide`, `tailscale`,
`imagemagick`, `ffmpeg`, `mpv-unwrapped` (has `lib/libmpv.so.2`), `vulkan-loader`, `libGL`,
`wayland`, `libxkbcommon`, `libxcb`, `gdk-pixbuf`, `udisks`, `usbmuxd`, `gvfs`,
`wl-clipboard`, `bat`, `jq`, `ripgrep`, `shared-mime-info`, `expect`, `bubblewrap`,
`util-linux`, `qt6.qtwebengine`, `qt6.qtdeclarative`, `gobject-introspection`,
`python3Packages.pygobject3`, `xdg-utils`, `diffutils`, `git`, `nixfmt`, `hicolor-icon-theme`,
`glibc` (2.44; the binaries need ≥ 2.39). Release binaries: interpreter
`/lib64/ld-linux-x86-64.so.2`, NEEDED gdk-pixbuf, gobject/glib, libxcb, fontconfig,
libxkbcommon(-x11), libgcc_s, libm, libc, no RUNPATH.

Repo traps that apply throughout:
- Untracked files are invisible to flakes: `git add` every new file before `nix build`.
- Every commit ends with the session's attribution lines.
- Name the step being executed in each commit (`feat(nix): step N …`).

## Steps

1. **`nix/package.nix`: replace `flea-unwrapped` with `flea-bin`**, and delete
   `nix/shelf-mode.patch` and `nix/nix-store-jail.patch` (`git rm`).
   - `flea-bin = stdenvNoCC.mkDerivation rec { pname = "flea-bin"; version = "0.4.0"; src = fetchurl { url = "https://github.com/thisisgm/flea/releases/download/v${version}/flea-v${version}-linux-x86_64.tar.gz"; hash = "sha256-76RmxJFiKMrW43T58zshbvI29TUVdY/dxQLGly9cUNc="; }; … }`.
     The tarball unpacks to `flea-${version}-linux-x86_64/`, which stdenv's `sourceRoot`
     detection handles.
   - `dontConfigure = true; dontBuild = true; dontPatchELF = true; dontStrip = true; dontPatchShebangs = true; dontCheckForBrokenSymlinks = true;`
   - `installPhase` = upstream `packaging/flea-bin/PKGBUILD` `package()` line for line,
     with `$pkgdir/usr` → `$out` and `$pkgname` → `flea`. That gives bin, 5 helpers in
     `lib/flea`, portal, 2 D-Bus services, desktop, icon, licenses, ui (+js, vendor,
     LICENSES, boot), shelf, and i18n catalogs (`i18n/*/flea.json` only). Then the `sed`
     version stamp to `${version}-1` with its `grep -qF` guard, and the four `ln -s`
     Commons/Ui links. **Skip** the `flea.hook` install.
   - `meta = { description = "File manager for Omarchy (upstream release binaries)"; homepage = "https://github.com/thisisgm/flea"; license = with lib.licenses; [ asl20 bsd2 bsd3 cc0 isc mit mpl20 unicode-30 zlib ]; sourceProvenance = [ lib.sourceTypes.binaryNativeCode ]; mainProgram = "flea"; platforms = [ "x86_64-linux" ]; };`
     If `unicode-30` is not the attribute name in the pinned nixpkgs, use the closest
     Unicode license attr and note it.
   - Until step 3, the file returns `flea-bin`. `flake.nix` exposes
     `packages.x86_64-linux.flea-bin` in place of `flea-unwrapped`.
   → verify (I run it): `nix build .#flea-bin -L` (no compile, seconds);
     `ls result/bin result/lib/flea` shows 2 + 5 files; `result/share/flea/ui/boot/shell.qml`
     exists; `grep '"version": "0.4.0-1"' result/share/flea/shelf/manifest.json`;
     `cmp result/bin/flea-gui <tarball>/flea-gui` (byte-identical); `head -1 result/lib/flea/flea-portal`
     is `#!/usr/bin/python3`; no `share/libalpm`.
   Traps: `install -Dm644 … -t dir` needs the target dirs, which `-D` creates. Globs such
   as `ui/*.qml` must match, or `install` fails loudly, which is what we want.

2. **Dropped in rev. 2** (the source build). Numbering is kept so steps 4–10 stay as approved.

3. **`nix/package.nix`, part 2: `flea-fhs` and `flea`**. The file becomes a function
   returning `flea` with `passthru = { unwrapped = flea-bin; fhs = flea-fhs; optionalPackages; }`.
   - Arguments (besides the callPackage'd nixpkgs ones): `withHtmlPreview ? true`, `extraPackages ? [ ]`,
     `omarchyPath ? "/run/current-system/sw/share/omarchy"`.
   - `omarchyLink = runCommand "flea-omarchy-link" { } "mkdir -p $out/share; ln -s ${omarchyPath} $out/share/omarchy";`
   - `bwrapShim = writeShellScriptBin "bwrap" ''exec ${bubblewrap}/bin/bwrap --ro-bind /nix/store /nix/store --ro-bind ${glibc}/etc ${glibc}/etc "$@"'';`
     The real `bubblewrap` package is **not** in targetPkgs, so `/usr/bin/bwrap` is the shim.
   - `flea-fhs = buildFHSEnv { name = "flea-fhs"; runScript = writeShellScript "flea-fhs-exec" ''exec "$@"''; dieWithParent = false; profile = …; extraBuildCommands = …; targetPkgs = p: [ flea-bin bwrapShim omarchyLink (python3.withPackages (ps: [ ps.pygobject3 ])) gobject-introspection glib expect bat util-linux gvfs jq quickjs-ng ripgrep shared-mime-info udisks usbmuxd wl-clipboard xdg-terminal-exec xdg-utils poppler poppler-utils mpv-unwrapped vulkan-loader libGL wayland diffutils git quickshell fontconfig freetype gdk-pixbuf libheif libxcb libxkbcommon hicolor-icon-theme ] ++ lib.optionals withHtmlPreview [ qt6.qtdeclarative qt6.qtwebengine ] ++ extraPackages; };`
   - `profile`:
     ```sh
     export GI_TYPELIB_PATH=/usr/lib/girepository-1.0 GIO_EXTRA_MODULES=/usr/lib/gio/modules
     chmod -R u+w "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/io.github.thisisgm.flea-shelf" 2>/dev/null || true
     ```
     In the Nix string, write `''${XDG_CONFIG_HOME:-$HOME/.config}` so Nix doesn't interpolate it.
   - `extraBuildCommands` ($out is the FHS root):
     ```sh
     test -d "$out/usr/bin" -a ! -L "$out/usr/bin" || { echo "flea-fhs: usr/bin is not a real directory" >&2; exit 1; }
     tools="bat soffice libreoffice"
     for f in "$out"/usr/share/thumbnailers/*.thumbnailer; do
       [ -e "$f" ] || continue
       tools="$tools $(sed -n 's/^\(Try\)\?Exec=\([^ ]*\).*/\2/p' "$f" | xargs -r -n1 basename)"
     done
     for t in $(printf '%s
' $tools | sort -u); do
       p="$out/usr/bin/$t"
       [ -L "$p" ] || continue
       real=$(readlink -f "$p"); rm "$p"; cp "$real" "$p"
       echo "flea-fhs: real file $t"
     done
     ```
     Resolve before removing: the entry is a symlink into the read-only store, so `cp`
     through it fails, and `cp --remove-destination` onto itself would delete its source.
   - `flea = runCommand "flea-${flea-bin.version}" { passthru…; meta = flea-bin.meta // { description = …; }; }` with:
     - `bin/flea` and `bin/flea-gui`: `#!${runtimeShell}` + `exec ${flea-fhs}/bin/flea-fhs /usr/bin/flea "$@"` (and the same for `flea-gui`), then `chmod +x`
     - The desktop file is `Exec=flea --gui %f` (checked), so it works through PATH unchanged
     - `ln -s` `share/applications`, `share/icons`, `share/licenses` from flea-bin
     - `share/xdg-desktop-portal/portals/flea.portal` copied
     - `share/dbus-1/services/*.service` copied with `sed 's|^Exec=/usr/lib/flea/|Exec=${flea-fhs}/bin/flea-fhs /usr/lib/flea/|'`
   - In the same file, `sevenzip7z = runCommand "7z-link" { } "mkdir -p $out/bin; ln -s ${_7zz}/bin/7zz $out/bin/7z";`, exposed as `passthru.optionalPackages` (an attrset used by the modules): `{ sevenzip = sevenzip7z; libarchive; ffmpeg; ffmpegthumbnailer; imagemagick; libreoffice; tailscale; zoxide; dropbox = dropbox-cli; }`. `libreoffice` is the wrapped `pkgs.libreoffice`.
   → verify (I run it): `nix build .#flea`; the build log shows `flea-fhs: real file bat`
     and the thumbnailer copies (gdk-pixbuf, heif); `grep -h ^Exec= result/share/dbus-1/services/*`
     all start with the flea-fhs store path; `nix run .#flea -- --version` prints `0.4.0`;
     and inside the env, with `fhs=$(nix build --no-link --print-out-paths .#packages.x86_64-linux.flea.fhs)`
     and each check run as `$fhs/bin/flea-fhs sh -c '…'`: `test -f /usr/bin/bat -a ! -L /usr/bin/bat`,
     `command -v bwrap` → `/usr/bin/bwrap`, `head -2 /usr/bin/bwrap` is the shim,
     `! ldd /usr/bin/flea-gui | grep -q 'not found'` (exit 0 = nothing missing), and
     `bwrap --ro-bind /usr /usr --ro-bind /etc /etc --symlink usr/lib /lib --ro-bind-try /lib64 /lib64 --proc /proc --dev /dev --unshare-all -- /usr/bin/flea --version` → `0.4.0`.
     The last one proves a jailed prebuilt binary loads its libraries.
   Traps: `buildFHSEnv` takes `targetPkgs` as a function. Flea calls `/usr/bin/7z`, not
   `7zz`, hence the link. `profile` runs for every entry, including D-Bus helpers, so it
   must never fail: hence `|| true`.

   **Deviations (step 3, from the step 10 reviews; each checked at runtime):**
   - `.thumbnailer` files named absolute store paths, so the `/usr/bin` copies went
     unused. `extraBuildCommands` now replaces them with copies whose `Exec=`/`TryExec=`
     use `/usr/bin/<tool>`. Checked: `gdk-pixbuf-thumbnailer` made a 32×32 PNG in a
     `--clearenv` jail.
   - Flea's HTML jail runs `/usr/bin/qml6` (Arch's name), and nixpkgs ships `qml`. A
     `qml6` wrapper (only with `withHtmlPreview`) sets `QML_IMPORT_PATH` and execs `qml`.
     Checked: it imports QtWebEngine under the HTML jail's exact `--setenv` set.
   - Inside buildFHSEnv, `/etc/*` link to `/.host-etc/*`, which Flea's jails did not bind,
     so fonts and every host `/etc` file dangled. The shim adds
     `--ro-bind-try /.host-etc /.host-etc` (parity with Arch, where jails see all of
     `/etc`). Checked: `fc-match sans` works in a jail.
   - `omarchyPath` is passed through `lib.escapeShellArg`.
   **Deviations (step 5, reviews):** the assertion counts priority < 1000 as user-set
   (`mkDefault` in a shared profile is not), also covers `package`, and names every
   option. A `package` without `passthru.fhs` fails with a clear `throw`.
   **Deviation (step 6, review):** the overlay's `flea-bin` is computed on its own, not
   from `final.flea`, so a later overlay's `flea` cannot break it. A new check,
   `fhs-rootfs`, asserts that the thumbnailer rewrite, the real files, `qml6` and the
   QtWebEngine QML dir exist.

   **Deviation (steps 4–5):** `base` is `pkgs.flea` only if it carries `optionalPackages`
   (i.e. it is ours). Otherwise it is `pkgs.callPackage ./package.nix { }`, so that a future,
   different nixpkgs `flea` cannot silently replace it.

4. **`nix/nixos-module.nix`**: `{ config, lib, pkgs, ... }:` with
   `let base = pkgs.flea or (pkgs.callPackage ./package.nix { });`. This honours the consumer's
   nixpkgs and overlay, as the spec's `pkgs.flea` does, and works without the overlay too.
   - Options under `programs.flea`: `enable`; `htmlPreview` (bool, default true);
     `optionalDependencies.<name>` for each key of `base.optionalPackages` (bool, default
     false); `extraPackages` (listOf package); `omarchyPath` (str, default
     `"/run/current-system/sw/share/omarchy"`); `package` (default
     `base.override { withHtmlPreview = cfg.htmlPreview; extraPackages = enabledOptionals ++ cfg.extraPackages; inherit (cfg) omarchyPath; }`,
     `defaultText` given).
   - `services.dbus.packages` ships `com.thisisgm.flea.FileManager1.service`, which claims
     `org.freedesktop.FileManager1` system-wide, as Arch's package does. Which claimant wins
     among system files is up to the bus. The HM `defaultFileManager` file in
     `~/.local/share` is what decides it. The option description says so.
   - Config under `mkIf cfg.enable`: `environment.systemPackages`, `xdg.portal.enable = mkDefault true`,
     `xdg.portal.extraPortals`, `services.dbus.packages`, and `mkDefault true` for
     `services.gvfs.enable`, `services.udisks2.enable`, `services.usbmuxd.enable` and
     `programs.dconf.enable`.
   → verify: step 6 `checks.nixos-module`.
   Traps: `package.nix` must be called with `callPackage`, so that `.override` exists.

5. **`nix/hm-module.nix`**: `{ config, lib, options, pkgs, osConfig ? null, ... }:`, with `base` as in step 4.
   - `enable` plus the same dependency options as step 4 (including `omarchyPath`), plus
     `package`. The default is `if osEnabled then osConfig.programs.flea.package else base.override {…}`,
     where `osEnabled = osConfig != null && (osConfig.programs.flea.enable or false)`.
   - Everything under `config = mkIf cfg.enable { … }`.
   - Assertion: when `osEnabled`, none of the HM dependency options is set.
     **Deviation:** `isDefined` is also true for an option left at its default, so the
     test is `isDefined && highestPrio < 1500` (a user definition, including an explicit
     default value).
     Message: "programs.flea: set htmlPreview/optionalDependencies/extraPackages in the NixOS module; Home Manager uses its package".
   - `defaultFileManager.enable`: `xdg.mimeApps.enable = true`;
     `xdg.mimeApps.defaultApplications."inode/directory" = "com.thisisgm.flea.desktop"`;
     `xdg.dataFile."dbus-1/services/org.freedesktop.FileManager1.service".text` containing the
     comment line `# Written by Home Manager programs.flea.defaultFileManager.`, then
     `[D-BUS Service]`, `Name=org.freedesktop.FileManager1`, and
     `Exec=${cfg.package.fhs}/bin/flea-fhs /usr/lib/flea/flea-filemanager1`.
   - `filePicker.enable` + `filePicker.extraConfig` (attrsOf str, default `{ }`):
     `xdg.configFile."xdg-desktop-portal/hyprland-portals.conf".text` = `[preferred]`, then
     `org.freedesktop.impl.portal.FileChooser=flea;gtk`, then the `extraConfig` lines as
     `k=v`. Never write a `default=` key unless the user puts it in `extraConfig`. Document
     that this host needs `extraConfig = { default = "hyprland;gtk"; "org.freedesktop.impl.portal.Secret" = "gnome-keyring"; };`.
     Also document the first switch: the file exists today as a mutable file, so move it
     aside (`mv … hyprland-portals.conf.pre-flea`) or set `force = true`. Otherwise HM
     refuses to clobber it.
   - `hyprland.bindings.enable`: when it or `filePicker.enable` is on, write
     `xdg.configFile."hypr/flea-binds.lua".text`:
     - a header naming `pcall(require, "hypr.flea-binds")`
     - if bindings: the 4 lines from `docs/install.md` step 3, with `flea` → `${lib.getExe cfg.package}`
     - if filePicker: `o.window("com.thisisgm.flea.picker", { tag = "+floating-window" })`
   - `home.packages = [ cfg.package ]` (also when `osEnabled`: the same store path, harmless).
   → verify: step 6 `checks.hm-module`.
   Traps: `osConfig` is absent in standalone HM, hence `? null`. Do not use `xdg.portal.*`.

6. **`flake.nix`, final**
   - `packages.x86_64-linux = { flea; flea-bin = flea.unwrapped; default = flea; }`
   - `overlays.default = final: prev: { flea = final.callPackage ./nix/package.nix { }; flea-bin = final.flea.unwrapped; }`
   - `nixosModules.{flea,default} = ./nix/nixos-module.nix` and
     `homeManagerModules.{flea,default} = ./nix/hm-module.nix` (plain paths, no flake-pinned package)
   - `formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt`
   - `checks.x86_64-linux`:
     - `flea-bin-layout` (spec check 2): a runCommand asserting the step 1 paths
     - `flea-services` (spec check 3): every `Exec=` starts with the flea-fhs path
     - `nixos-module` (eval only; it does not build the toplevel closure):
       `nixpkgs.lib.nixosSystem { system = "x86_64-linux"; modules = [ self.nixosModules.flea { programs.flea.enable = true; programs.flea.optionalDependencies = lib.genAttrs (builtins.attrNames self.packages.x86_64-linux.flea.optionalPackages) (_: true); boot.isContainer = true; system.stateVersion = "26.05"; } ]; }`
       (every option on, as the spec asks; eval only, so the large optional closures are not built).
       A runCommand whose text is produced by `lib.assertMsg` checks that
       `config.xdg.portal.extraPortals` contains `config.programs.flea.package` and that
       `services.gvfs.enable` is true.
     - `hm-module`: `home-manager.lib.homeManagerConfiguration { pkgs = nixpkgs.legacyPackages.x86_64-linux; modules = [ self.homeManagerModules.flea { home = { username = "t"; homeDirectory = "/home/t"; stateVersion = "26.05"; }; programs.flea = { enable = true; defaultFileManager.enable = true; filePicker.enable = true; hyprland.bindings.enable = true; htmlPreview = false; optionalDependencies = <all true, as above>; extraPackages = [ pkgs.hello ]; omarchyPath = "/opt/omarchy"; }; } ]; }`.
       Read `config.xdg.configFile`/`xdg.dataFile` `.text` at eval time and assert:
       `flea-binds.lua` has both blocks, `hyprland-portals.conf` has no `default=`, the
       FileManager1 service `Exec=` uses flea-fhs, and the mimeApps entry is set. Eval only,
       no activation build.
     - `hm-under-nixos` (eval only): a `nixosSystem` with
       `home-manager.nixosModules.home-manager`, the NixOS module on, and the HM module for
       user `t`. Assert that HM's `programs.flea.package` == the NixOS one. A second
       evaluation with `home-manager.users.t.programs.flea.htmlPreview = false` must fail
       its assertion, checked via `builtins.tryEval` on the assertion list.
   → verify: `nix flake check -L` passes (I run it).
   Traps: `home-manager` input only for checks, `follows = "nixpkgs"`.

   **Deviations (step 6):** (1) "every option on" excludes `dropbox`, because
   `dropbox-cli` pulls in the unfree `dropbox`, which nixpkgs refuses to evaluate without
   `allowUnfree`. The README says so. (2) The FileManager1 `Exec=` pattern goes through
   `builtins.unsafeDiscardStringContext`, because `lib.hasInfix` rejects a pattern string
   that refers to a store path. It is only compared as text. (3) `hm-under-nixos` tests the
   bad case through the NixOS `config.assertions` list, where Home Manager's assertions
   land, not through `builtins.tryEval`.

7. **Build and check** (me): `nix fmt`, `nix build .#flea -L`, `nix flake check -L`. Fix by
   sending failures back to the step's coder. Commit.

8. **`README.md`**: what this is, the flake input snippet, NixOS + HM usage with every
   option, the `pcall(require, …)` line, the `hyprland-portals.conf` `extraConfig` example,
   `omarchyPath` (when Omarchy is per-user, e.g. `/etc/profiles/per-user/$USER/share/omarchy`),
   the first-switch move of `hyprland-portals.conf`, and "do not use
   `flea --default`/`--picker` or the Settings > About switch with these options".
   → verify: every option name in the README exists in `nix/*-module.nix` (`rg`).

9. **Runtime checks** (me, then you for GUI eyes). Spec checks 1–6 run on this host via
   `nix run .#flea` / `--gui` with no system change. **Deviation from the spec:** checks
   7–10 (FileManager1, portal picker, Hyprland keys, shelf across a version bump) need the
   modules in your nixarchy config. You said integration comes later, so they move to the
   integration PR and are listed in this PR as pending. Each check is recorded pass/fail in
   the PR description.

10. **Review and PR** (me): a fresh Opus agent gets this plan path and `git diff main`. Codex
    and agy review in parallel (read-only). Fix confirmed findings, then open the PR linking
    intent/spec/plan and saying which steps each coder did. There is no remote yet, so the
    PR waits on issue/repo creation (open question 1).

## Deviations from the spec (need your approval with this plan)

- Runtime checks 7–10 move to the nixarchy integration PR (step 9).
- The `checks` are evaluation-only for the modules. The spec said "evaluate". This plan
  adds a sixth check, `hm-under-nixos`, which the spec did not list.
- `omarchyPath` becomes a module option, as well as a package argument.

## Tests

| Command | Expected |
|---|---|
| `nix build .#flea-bin .#flea -L` | both build; only the tarball is fetched; Flea is not compiled |
| step 3's in-env checks | real-file copies, the shim on PATH, no missing libraries, the jailed binary runs |
| `nix flake check -L` | `flea-bin-layout`, `flea-services`, `nixos-module`, `hm-module`, `hm-under-nixos` pass |
| `nix run .#flea -- --version` | `0.4.0` |
| runtime checks 1–6 (spec) | each recorded pass/fail in the PR |

## Rollback

Nothing outside this repo changes. Delete the branch, or `git revert` the implementation
commits. Consumers roll back by dropping the flake input. If the FHS/nested-bwrap approach
fails runtime check 4, stop and update the spec (fallback: native path rewriting). That
needs re-approval.
