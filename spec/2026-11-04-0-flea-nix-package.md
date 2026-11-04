---
status: approved
issue: 0
intent: intent/2026-11-04-0-flea-nix-package.md
---

# Spec: Nix package, flake and Home Manager module for Flea

## Decisions on the intent's open questions

The intent was approved without answers, so these are defaults. Change any of them at this
gate.

| # | Question | Decision |
|---|---|---|
| 1 | Tracking issue | Keep `0` until a repo/issue exists. |
| 2 | Option scope | Only what `flea --default`, `flea --picker` and the shelf do, plus one switch per optional dependency. No options mirroring in-app settings. |
| 3 | Hyprland binds | HM writes `~/.config/hypr/flea-binds.lua`. You add `pcall(require, "hypr.flea-binds")` to `bindings.lua` once, the same pattern as `hypr.ai-mirror-binds` on this host. |
| 4 | Shelf plugin | Flea owns it (its in-app switch). The package patches the copy so files land `0644`, not the store's `0444`. HM does not manage the plugin directory. |
| 5 | System services | Ship `nixosModules.flea`. Portal discovery is system-level here: `flea.portal` must be in `/run/current-system/sw/share/xdg-desktop-portal/portals`. |
| — | Build-time tests | **Off (`doCheck = false`). This changes the approved intent's test constraint. Your call, see "Alternatives rejected".** |
| 6 | Optional deps default | Off. |
| 7 | `qt6-webengine` HTML previews | On by default (Arch hard dep), `withHtmlPreview` to drop it. |
| 8 | Platforms | `x86_64-linux` only. |

## Design

### Layout

```
flake.nix            inputs: nixpkgs (unstable); outputs below
nix/package.nix      flea-unwrapped (build) + flea (FHS runtime)
nix/shelf-mode.patch one-hunk fix: copied shelf files get 0644
nix/nix-store-jail.patch  /nix/store counts as /usr for Flea's jails (5 files)
nix/hm-module.nix    homeManagerModules.flea
nix/nixos-module.nix nixosModules.flea
```

Flake outputs (`x86_64-linux`): `packages.{flea,flea-unwrapped,default}`,
`overlays.default` (adds `flea`, `flea-unwrapped`), `homeManagerModules.{flea,default}`,
`nixosModules.{flea,default}`, `checks` (see Verification), `formatter` (nixfmt).
Source is fetched with `fetchFromGitHub` at tag `v0.4.0` inside `package.nix`, not as a
flake input, so a bump is version + two hashes.

### Build: `flea-unwrapped`

`rustPlatform.buildRustPackage`:
- `cargoLock.lockFile = "${src}/Cargo.lock"`, `outputHashes` with one entry for the single
  git source (`gpui-omarchy` @ `04965e86…`, 15 crates).
- `cargoBuildFlags = [ "--workspace" "--bins" ]`, matching `PKGBUILD:89`.
- `nativeBuildInputs`: `pkg-config`.
- `buildInputs`: fontconfig, freetype, glib, gdk-pixbuf, libheif, libxcb, libxkbcommon,
  wayland, vulkan-loader, libGL, poppler (glib), mpv. The exact list is whatever the build
  asks for; this is the Arch "linked by" set.
- `doCheck = false`. See "Alternatives rejected".
- `installPhase`: `make DESTDIR=$out VERSION=${version}-1 install`, then move `$out/usr/*`
  up to `$out`. The Makefile already lays out `bin/`, `lib/flea/`, `share/flea/{ui,shelf,i18n}`,
  `share/dbus-1/services`, `share/xdg-desktop-portal/portals`, `share/applications`, icons,
  licenses. Delete `share/libalpm` (pacman hook).
- The four `ui/{,boot/}{Commons,Ui}` symlinks point at `/usr/share/omarchy/shell/…` and
  dangle at build time, which they are meant to. `dontCheckForBrokenSymlinks = true`.
- `patches = [ ./shelf-mode.patch ./nix-store-jail.patch ]`. No path rewriting beyond these.
- `postFixup`: `patchelf --add-rpath ${makeLibraryPath [ vulkan-loader wayland libGL poppler mpv ]}`
  on both binaries. These libraries are `dlopen`ed, so shrink-rpath would drop them. Jailed
  workers start with `--clearenv`, so `LD_LIBRARY_PATH` cannot stand in for the runpath.
- `meta.license = [ mit ]`, plus the shipped `THIRD-PARTY-LICENSES.txt`.

### Runtime: `flea` = `buildFHSEnv`

Flea assumes an Arch `/usr`: about 60 production code sites, bwrap jails that bind `/usr`
(`src/backend/sandbox.rs:35`, `crates/flea-gui/src/g2/pv3/sandbox.rs:62`), `/usr/share/mime`,
and helpers with `#!/usr/bin/python3` and `#!/usr/bin/expect`. Rather than patching all
of that, Flea runs in an FHS namespace where `/usr` is a profile holding Flea and every
dependency. That `/usr` is a tree of symlinks into `/nix/store`. Every Nix binary also has a
store interpreter and runpath. So Flea's own jails must bind `/nix/store` too, which is what
`nix-store-jail.patch` does (below).

- `flea-fhs` = `buildFHSEnv { name = "flea-fhs"; runScript = writeShellScript "exec" ''exec "$@"''; dieWithParent = false; targetPkgs = …; }`.
  - `targetPkgs`: flea-unwrapped; `(python3.withPackages (p: [ p.pygobject3 ]))` plus
    glib/gobject-introspection typelibs; expect; bat; bubblewrap; util-linux (prlimit);
    gvfs (gio modules); glib (gio); jq; quickjs-ng (qjs); ripgrep; shared-mime-info;
    udisks (udisksctl); usbmuxd; wl-clipboard; xdg-terminal-exec; xdg-utils; poppler-utils;
    mpv; vulkan-loader; libGL; wayland; diffutils; git; quickshell (upstream lists it as a
    hard dependency; cheap insurance even though 0.4.0's GPUI window does not spawn it);
    the libraries above. Also
    `qt6.qtdeclarative` + `qt6.qtwebengine` when `withHtmlPreview`, and the enabled
    optional packages (`extraPackages` argument).
  - `omarchy-link`: a two-line derivation with `share/omarchy ->
    ${omarchyPath}` (argument, default `/run/current-system/sw/share/omarchy`). Inside the
    namespace, `/usr/share/omarchy` therefore resolves to nixarchy's tree, and the four
    dangling UI symlinks resolve too. This covers the locale registry the intent flagged.
  - `dieWithParent = false`, so apps opened from Flea outlive it.
  - `profile`: `export GI_TYPELIB_PATH=/usr/lib/girepository-1.0` and
    `GIO_EXTRA_MODULES=/usr/lib/gio/modules`. All four Python helpers import `gi`/`Gio`, and
    D-Bus starts them with a minimal environment.
- `flea` = `symlinkJoin`/`runCommand` exposing:
  - `bin/flea` and `bin/flea-gui` → `exec flea-fhs /usr/bin/flea "$@"` (and `flea-gui`)
  - `share/applications`, `share/icons`, `share/xdg-desktop-portal/portals/flea.portal`
    from flea-unwrapped
  - `share/dbus-1/services/*.service` rewritten so `Exec=` is
    `${flea-fhs}/bin/flea-fhs /usr/lib/flea/<helper>`. The session bus starts these outside
    the namespace, so a bare `/usr/lib/flea/…` path would not exist.
  - `passthru = { unwrapped = flea-unwrapped; fhs = flea-fhs; }`
- `package.nix` arguments: `withHtmlPreview ? true`, `extraPackages ? [ ]`,
  `omarchyPath ? "/run/current-system/sw/share/omarchy"`.

### `nixosModules.flea`

```nix
programs.flea = {
  enable = mkEnableOption "Flea";
  package = mkPackageOption … "flea" { };   # from the overlay
};
config = mkIf cfg.enable {
  environment.systemPackages = [ cfg.package ];
  xdg.portal.extraPortals = [ cfg.package ];   # flea.portal is now visible
  services.dbus.packages = [ cfg.package ];   # FileManager1 + portal activation
  xdg.portal.enable = mkDefault true;          # extraPortals is ignored without it
  services.gvfs.enable = mkDefault true;
  services.udisks2.enable = mkDefault true;
  services.usbmuxd.enable = mkDefault true;
  programs.dconf.enable = mkDefault true;  # gio settings backend
};
```

This only registers Flea. It does not make Flea the default for anything. It carries the
same dependency options as the HM module (`htmlPreview`, `optionalDependencies`,
`extraPackages`), applied to `package` via `override`, so the D-Bus-activated portal and
FileManager1 helpers get the same closure as the user's `flea`.

### `homeManagerModules.flea`

```nix
programs.flea = {
  enable = mkEnableOption "Flea";
  package = mkOption { default = pkgs.flea (overridden with the options below); };
  htmlPreview = mkOption { type = bool; default = true; };
  optionalDependencies = {            # one bool each, default false
    sevenzip libarchive ffmpeg ffmpegthumbnailer imagemagick
    libreoffice tailscale zoxide dropbox;
  };
  extraPackages = mkOption { type = listOf package; default = [ ]; };  # into the FHS env
  defaultFileManager.enable = mkEnableOption "...";   # flea --default steps 1+2
  filePicker.enable = mkEnableOption "...";           # flea --picker portal step
  hyprland.bindings.enable = mkEnableOption "...";   # the two file-manager keys
};
```

- `package` is `pkgs.flea.override { withHtmlPreview; extraPackages = optionals + extraPackages; }`
  and is added to `home.packages`. When HM runs as a NixOS module and
  `osConfig.programs.flea.enable` is true, `package` defaults to
  `osConfig.programs.flea.package` instead. An assertion then rejects HM-side dependency
  options ("set them in the NixOS module"), so there is only ever one Flea closure.
  `osConfig` is taken as `osConfig ? null` for standalone HM.
- Optional dependency attributes (e.g. `dropbox` → `pkgs.dropbox-cli`, 7-Zip →
  `_7zz` or `p7zip`) are checked against the pinned nixpkgs in the plan.
- `defaultFileManager.enable`:
  - `xdg.mimeApps.enable = true` (HM writes `mimeapps.list` only with it), and
    `xdg.mimeApps.defaultApplications."inode/directory" = "com.thisisgm.flea.desktop"`
    (`mimeapps.list` is HM-managed on this host already)
  - `xdg.dataFile."dbus-1/services/org.freedesktop.FileManager1.service"`: the same
    contents `flea --default` writes (`docs/install.md` step 2), with the FHS `Exec=`
    above. It goes in `~/.local/share` because the bus reads that directory before
    nautilus's system file.
- `filePicker.enable`: `xdg.configFile."xdg-desktop-portal/hyprland-portals.conf"` with
  `[preferred]` and `org.freedesktop.impl.portal.FileChooser=flea;gtk`. It has no
  `default=` line, per `docs/install.md`, so other interfaces fall through to the system
  file. Your file today holds `default=hyprland;gtk` and `Secret=gnome-keyring`. HM would
  own the file, so an `extraConfig` attrset lets you carry those lines. The first switch
  needs `force = true` or removing the old file, because it is a mutable file now.
- `xdg.configFile."hypr/flea-binds.lua"` is written when `hyprland.bindings.enable` or
  `filePicker.enable` is on. It holds the two `hl.unbind` + `o.bind` pairs (bindings) and the
  picker `o.window` rule (filePicker), each independently, as upstream's `--default` and
  `--picker` do. The text is verbatim from `docs/install.md`, with `flea` replaced by the
  store path. A header comment names the `pcall(require, "hypr.flea-binds")` line to add.
- Not wrapped in options: Flea's own settings file, theme, keymap, menus. Flea rewrites
  them.

### The one source patch

`src/shelfplugin.rs` `install()`: after each `std::fs::copy(&from, &to)`, add
`std::fs::set_permissions(&to, Permissions::from_mode(0o644))`. Without it, the second
version change fails with EACCES (agy finding, confirmed in `src/shelfplugin.rs:60-73`).
It is kept as a `.patch` so a bump that fixes it upstream simply drops the file.

### The `/nix/store` jail patch

The upstream jails and trust checks equate "safe to run in the jail" with "under `/usr`".
Inside the FHS env, every real path is under `/nix/store`. One patch, about 10 lines:

| File | Change |
|---|---|
| `src/backend/sandbox.rs` `BWRAP_FLAGS` | add `--ro-bind /nix/store /nix/store`. `htmlsandbox.rs`, `flashpipe.rs` and `pluginpreview_sandbox.rs` reuse this list. |
| `crates/flea-gui/src/g2/pv3/sandbox.rs` (media jail) | same bind |
| `src/backend/thumbbind.rs` `JAIL_ROOTS`, `MOUNTED` | add `"/nix/store"`. Store targets then need no per-binary bind. This also avoids `trusted()`, which rejects store files: in the FHS user namespace, root-owned files read as the overflow uid. |
| `src/backend/officepdf.rs:58` | accept `real.starts_with("/nix/store")` (LibreOffice detection) |
| `src/backend/codereq.rs:204` | `bat_under` accepts a `/nix/store` target (bat colouring) |

The store is read-only and world-readable on every NixOS host anyway, so binding it
read-only into the jail exposes no more than the host already does.

## Alternatives rejected

- **Native packaging, patching every `/usr` path to store paths.** About 60 production
  sites in two crates, plus the sandbox bind lists and the logic in `thumbbind.rs` that
  decides which paths are already under `/usr`. That is a fork that breaks on every
  upstream bump, and it fails the intent's "small patch set" constraint. The FHS env
  meets "must not rely on host `/usr`", because `/usr` is ours, inside the namespace.
- **Running the upstream test suite in the build.** The tests exec `/usr/bin/{true,sleep,
  sh,python3,git,…}` (more than 100 sites) and need unprivileged namespaces and tmpfs.
  The Nix build sandbox has neither `/usr` nor the namespace, and the FHS env cannot run
  inside the build. Upstream's own `check()` also builds `flea-gui` a second time in debug
  mode, doubling the GPUI compile. **This changes the intent's test constraint. Please
  confirm.** Reviewers split here: agy agrees; Codex wants a measured subset, e.g.
  `cargo test -p flea --lib` with a skip list. If you prefer Codex's option, the plan adds
  one step: run the subset once, record the failures by suite, and skip only those.
  Replacement checks are under Verification.
- **HM managing the shelf plugin directory.** Flea's switch copies, versions and prunes
  the same files (`src/shelfplugin.rs:43-80, 115-147`), so there would be two owners.
- **HM `xdg.portal.*` for the picker.** Enabling it in HM replaces the system portal
  setup that nixarchy owns. Writing the one conf file is narrower.
- **Appending to `bindings.lua` from an activation script.** It is mutable and already
  edited by hand. The separate-file + `pcall(require)` pattern already exists here.
- **`allowBuiltinFetchGit` for the GPUI fork.** One `outputHashes` entry is enough, and it
  keeps the derivation acceptable to nixpkgs later.

## Risks

| Risk | Where | Mitigation |
|---|---|---|
| Nested bwrap: Flea's jails run inside the FHS bwrap namespace. If nesting is refused, jobs fail **silently**: production `sandbox::available()` only checks that `bwrap` and `prlimit` are on PATH, and `sandboxprobe.rs` is test-only. | every host | Runtime check 4 runs real jailed jobs and checks their output, not a notice. `user.max_user_namespaces` is 1029697 here. Fallback (plan update): run Flea outside the FHS with the store patch plus full path rewriting. |
| More "must be under /usr" checks than the five found by grep. | every host | Runtime checks 3–4 exercise each preview kind. A new site is added to the same patch. |
| Apps opened from Flea start inside its namespace (its `/usr`, env). NixOS apps use store paths, so this is mostly harmless. Apps that read `/usr/share/applications` see Flea's profile. | every host | `dieWithParent = false`. Runtime check 6 opens an image and a PDF from Flea. |
| Vulkan ICDs: the loader inside the FHS needs `/run/opengl-driver` (host bind) and its `share/vulkan/icd.d`. | GPU hosts | buildFHSEnv already binds `/run` and adds the opengl-driver lib path. Runtime check 2. Flea falls back to GL. |
| `flea --default` / the Settings > About switch fails against HM-managed files. | when HM options are on | Expected: HM owns the files. The module docs say to use the HM options, not the switch. |
| `omarchyPath` wrong on a host where Omarchy is per-user (`/etc/profiles/per-user/$USER/share/omarchy`). | non-nixarchy or HM-only hosts | It is a package argument. HM/NixOS module docs name it. |
| `hyprland-portals.conf` taken over by HM loses your `Secret=gnome-keyring` line if `extraConfig` isn't set. | this host | Module example carries it. Plan step lists the first-switch backup. |
| GPUI build needs a library the Arch list doesn't name. | build | Found by the first build. Added to `buildInputs` with a plan update. |
| Large closure from qt6-webengine. | all | `htmlPreview = false`. |

## Verification

Build-time (`nix flake check`, CI-able):
1. `nix build .#flea-unwrapped` and `.#flea` succeed with no network.
2. `checks.flea-unwrapped-layout`: assert `$out/share/flea/ui/boot/shell.qml`,
   `$out/share/flea/shelf/manifest.json` (version stamped `0.4.0-1`), `$out/lib/flea/` with 5
   helpers, `$out/bin/{flea,flea-gui}`.
3. `checks.flea-services`: every `share/dbus-1/services/*.service` `Exec=` starts with the
   flea-fhs store path.
4. `checks.hm-module` and `checks.nixos-module`: evaluate each module with every option on.
   Assert the generated files (`flea-binds.lua`, `hyprland-portals.conf`, FileManager1
   service, mimeApps entry) and that `xdg.portal.extraPortals` contains Flea.
5. `nix run .#flea -- --version` prints `0.4.0` (needs the host, not the build sandbox).

Runtime, on this host, after adding the NixOS + HM modules (manual, results go in the PR):
1. `flea` (TUI) lists a directory. `flea --gui` opens a window.
2. GPU renderer in use (Settings > About, or the log), not the GL fallback.
3. Quick Look previews an image, a PDF, a text file, a video, an archive and an HTML file.
4. Jails really work, judged by the results: a photo and a video get thumbnails; a code
   file is colour-highlighted (bat); a Markdown file with maths renders (qjs); a .zip
   extracts and a folder compresses (archive jail); an .odt previews (LibreOffice, if
   enabled). Each one runs a different jail path. Also `strace -f -e execve` on one
   thumbnail shows `bwrap … --ro-bind /nix/store`.
5. Trash, an SMB or SFTP mount via gvfs, and a USB stick via udisks work.
6. Opening a file from Flea starts the default app, which stays up after Flea quits.
7. `gio open` on a folder and Firefox "Show in folder" open Flea (FileManager1).
8. A portal Open dialog (`zenity --file-selection` via portal, or Firefox upload) shows
   Flea's picker, floating.
9. Super+Shift+F and Super+Alt+Shift+F open Flea after the `pcall(require)` line is added.
10. Enabling the shelf twice across a version bump (rebuild with a changed `VERSION`) does
    not fail. This checks the patch.
