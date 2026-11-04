---
status: draft
issue: 0  # placeholder until a tracking issue exists (open question 1)
author: olafkfreund
---

# Intent: Nix package, flake and Home Manager module for Flea

## Problem

Flea (https://github.com/thisisgm/flea, v0.4.0, MIT) is a Rust + Quickshell/QML file
manager built for Omarchy. It ships only as an Arch package (PKGBUILD + Makefile), so it
cannot be installed on nixarchy (Omarchy on NixOS) today. Porting it is not a plain
`buildRustPackage`:

- Two binaries (`flea`, `flea-gui`; `flea-gui` is a workspace member built on a GPUI fork
  pulled by git rev, so the vendored deps need `outputHashes`).
- It installs data and helpers to fixed FHS paths and looks them up there:
  `/usr/share/flea/ui` (overridable via `FLEA_UI`), `/usr/lib/flea/*` helpers (Python
  D-Bus services, expect script), `/usr/share/omarchy` (overridable via `OMARCHY_PATH`),
  and symlinks `ui/Commons`, `ui/Ui` into `/usr/share/omarchy/shell/`.
- Many `"/usr/bin/<tool>"` literals in the source (bwrap, qjs, bat, python, ffmpegthumbnailer,
  pdfinfo, magick, tailscale…), partly inside bubblewrap sandboxes that bind FHS paths.
- ~40 runtime dependencies (gvfs + backends, bubblewrap, mpv, poppler, qt6-webengine,
  quickjs-ng, ripgrep, udisks2, Vulkan, Wayland/X11 libs, …) and 9 optional ones.
- Desktop integration (`flea --default`) imperatively edits `~/.config/mimeapps.list`,
  `portals.conf`, `~/.config/hypr/bindings.lua` and a user D-Bus service file — which
  fights a declarative Home Manager setup.

## Proposed outcome

In this repo (`nixarchy-flea`):

- `nix build .#flea` produces a working Flea: `flea` (TUI) and `flea --gui` run on
  nixarchy, with previews, search, trash, gvfs mounts, devices and the portal file chooser
  working as on Arch.
- `flake.nix` exposes `packages.x86_64-linux.{flea,default}`, an `overlays.default`, and
  `homeManagerModules.flea` (plus `nixosModules.flea` only if the portal/D-Bus pieces need
  system level — decided in spec).
- The Home Manager module declaratively replaces `flea --default`: install the package,
  optionally make Flea the default file manager (mimeApps), the file chooser portal
  (`xdg.portal` config), the FileManager1 D-Bus service, the Hyprland Super+Shift+F binding,
  the optional Omarchy bar shelf plugin, and toggles for the optional dependencies.
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
- Upstream tests that need a display, GPU, network or real devices are skipped in the
  build; the rest should run.
- Keep the patch set small so v0.4.x bumps are a version + hash change.

## Open questions

1. Tracking issue: is there a GitHub repo/issue for this work, or keep the `0` placeholder?
2. Scope of "all the options": I propose HM options only for what `flea --default` /
   `--picker` / the shelf do, plus one `extraPackages`-style switch for the optional deps
   (7zip, ffmpeg, ffmpegthumbnailer, imagemagick, libarchive, libreoffice, tailscale,
   zoxide, dropbox-cli). No options mirroring Flea's own in-app settings — Flea owns its
   settings file and rewrites it. OK?
3. Optional deps default: off (small closure) or on (Arch-parity)? libreoffice and
   qt6-webengine are large.
4. `qt6-webengine` HTML preview helper is a hard dep on Arch "until flea-html lands" —
   include it by default or behind an option?
5. Platforms: x86_64-linux only, or also aarch64-linux?
