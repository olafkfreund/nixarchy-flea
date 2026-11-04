---
status: draft
issue: 0  # placeholder until a tracking issue exists (open question 1)
author: olafkfreund
---

# Intent: Nix package, flake and Home Manager module for Flea

## Problem

Flea (https://github.com/thisisgm/flea, v0.4.0; MIT plus bundled third-party
licenses in `THIRD-PARTY-LICENSES.txt`) is a Rust + Quickshell/QML file
manager built for Omarchy. It ships only as an Arch package (PKGBUILD + Makefile), so it
cannot be installed on nixarchy (Omarchy on NixOS) today. Porting it is not a plain
`buildRustPackage`:

- Two binaries (`flea`, `flea-gui`). `flea-gui` is a non-default workspace member, so it
  needs `--workspace`. It builds on a GPUI fork pinned by git rev (15 git entries in
  `Cargo.lock`, which need `outputHashes`), and its `build.rs` reads `ci/visual/scenes` and
  `startup-order.txt` and runs a linker probe on x86_64.
- It installs data and helpers to fixed FHS paths and looks them up there:
  `/usr/share/flea/ui` (`FLEA_UI`), `/usr/share/flea/shelf` (`FLEA_SHELF`), five
  `/usr/lib/flea/*` helpers (Python D-Bus services for portal, FileManager1, MPRIS; the
  expect script; udisks), and `/usr/share/omarchy` (`OMARCHY_PATH`). It also creates four
  symlinks (`ui/{,boot/}{Commons,Ui}`) into `/usr/share/omarchy/shell/`. The fallback lookup
  walks three directories up from the binary (the dev-tree layout), so a store install
  finds nothing unless the paths are patched or set by env.
- Omarchy data is needed at startup, not only for QML imports: Flea reads
  `$OMARCHY_PATH/default/i18n/locales.json` and can panic without it.
- The runtime sandbox is a separate portability problem. `src/backend/sandbox.rs` binds
  `/usr` into bubblewrap jails and runs `/usr/bin/*` tools in them (prlimit, bwrap,
  ffmpegthumbnailer, true, …). The jail also clears the environment, so `LD_LIBRARY_PATH`
  wrappers do not reach jailed workers. Previews and archive jobs can build fine and still
  fail at runtime on NixOS.
- Several libraries are `dlopen`ed rather than linked (libvulkan, libwayland-client/-egl,
  libEGL, poppler-glib, libmpv), so they must be on the runpath, not only in `buildInputs`.
- Many more `"/usr/bin/<tool>"` literals outside the sandbox (qjs, bat, python, pdfinfo,
  magick, tailscale, git…).
- ~40 runtime dependencies (gvfs + backends, bubblewrap, mpv, poppler, qt6-webengine,
  quickjs-ng, ripgrep, udisks2, Vulkan, Wayland/X11 libs, …) and 9 optional ones.
- Desktop integration fights Home Manager. `flea --default` edits `~/.config/mimeapps.list`
  (a read-only HM symlink on this host, so the command fails), writes a user
  FileManager1 D-Bus service, and appends two binds to `~/.config/hypr/bindings.lua`
  (Super+Shift+F and Super+Alt+Shift+F). `flea --picker` writes
  `~/.config/xdg-desktop-portal/hyprland-portals.conf` (`FileChooser=flea;gtk`, with no
  `default=` line) and adds a Hyprland window rule. The in-app Settings > About switch
  calls the same commands.
- The shelf plugin is copied by Flea into the Omarchy plugin directory, along with the
  store's read-only file modes, so the next version-change copy fails with EACCES.
- gvfs, udisks2, usbmuxd and the xdg-desktop-portal service are NixOS system services.
  A package or an HM module alone cannot start them.

## Proposed outcome

In this repo (`nixarchy-flea`):

- `nix build .#flea` produces a working Flea: `flea` (TUI) and `flea --gui` run on
  nixarchy, with previews, search, trash, gvfs mounts, devices and the portal file chooser
  working as on Arch.
- `flake.nix` exposes `packages.x86_64-linux.{flea,default}`, an `overlays.default`, and
  `homeManagerModules.flea` (plus `nixosModules.flea` only if the portal/D-Bus pieces need
  system level — decided in spec).
- The Home Manager module replaces `flea --default` / `--picker` declaratively. It can
  install the package and optionally make Flea the default file manager (mimeApps), the
  FileManager1 provider, and the portal file chooser. It can also add the two Hyprland
  binds and the picker window rule, install the shelf plugin, and turn on the optional
  dependencies.
- Package registration (portal file, D-Bus activation files) is kept apart from user
  preference (choosing Flea). Where each one lives (package, HM or NixOS module) is
  decided in the spec.
- nixarchy can consume it later as a flake input with no edits to this repo.

## Affected users and systems

- The user's nixarchy hosts (x86_64-linux; aarch64 untested).
- Home Manager user config: mimeapps, xdg-desktop-portal config, Hyprland bindings,
  Omarchy shell plugin directory.
- No changes to nixarchy itself in this task.

## Constraints

- Must build from source in the Nix sandbox (no network in build; pinned git deps hashed).
- Must not rely on `/usr` existing at runtime; patch paths to store paths or use the
  upstream env overrides (`FLEA_UI`, `OMARCHY_PATH`, `FLEA_GIO_BIN`).
- Omarchy shell `Commons`/`Ui` come from nixarchy at runtime
  (`/run/current-system/sw/share/omarchy/shell` on this host), not from this flake.
- Must not run `flea --default` on activation; HM writes the same files declaratively.
- Upstream's own test skips carry over: no display, GPU, network, devices or unprivileged
  namespaces; racy ctime tests; tmpfs-only filesystem tests; `--test-threads=1`; GPUI test
  selectors that exist only in debug builds. The exact list goes in the spec.
- Runtime verification assumes the host provides gvfs, udisks2, usbmuxd,
  xdg-desktop-portal, a Vulkan driver and Omarchy shell + locale data. nixarchy provides
  the Omarchy parts here (`/run/current-system/sw/share/omarchy`). A failed precondition is
  reported, not worked around.
- Keep the patch set small so v0.4.x bumps are a version + hash change.

## Open questions

1. Tracking issue: is there a GitHub repo/issue for this work, or keep the `0` placeholder?
2. Scope of "all the options": HM options only for what `flea --default`, `--picker` and
   the shelf do, plus one switch per optional dep (7zip, ffmpeg, ffmpegthumbnailer,
   imagemagick, libarchive, libreoffice, tailscale, zoxide, dropbox-cli). No options
   mirroring Flea's in-app settings, since Flea owns that file and rewrites it. OK?
3. Hyprland binds: `bindings.lua` is a mutable user file here. Should HM emit the binds
   through the Hyprland HM/nixarchy settings, or leave them to nixarchy?
4. Shelf plugin ownership: HM installs it (and Flea's in-app shelf switch is disabled or
   patched), or Flea installs it (with the file-mode fix)?
5. System services: does nixarchy already enable gvfs, udisks2, usbmuxd and the portal on
   your hosts, or should this flake also ship `nixosModules.flea`?
6. Optional deps default: off (small closure) or on (Arch parity)? libreoffice is large.
7. `qt6-webengine` (HTML preview helper) is a hard dep on Arch: on by default, or behind
   an option?
8. Platforms: x86_64-linux only, or also aarch64-linux? (Upstream already skips some
   tests on emulated aarch64.)
