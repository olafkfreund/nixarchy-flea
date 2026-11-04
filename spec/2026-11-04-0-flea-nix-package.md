---
status: approved
issue: 1
intent: intent/2026-11-04-0-flea-nix-package.md
---

# Spec: Nix package, flake and Home Manager module for Flea

> **Revision 2 (2026-11-04):** use upstream's prebuilt release binaries instead of building
> from source (requested after a 12-minute cold build). The source build (`flea-unwrapped`,
> commits up to `33d96d9`) and both `.patch` files are dropped. The four losses that
> prebuilt binaries would cause are fixed in packaging instead (see "Making the prebuilt
> binaries work on NixOS"). The modules, FHS runtime and verification are unchanged except
> where marked.

## Decisions on the intent's open questions

The intent was approved without answers, so these are defaults. Change any of them at this
gate.

| # | Question | Decision |
|---|---|---|
| 1 | Tracking issue | Keep `0` until a repo/issue exists. |
| 2 | Option scope | Only what `flea --default`, `flea --picker` and the shelf do, plus one switch per optional dependency. No options mirroring in-app settings. |
| 3 | Hyprland binds | HM writes `~/.config/hypr/flea-binds.lua`. You add `pcall(require, "hypr.flea-binds")` to `bindings.lua` once, the same pattern as `hypr.ai-mirror-binds` on this host. |
| 4 | Shelf plugin | Flea owns it (its in-app switch). The `flea` wrapper makes the copied files user-writable before Flea starts (rev. 2; was a source patch). HM does not manage the plugin directory. |
| 5 | System services | Ship `nixosModules.flea`. Portal discovery is system-level here: `flea.portal` must be in `/run/current-system/sw/share/xdg-desktop-portal/portals`. |
| — | Build-time tests | None. Rev. 2 compiles nothing, so there is no test phase. Upstream runs its suite before publishing the release. Approved as "off" in rev. 1. |
| 6 | Optional deps default | Off. |
| 7 | `qt6-webengine` HTML previews | On by default (Arch hard dep), `withHtmlPreview` to drop it. |
| 8 | Platforms | `x86_64-linux` only. |

## Design

### Layout

```
flake.nix            inputs: nixpkgs (unstable); outputs below
nix/package.nix      flea-bin (unpacked release) + flea (FHS runtime)
nix/hm-module.nix    homeManagerModules.flea
nix/nixos-module.nix nixosModules.flea
```

Flake outputs (`x86_64-linux`): `packages.{flea,flea-bin,default}`,
`overlays.default` (adds `flea`, `flea-bin`), `homeManagerModules.{flea,default}`,
`nixosModules.{flea,default}`, `checks` (see Verification), `formatter` (nixfmt).
A bump is the version plus one hash.

### Unpack: `flea-bin`

`stdenvNoCC.mkDerivation`, no compiler:
- `src = fetchurl { url = "https://github.com/thisisgm/flea/releases/download/v${version}/flea-v${version}-linux-x86_64.tar.gz"; hash = …; }`.
  Upstream publishes a `.sha256` next to it, and the plan cross-checks the two.
- `installPhase` mirrors upstream's own `packaging/flea-bin/PKGBUILD` `package()` with
  `$out` as the root, not `$pkgdir/usr`. That gives `bin/{flea,flea-gui}`, `lib/flea/` (5
  helpers), `share/flea/{ui,shelf,i18n}` (catalogs only), the shelf version stamp
  `${version}-1`, D-Bus service files, `flea.portal`, the desktop file, the icon and
  licenses. It also creates the four `ui/{,boot/}{Commons,Ui}` symlinks to
  `/usr/share/omarchy/shell/…`. The pacman hook is skipped.
- The binaries stay byte-for-byte upstream's: `dontPatchELF`, `dontStrip`,
  `dontPatchShebangs` (helpers keep `#!/usr/bin/python3`, `#!/usr/bin/expect -f`), and
  `dontCheckForBrokenSymlinks` (the four UI links dangle on purpose).
- They need glibc ≥ 2.39 and `/lib64/ld-linux-x86-64.so.2` (checked: nixpkgs has 2.44,
  and the FHS env provides the loader). Linked libraries: gdk-pixbuf, glib/gobject, libxcb,
  fontconfig, libxkbcommon(-x11), libgcc_s. The `dlopen`ed ones (vulkan, wayland, EGL,
  poppler-glib, libmpv) come from the FHS `/usr/lib` and its `ld.so.cache`.
- `meta.sourceProvenance = [ binaryNativeCode ]`. `license` is upstream's binary-package
  list (`packaging/flea-bin/PKGBUILD:12`): asl20, bsd2, bsd3, cc0, isc, mit, mpl20,
  unicode-30, zlib.

### Runtime: `flea` = `buildFHSEnv`

Flea assumes an Arch `/usr`: about 60 production code sites, bwrap jails that bind `/usr`
(`src/backend/sandbox.rs:35`, `crates/flea-gui/src/g2/pv3/sandbox.rs:62`), `/usr/share/mime`,
and helpers with `#!/usr/bin/python3` and `#!/usr/bin/expect`. A prebuilt binary cannot be
patched, so Flea runs in an FHS namespace where `/usr` is a profile holding Flea and every
dependency. That `/usr` is a tree of symlinks into `/nix/store`, which breaks Flea's
jails and trust checks unless the packaging fixes them (below).

- `flea-fhs` = `buildFHSEnv { name = "flea-fhs"; runScript = writeShellScript "exec" ''exec "$@"''; dieWithParent = false; targetPkgs = …; }`.
  - `targetPkgs`: flea-bin; the `bwrap` shim (below) instead of `bubblewrap`; `(python3.withPackages (p: [ p.pygobject3 ]))` plus
    glib/gobject-introspection typelibs; expect; bat; util-linux (prlimit); libheif (also ships `heif-thumbnailer`);
    hicolor-icon-theme;
    gvfs (gio modules); glib (gio); jq; quickjs-ng (qjs); ripgrep; shared-mime-info;
    udisks (udisksctl); usbmuxd; wl-clipboard; xdg-terminal-exec; xdg-utils; poppler-utils;
    mpv; vulkan-loader; libGL; wayland; diffutils; git; quickshell (upstream lists it as a
    hard dependency; cheap insurance even though 0.4.0's GPUI window does not spawn it);
    the libraries `flea-bin` links and `dlopen`s (above). Also
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
  - `bin/flea` and `bin/flea-gui` → the shelf permission fix (below), then
    `exec flea-fhs /usr/bin/flea "$@"` (and `flea-gui`)
  - `share/applications`, `share/icons`, `share/xdg-desktop-portal/portals/flea.portal`
    from flea-bin
  - `share/dbus-1/services/*.service` rewritten so `Exec=` is
    `${flea-fhs}/bin/flea-fhs /usr/lib/flea/<helper>`. The session bus starts these outside
    the namespace, so a bare `/usr/lib/flea/…` path would not exist.
  - `passthru = { unwrapped = flea-bin; fhs = flea-fhs; optionalPackages; }`
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

### Making the prebuilt binaries work on NixOS

The rev. 1 source patches fixed four things in Flea's code. Each is now fixed outside the
binary:

| Loss with plain prebuilt | Cause in upstream code | Fix in packaging |
|---|---|---|
| Every jail is broken: tools and libraries are dangling links | jails bind `/usr` and `/etc` only (`sandbox.rs` `BWRAP_FLAGS`, `pv3/sandbox.rs`); FHS `/usr` links into the store | **`bwrap` shim.** Both jails run `bwrap` from PATH (`sandbox.rs` `BWRAP = "bwrap"`, `pv3/sandbox.rs:42`, and through `prlimit`'s `execvp`). The FHS env gets a `bin/bwrap` script: `exec ${bubblewrap}/bin/bwrap --ro-bind /nix/store /nix/store --ro-bind ${glibc}/etc ${glibc}/etc "$@"`. The second bind keeps the FHS env's `ld.so.cache` link, which lives on a tmpfs over `${glibc}/etc`. bwrap's binds are recursive, so the first bind should already carry it, but the jailed `flea`/`flea-gui` (thumbnail worker, `/flea-media`) have no RUNPATH, so they depend on that cache. The store is read-only and world-readable on NixOS anyway. |
| Thumbnails from external thumbnailers (video, PDF) refused | `thumbbind.rs` canonicalizes the tool. A `/nix/store` target is outside `MOUNTED` (`/usr`, `/etc`), so it gets a per-file bind and `trusted()`, which needs uid 0 or the user. In the FHS user namespace, root-owned store files read as the overflow uid, so they fail. | **Real files under `/usr/bin`.** In `buildFHSEnv`'s `extraBuildCommands`, each trust-checked tool's `usr/bin` symlink is replaced by a copy of its target. The canonical path is then `/usr/bin/<tool>`, inside `MOUNTED`, so no bind and no `trusted()` check happen. The copy keeps its store interpreter and runpath, which resolve through the shim's store bind. |
| LibreOffice previews off | `officepdf.rs:58` needs `canonicalize(soffice)` under `/usr` | the same copy, for `soffice`/`libreoffice` when the optional dep is on |
| bat colouring off | `codereq.rs:204` needs `canonicalize(bat)` under `/usr` | the same copy, for `bat` |
| Shelf update fails (EACCES) at the next version | `shelfplugin.rs:72` `std::fs::copy` keeps the store's `0444` mode | **FHS `profile`.** `chmod -R u+w "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/io.github.thisisgm.flea-shelf" 2>/dev/null` runs in `flea-fhs`'s profile. Every entry into the env sees it: the `flea` wrappers and the D-Bus-started portal and FileManager1 helpers. The first launch after an upgrade, by any route, therefore finds writable files. |

The copied tools are `bat`, `soffice` and `libreoffice`, plus every program named by an
`Exec=` or `TryExec=` line in the FHS env's `usr/share/thumbnailers/*.thumbnailer` files.
This is computed in `extraBuildCommands`, so `heif-thumbnailer`, `ffmpegthumbnailer`,
`gdk-pixbuf-thumbnailer` and any thumbnailer from `extraPackages` are covered
automatically. Each is copied only if present, with `cp -L --remove-destination`: the
entry is a symlink into the read-only store, so copying through it fails. LibreOffice comes
from the wrapped `pkgs.libreoffice`, whose `bin/soffice` is a script with absolute store
paths. The unwrapped `soffice` resolves its siblings from `$0` and would break as a copy.
Copying is limited to these on purpose: relocatable programs such as python find their
prefix from their own path, and a copy would break them.

## Alternatives rejected

- **Building from source (rev. 1).** Worked (12m08s cold on 128 cores, 75 MB), but was
  slow for consumers without a cache. It also carried two source patches. Kept in git
  history (`33d96d9`) as the fallback if a release tarball is ever missing or broken.
- **Prebuilt binaries patched with `patchelf` / `autoPatchelfHook` to run without an FHS
  env.** That fixes the loader only. The ~60 `/usr` literals, the jail binds and the trust
  checks are compiled in, so the FHS env is still needed.
- **Binary-patching the `/usr` strings.** Fragile and unreviewable.
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

## Risks

| Risk | Where | Mitigation |
|---|---|---|
| Nested bwrap: Flea's jails run inside the FHS bwrap namespace. If nesting is refused, jobs fail **silently**: production `sandbox::available()` only checks that `bwrap` and `prlimit` are on PATH, and `sandboxprobe.rs` is test-only. | every host | Runtime check 4 runs real jailed jobs and checks their output, not a notice. `user.max_user_namespaces` is 1029697 here. Fallback (plan update): run Flea outside the FHS with the store patch plus full path rewriting. |
| More "must be under /usr" checks than the ones found by grep, or a trust-checked tool not on the copy list. | every host | Runtime checks 3–4 exercise each preview kind. A missing tool is added to the copy list. |
| Upstream stops shipping the x86_64 tarball, or changes its layout. | bumps | The bump fails at `installPhase` and never reaches `main` (#2). Fallback: the rev. 1 source build from git history. |
| A copied tool depends on its own location (`/proc/self/exe`) to find data. | runtime | The list is short and each tool is exercised by runtime check 4. Drop a tool from the list if its copy misbehaves (the loss comes back for that tool only). |
| D-Bus-started helpers get a minimal environment. Flea's shelf switch runs `omarchy` and `omarchy-shell` from PATH (`shelfplugin.rs:94,112`). | portal / FileManager1 launches | The FHS PATH ends with the host PATH. On NixOS the systemd user environment includes `/run/current-system/sw/bin`. Runtime checks 7–8 open Flea that way. |
| `usr/bin` in the FHS root is a whole-directory symlink (buildEnv collapses a dir with one source), so it cannot be written. | build | With dozens of packages it is a merged real directory. The plan's build check asserts the copies are regular files. |
| Apps opened from Flea start inside its namespace (its `/usr`, env). NixOS apps use store paths, so this is mostly harmless. Apps that read `/usr/share/applications` see Flea's profile. | every host | `dieWithParent = false`. Runtime check 6 opens an image and a PDF from Flea. |
| Vulkan ICDs: the loader inside the FHS needs `/run/opengl-driver` (host bind) and its `share/vulkan/icd.d`. | GPU hosts | buildFHSEnv already binds `/run` and adds the opengl-driver lib path. Runtime check 2. Flea falls back to GL. |
| `flea --default` / the Settings > About switch fails against HM-managed files. | when HM options are on | Expected: HM owns the files. The module docs say to use the HM options, not the switch. |
| `omarchyPath` wrong on a host where Omarchy is per-user (`/etc/profiles/per-user/$USER/share/omarchy`). | non-nixarchy or HM-only hosts | It is a package argument. HM/NixOS module docs name it. |
| `hyprland-portals.conf` taken over by HM loses your `Secret=gnome-keyring` line if `extraConfig` isn't set. | this host | Module example carries it. Plan step lists the first-switch backup. |
| The prebuilt binary needs a library that the FHS env lacks. | runtime | `ldd` inside `flea-fhs` (plan check) lists no `not found`. |
| Large closure from qt6-webengine. | all | `htmlPreview = false`. |

## Verification

Build-time (`nix flake check`, CI-able):
1. `nix build .#flea-bin` and `.#flea` succeed. Only the release tarball is fetched.
2. `checks.flea-bin-layout`: assert `$out/share/flea/ui/boot/shell.qml`,
   `$out/share/flea/shelf/manifest.json` (version stamped `0.4.0-1`), `$out/lib/flea/` with 5
   helpers, `$out/bin/{flea,flea-gui}`.
3. `checks.flea-services`: every `share/dbus-1/services/*.service` `Exec=` starts with the
   flea-fhs store path.
4. `checks.hm-module` and `checks.nixos-module`: evaluate each module with every option on.
   Assert the generated files (`flea-binds.lua`, `hyprland-portals.conf`, FileManager1
   service, mimeApps entry) and that `xdg.portal.extraPortals` contains Flea.
5. `nix run .#flea -- --version` prints `0.4.0` (needs the host, not the build sandbox).
6. Inside `flea-fhs`: `ldd /usr/bin/flea-gui` has no `not found`; `/usr/bin/bat` and
   `/usr/bin/ffmpegthumbnailer` (when enabled) are regular files, not symlinks; `bwrap`
   resolves to the shim.

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
10. Enabling the shelf twice across a version bump does not fail. Simulate it: enable it,
    edit the copied `manifest.json` version, relaunch `flea`, toggle again. This checks
    the wrapper's chmod.
