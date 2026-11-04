---
status: approved
issue: 0
spec: spec/2026-11-04-0-flea-nix-package.md
coders:
  1: codex   # two small Rust patches where one wrong line breaks the jail silently: small tricky logic
  2: coder   # derivation boilerplate; iterates with my build output
  3: coder   # FHS env + wrapper, same file as step 2, keeps the coder's cache warm
  4: coder   # NixOS module, short
  5: codex   # HM module: osConfig defaulting, assertions, conditional file generation
  6: coder   # flake.nix outputs and checks wire the files above together
  8: agy     # README: mechanical prose from the module options
reviewers:
  - codex    # reviews steps 2-4 and 6 (Nix plumbing), which it did not write
  - agy      # reviews steps 1 and 5 (patches, HM logic), which codex wrote
---

# Plan: Nix package, flake and Home Manager module for Flea

## Approved decisions (from spec, self-contained)

- Upstream: `thisisgm/flea` tag `v0.4.0` (rev `3745419ecb4f2fee4db0ce18da483be9c7204978`),
  fetched with `fetchFromGitHub` in `nix/package.nix`. Not a flake input.
- The only flake input is `nixpkgs` (`github:NixOS/nixpkgs/nixos-unstable`), plus
  `home-manager` used by `checks` only (`inputs.nixpkgs.follows`). System: `x86_64-linux` only.
- Two derivations:
  - `flea-unwrapped`: `buildRustPackage`, `--workspace --bins`, `doCheck = false`, installed
    with upstream's `make install`, then `usr/*` is moved up.
  - `flea`: a `buildFHSEnv` runtime (`flea-fhs`) plus a thin output with `bin/`,
    `share/applications`, icons, `flea.portal`, and D-Bus `.service` files whose
    `Exec=` goes through `flea-fhs`.
- Two source patches: `nix/shelf-mode.patch` and `nix/nix-store-jail.patch`.
- NixOS module: registration and system services. HM module: per-user preferences.
  Dependency options live in both, and HM defers to `osConfig` when the NixOS module is on.
- Build-time tests are off. Replacement checks are `nix flake check` layout/eval checks
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
`python3Packages.pygobject3`, `xdg-utils`, `diffutils`, `git`, `nixfmt`. rustc 1.99 (≥ 1.77).

Repo traps that apply throughout:
- Untracked files are invisible to flakes: `git add` every new file before `nix build`.
- Every commit ends with the session's attribution lines.
- Name the step being executed in each commit (`feat(nix): step N …`).

## Steps

1. **`nix/shelf-mode.patch`, `nix/nix-store-jail.patch`** (new files, unified diffs against
   v0.4.0 with `a/` `b/` prefixes)
   - shelf-mode: in `src/shelfplugin.rs` `install()`, after each `std::fs::copy(&from, &to)`
     succeeds, call `std::fs::set_permissions(&to, std::fs::Permissions::from_mode(0o644))`
     with the same `map_err` style. Import `std::os::unix::fs::PermissionsExt` if it is
     not already in scope.
   - nix-store-jail:
     - `src/backend/sandbox.rs` `BWRAP_FLAGS`: insert `"--ro-bind", "/nix/store", "/nix/store",`
       right after the `/etc` bind, with a one-line comment (`// Nix: /usr links into the store.`).
     - `crates/flea-gui/src/g2/pv3/sandbox.rs` (~line 64): same three words after the `/etc` bind.
     - `src/backend/thumbbind.rs:7,9`: `JAIL_ROOTS: [&str; 7]` gets `"/nix/store"`,
       `MOUNTED: [&str; 3]` gets `"/nix/store"`.
     - `src/backend/officepdf.rs:58`: `(real.starts_with("/usr") || real.starts_with("/nix/store"))`.
     - `src/backend/codereq.rs:204` `bat_in`:
       `bat_under(path, Path::new("/usr")).or_else(|| bat_under(path, Path::new("/nix/store")))`.
       `bat_under` takes `&Path`. It looks only at the first `bat` on PATH, which is fine:
       inside the FHS env `/usr/bin` comes first.
   → verify: in a scratch clone of v0.4.0,
     `git apply --check /mnt/code/Source-home/GitHub/nixarchy-flea/nix/*.patch`, then apply and
     run `nix shell nixpkgs#cargo nixpkgs#rustc -c cargo check -p flea` (the `flea` crate has
     only pure-Rust deps). The patched `flea-gui` file compiles in step 2's build.
   Traps: no other line may change. Run `rg 'BWRAP_FLAGS.len\(\)|READONLY_'` to confirm
   that no production code depends on the list length (tests may, but tests are off).

2. **`nix/package.nix`, part 1: `flea-unwrapped`**. Also add a minimal `flake.nix` exposing
   `packages.x86_64-linux.flea-unwrapped` so it can be built.
   - `pname = "flea"; version = "0.4.0";` with `src = fetchFromGitHub { owner = "thisisgm"; repo = "flea"; tag = "v${version}"; hash = lib.fakeHash; }`.
     Replace the hash with the one from the first build.
   - `cargoLock = { lockFile = "${src}/Cargo.lock"; outputHashes."gpui-pre-0.3.9" = lib.fakeHash; };`
   - `cargoBuildFlags = [ "--workspace" "--bins" ]; doCheck = false;`
   - `nativeBuildInputs = [ pkg-config ];`
     `buildInputs = [ fontconfig freetype glib gdk-pixbuf libheif libxcb libxkbcommon wayland vulkan-loader libGL poppler mpv-unwrapped ];`
     Add whatever the build demands, and note each addition in this file (deviation rule).
   - `patches = [ ./shelf-mode.patch ./nix-store-jail.patch ];`
   - `installPhase`: `runHook preInstall`; `mkdir -p target/release`;
     `cp $releaseDir/flea $releaseDir/flea-gui target/release/`;
     `make DESTDIR=$out VERSION=${version}-1 install`;
     `mv $out/usr/* $out/ && rmdir $out/usr`; `rm -r $out/share/libalpm`; `runHook postInstall`.
   - `postFixup`: `for b in $out/bin/flea $out/bin/flea-gui; do patchelf --add-rpath ${lib.makeLibraryPath [ vulkan-loader wayland libGL poppler mpv-unwrapped ]} $b; done`.
   - `dontPatchShebangs = true;` The helpers' `#!/usr/bin/python3` and `#!/usr/bin/expect`
     must stay: they resolve to the FHS env's python (with pygobject) and expect.
   - `dontCheckForBrokenSymlinks = true;` The four `ui/{,boot/}{Commons,Ui}` links are meant to dangle.
   - `meta = { description; homepage; license = lib.licenses.mit; mainProgram = "flea"; platforms = [ "x86_64-linux" ]; };`
   → verify: `nix build .#flea-unwrapped -L` succeeds (I run it); `patchelf --print-rpath`
     on both binaries lists the vulkan-loader and mpv-unwrapped paths; `head -1 result/lib/flea/flea-portal`
     is still `#!/usr/bin/python3`; then
     `ls result/share/flea/ui/boot/shell.qml result/lib/flea/` shows the 5 helpers, and
     `grep '"version": "0.4.0-1"' result/share/flea/shelf/manifest.json` matches.
   Traps: `$releaseDir` is set by `cargoBuildHook`. The `build.rs` linker probe may print
   a warning, which is fine. The Makefile `sed -i` writes into `$out`, so it is writable.

3. **`nix/package.nix`, part 2: `flea-fhs` and `flea`**. The file becomes a function
   returning `flea` with `passthru = { unwrapped; fhs; }`. `flea-unwrapped` is exposed via
   `passthru.unwrapped`.
   - Arguments (besides the callPackage'd nixpkgs ones): `withHtmlPreview ? true`, `extraPackages ? [ ]`,
     `omarchyPath ? "/run/current-system/sw/share/omarchy"`.
   - `omarchyLink = runCommand "flea-omarchy-link" { } "mkdir -p $out/share; ln -s ${omarchyPath} $out/share/omarchy";`
   - `flea-fhs = buildFHSEnv { name = "flea-fhs"; runScript = writeShellScript "flea-fhs-exec" ''exec "$@"''; dieWithParent = false; profile = "export GI_TYPELIB_PATH=/usr/lib/girepository-1.0 GIO_EXTRA_MODULES=/usr/lib/gio/modules"; targetPkgs = p: [ flea-unwrapped omarchyLink (python3.withPackages (ps: [ ps.pygobject3 ])) gobject-introspection glib expect bat bubblewrap util-linux gvfs jq quickjs-ng ripgrep shared-mime-info udisks usbmuxd wl-clipboard xdg-terminal-exec xdg-utils poppler poppler-utils mpv-unwrapped vulkan-loader libGL wayland diffutils git quickshell fontconfig freetype gdk-pixbuf libheif libxcb libxkbcommon ] ++ lib.optionals withHtmlPreview [ qt6.qtdeclarative qt6.qtwebengine ] ++ extraPackages; };`
   - `flea = runCommand "flea-${version}" { passthru…; meta = flea-unwrapped.meta; }` with:
     - `bin/flea` and `bin/flea-gui`: `#!${runtimeShell}` + `exec ${flea-fhs}/bin/flea-fhs /usr/bin/flea "$@"` (and the same for `flea-gui`), then `chmod +x`
     - The desktop file is `Exec=flea --gui %f` (checked), so it works through PATH unchanged
     - `ln -s` `share/applications`, `share/icons`, `share/licenses` from unwrapped
     - `share/xdg-desktop-portal/portals/flea.portal` copied
     - `share/dbus-1/services/*.service` copied with `sed 's|^Exec=/usr/lib/flea/|Exec=${flea-fhs}/bin/flea-fhs /usr/lib/flea/|'`
   - In the same file, `sevenzip7z = runCommand "7z-link" { } "mkdir -p $out/bin; ln -s ${_7zz}/bin/7zz $out/bin/7z";`, exposed as `passthru.optionalPackages` (an attrset used by the modules): `{ sevenzip = sevenzip7z; libarchive; ffmpeg; ffmpegthumbnailer; imagemagick; libreoffice; tailscale; zoxide; dropbox = dropbox-cli; }`.
   → verify: `nix build .#flea`; `grep -h ^Exec= result/share/dbus-1/services/*` all start with
     the flea-fhs store path; `nix run .#flea -- --version` prints `0.4.0`.
   Traps: `buildFHSEnv` takes `targetPkgs` as a function. Flea calls `/usr/bin/7z`, not
   `7zz`, hence the link.

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
   - Assertion: when `osEnabled`, none of the HM dependency options is set (test with
     `options.programs.flea.<x>.isDefined`, so an explicit default is caught too).
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
   - `packages.x86_64-linux = { flea; flea-unwrapped = flea.unwrapped; default = flea; }`
   - `overlays.default = final: prev: { flea = final.callPackage ./nix/package.nix { }; flea-unwrapped = final.flea.unwrapped; }`
   - `nixosModules.{flea,default} = ./nix/nixos-module.nix` and
     `homeManagerModules.{flea,default} = ./nix/hm-module.nix` (plain paths, no flake-pinned package)
   - `formatter.x86_64-linux = nixpkgs.legacyPackages.x86_64-linux.nixfmt`
   - `checks.x86_64-linux`:
     - `flea-unwrapped-layout` (spec check 2): a runCommand asserting the step 2 paths
     - `flea-services` (spec check 3): every `Exec=` starts with the flea-fhs path
     - `nixos-module` (eval only; it does not build the toplevel closure):
       `nixpkgs.lib.nixosSystem { system = "x86_64-linux"; modules = [ self.nixosModules.flea { programs.flea.enable = true; programs.flea.optionalDependencies.ffmpeg = true; boot.isContainer = true; system.stateVersion = "26.05"; } ]; }`.
       A runCommand whose text is produced by `lib.assertMsg` checks that
       `config.xdg.portal.extraPortals` contains `config.programs.flea.package` and that
       `services.gvfs.enable` is true.
     - `hm-module`: `home-manager.lib.homeManagerConfiguration { pkgs = nixpkgs.legacyPackages.x86_64-linux; modules = [ self.homeManagerModules.flea { home = { username = "t"; homeDirectory = "/home/t"; stateVersion = "26.05"; }; programs.flea = { enable = true; defaultFileManager.enable = true; filePicker.enable = true; hyprland.bindings.enable = true; }; } ]; }`.
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
| `git apply --check /mnt/code/Source-home/GitHub/nixarchy-flea/nix/*.patch` (in a v0.4.0 scratch clone) | no output, exit 0 |
| `nix build .#flea-unwrapped .#flea -L` | both build, no network in build |
| `nix flake check -L` | `flea-unwrapped-layout`, `flea-services`, `nixos-module`, `hm-module`, `hm-under-nixos` pass |
| `nix run .#flea -- --version` | `0.4.0` |
| runtime checks 1–6 (spec) | each recorded pass/fail in the PR |

## Rollback

Nothing outside this repo changes. Delete the branch, or `git revert` the implementation
commits. Consumers roll back by dropping the flake input. If the FHS/nested-bwrap approach
fails runtime check 4, stop and update the spec (fallback: native path rewriting). That
needs re-approval.
