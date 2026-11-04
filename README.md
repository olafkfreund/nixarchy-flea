# nixarchy-flea

Nix package, NixOS module, and Home Manager module for [Flea](https://github.com/thisisgm/flea), the Omarchy file manager.

Supported platform: `x86_64-linux` only.

## How it is packaged

Flea is packaged from upstream's prebuilt release binaries (`flea-bin`) without patching or recompiling, and runs inside a `buildFHSEnv` (`flea-fhs`). To work on NixOS without source patches, the FHS environment does three things:

- **Bubblewrap shim (`bwrap`)**: wraps `bwrap` and puts `--ro-bind /nix/store /nix/store` and `--ro-bind ${glibc}/etc ${glibc}/etc` before Flea's own arguments, so binaries and libraries inside Flea's inner sandbox resolve `/nix/store` paths. It also adds `--ro-bind-try /.host-etc /.host-etc`: inside `buildFHSEnv`, `/etc` entries link there, and without it fonts and other host `/etc` files would be missing in the jails.
- **Real-file copies of trust-checked tools**: replaces `/usr/bin` symlinks with real file copies for `bat`, `soffice`, `libreoffice`, and every binary named in `/usr/share/thumbnailers/*.thumbnailer`. It also rewrites those `.thumbnailer` files to point at the `/usr/bin` copies, which satisfies Flea's symlink/ownership checks.
- **`qml6` for HTML previews**: a small `qml6` wrapper (Arch's name for Qt's QML runner) that sets the QML import path, so the HTML preview jail finds QtWebEngine.
- **Shelf permissions**: runs `chmod -R u+w` on `~/.config/omarchy/plugins/io.github.thisisgm.flea-shelf` in the FHS profile so Flea can update its shelf plugin after copying read-only files from the Nix store.

## Try it

```sh
nix run github:olafkfreund/nixarchy-flea -- --gui
```

Flea runs, but nothing is registered: there is no portal picker, no "Show in folder" and
no default file manager. For those, use the modules below.

## CI and updates

[![check](https://github.com/olafkfreund/nixarchy-flea/actions/workflows/check.yml/badge.svg)](https://github.com/olafkfreund/nixarchy-flea/actions/workflows/check.yml)

CI proves build, `nix flake check`, the smoke step (libraries, version, a jailed run) and format. It does not prove the GUI, portal, `gvfs` or GPU.

A daily bot (`bump.yml`) looks for a new upstream release and opens a PR. The PR body lists upstream changes to the files the packaging relies on. "Inspection incomplete" means GitHub's compare was truncated or had no patch for some files, so read those yourself. You review and merge. A weekly PR (`lock.yml`) refreshes `nixpkgs`. Nothing merges by itself. `nixarchy` follows `main`.

If a bot PR shows no check, close and reopen it (as you), or push to it.

Manual liveness check:

```bash
gh run list -R olafkfreund/nixarchy-flea -w bump.yml -L 3
```

Failures open (or update) an issue labelled `bump-failed` or `lock-failed`.

## Flake input

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixarchy-flea = {
      url = "github:olafkfreund/nixarchy-flea";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
}
```

## Usage

When `programs.flea.enable` is on in NixOS, set the runtime and dependency options (`htmlPreview`, `optionalDependencies`, `extraPackages`, `omarchyPath`) in the NixOS module. The Home Manager module reuses the NixOS package and rejects duplicate dependency settings. In standalone Home Manager (without the NixOS module), set those options directly under Home Manager's `programs.flea`.

### NixOS + Home Manager example (all options)

```nix
{ inputs, pkgs, ... }:
{
  imports = [
    inputs.nixarchy-flea.nixosModules.flea
  ];

  # Needed only when programs.flea.optionalDependencies.dropbox = true.
  nixpkgs.config.allowUnfree = true;

  programs.flea = {
    enable = true;
    htmlPreview = true;
    optionalDependencies = {
      sevenzip = true;
      libarchive = true;
      ffmpeg = true;
      ffmpegthumbnailer = true;
      imagemagick = true;
      libreoffice = true;
      tailscale = true;
      zoxide = true;
      dropbox = false;
    };
    extraPackages = [ ];
    omarchyPath = "/run/current-system/sw/share/omarchy";
    # package: leave unset; the default is Flea built with the options above.
  };

  home-manager.users.alice = {
    imports = [
      inputs.nixarchy-flea.homeManagerModules.flea
    ];

    programs.flea = {
      enable = true;
      # Set htmlPreview, optionalDependencies, extraPackages, omarchyPath, and package
      # here only when the NixOS module is not enabled.
      defaultFileManager.enable = true;
      filePicker = {
        enable = true;
        extraConfig = {
          default = "hyprland;gtk";
          "org.freedesktop.impl.portal.Secret" = "gnome-keyring";
        };
      };
      hyprland.bindings.enable = true;
    };
  };
}
```

## Options

### NixOS and Home Manager (`programs.flea.*`)

- `programs.flea.enable`: Enable Flea (in NixOS: registers the package, portal backend, D-Bus services, and `gvfs`/`udisks2`/`usbmuxd`/`dconf`; in Home Manager: installs the package and enables selected user files).
- `programs.flea.htmlPreview` (`bool`, default `true`): Include `qt6-webengine` for HTML previews (large closure).
- `programs.flea.optionalDependencies.sevenzip` (`bool`, default `false`): Add the optional dependency `sevenzip` (`_7zz` linked as `7z`) to Flea's FHS environment.
- `programs.flea.optionalDependencies.libarchive` (`bool`, default `false`): Add the optional dependency `libarchive` to Flea's FHS environment.
- `programs.flea.optionalDependencies.ffmpeg` (`bool`, default `false`): Add the optional dependency `ffmpeg` to Flea's FHS environment.
- `programs.flea.optionalDependencies.ffmpegthumbnailer` (`bool`, default `false`): Add the optional dependency `ffmpegthumbnailer` to Flea's FHS environment.
- `programs.flea.optionalDependencies.imagemagick` (`bool`, default `false`): Add the optional dependency `imagemagick` to Flea's FHS environment.
- `programs.flea.optionalDependencies.libreoffice` (`bool`, default `false`): Add the optional dependency `libreoffice` to Flea's FHS environment.
- `programs.flea.optionalDependencies.tailscale` (`bool`, default `false`): Add the optional dependency `tailscale` to Flea's FHS environment.
- `programs.flea.optionalDependencies.zoxide` (`bool`, default `false`): Add the optional dependency `zoxide` to Flea's FHS environment.
- `programs.flea.optionalDependencies.dropbox` (`bool`, default `false`): Add the optional dependency `dropbox` (`dropbox-cli`) to Flea's FHS environment. Requires `nixpkgs.config.allowUnfree = true` because `dropbox-cli` depends on the unfree `dropbox` package.
- `programs.flea.extraPackages` (`listOf package`, default `[ ]`): Extra packages to put in Flea's FHS environment (e.g. more thumbnailers).
- `programs.flea.omarchyPath` (`str`, default `"/run/current-system/sw/share/omarchy"`): Where Omarchy's data tree (`shell/Commons`, `shell/Ui`, `default/i18n/locales.json`) lives on the host, exposed as `/usr/share/omarchy` in the FHS environment.
- `programs.flea.package` (`package`): The Flea package to install (defaults to the NixOS `programs.flea.package` when the NixOS module is enabled, or `pkgs.flea.override` with the options above).

### Home Manager only (`programs.flea.*`)

- `programs.flea.defaultFileManager.enable` (`bool`, default `false`): Enable Flea as the default file manager (`inode/directory` MIME association and `~/.local/share/dbus-1/services/org.freedesktop.FileManager1.service`).
- `programs.flea.filePicker.enable` (`bool`, default `false`): Enable Flea as the XDG desktop portal file chooser in `~/.config/xdg-desktop-portal/hyprland-portals.conf` and add the floating window rule for `com.thisisgm.flea.picker`.
- `programs.flea.filePicker.extraConfig` (`attrsOf str`, default `{ }`): Additional `[preferred]` portal lines to retain in `hyprland-portals.conf`; a `default=` line is written only when supplied here.
- `programs.flea.hyprland.bindings.enable` (`bool`, default `false`): Enable Flea's two Omarchy file-manager keybindings in `~/.config/hypr/flea-binds.lua`.

## Setup notes

### Per-user Omarchy path (`omarchyPath`)

`programs.flea.omarchyPath` defaults to `/run/current-system/sw/share/omarchy`. If Omarchy is installed in a user profile instead of `environment.systemPackages`, point `omarchyPath` at the user profile path, for example:

```nix
programs.flea.omarchyPath = "/etc/profiles/per-user/alice/share/omarchy";
```

Write the user name out in full: Nix does not expand `$USER` here. The NixOS package is
system-wide, so a per-user path serves only that one user. In that case, set it in the
Home Manager module (without the NixOS module) instead.

### Hyprland bindings

When `programs.flea.hyprland.bindings.enable` or `programs.flea.filePicker.enable` is on, Home Manager writes `~/.config/hypr/flea-binds.lua`. Load it once by adding this line to `~/.config/hypr/bindings.lua`:

```lua
pcall(require, "hypr.flea-binds")
```

### Portal file picker and first switch

When `programs.flea.filePicker.enable = true`, Home Manager manages `~/.config/xdg-desktop-portal/hyprland-portals.conf` and only writes `org.freedesktop.impl.portal.FileChooser=flea;gtk` plus `filePicker.extraConfig`. To keep the host's existing portal defaults and keyring backend, set:

```nix
programs.flea.filePicker.extraConfig = {
  default = "hyprland;gtk";
  "org.freedesktop.impl.portal.Secret" = "gnome-keyring";
};
```

Before the first rebuild with `filePicker.enable = true`, move the existing mutable `~/.config/xdg-desktop-portal/hyprland-portals.conf` aside so Home Manager does not refuse to overwrite it:

```sh
mv ~/.config/xdg-desktop-portal/hyprland-portals.conf \
   ~/.config/xdg-desktop-portal/hyprland-portals.conf.pre-flea
```

Alternatively, set `xdg.configFile."xdg-desktop-portal/hyprland-portals.conf".force = true;` in Home Manager.

### Default file manager and first switch

`defaultFileManager.enable` turns on Home Manager's `xdg.mimeApps`, which then owns
`~/.config/mimeapps.list`. If that file is still a mutable file, move it aside before the
first switch, the same way as `hyprland-portals.conf`, and carry the associations you want
to keep into `xdg.mimeApps`.

### Sandbox note

The `bwrap` shim makes the whole `/nix/store` readable, read-only, inside Flea's preview
jails. That is no more than any process on NixOS can read, but it is more than upstream's
Arch jail sees. The jails still have no network, and see only the one file being previewed, not the rest of your home directory.

### Warning: do not mix with Flea's imperative toggles

Do not run `flea --default` or `flea --picker`, and do not toggle the default file manager switch in Flea's **Settings > About** pane when using `defaultFileManager.enable`, `filePicker.enable`, or `hyprland.bindings.enable`. Those commands try to rewrite files owned by Home Manager (`mimeapps.list`, `org.freedesktop.FileManager1.service`, `hyprland-portals.conf`, and Hyprland bindings).
