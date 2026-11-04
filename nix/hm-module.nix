{
  config,
  lib,
  options,
  pkgs,
  osConfig ? null,
  ...
}:
let
  cfg = config.programs.flea;
  # The consumer's overlay wins; a different pkgs.flea (no optionalPackages) or none falls back to this repo's package.nix.
  base =
    if pkgs ? flea && pkgs.flea ? optionalPackages then
      pkgs.flea
    else
      pkgs.callPackage ./package.nix { };
  osEnabled = osConfig != null && (osConfig.programs.flea.enable or false);
  enabledOptionals = builtins.attrValues (
    lib.filterAttrs (name: _: cfg.optionalDependencies.${name}) base.optionalPackages
  );
  # Option defaults count as defined; only a higher-priority definition is user-supplied.
  # (mkDefault, 1000, in a shared profile is not counted as a user choice.)
  explicitlyDefined = option: option.isDefined && option.highestPrio < 1000;
in
{
  options.programs.flea = {
    enable = lib.mkEnableOption "Flea";

    htmlPreview = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Include HTML preview support in Flea. Set this in the NixOS module when it is enabled.";
    };

    optionalDependencies = lib.mapAttrs (
      name: _:
      lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Include the optional ${name} package in Flea's runtime. Set this in the NixOS module when it is enabled.";
      }
    ) base.optionalPackages;

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Extra packages inside Flea's FHS runtime. Set this in the NixOS module when it is enabled.";
    };

    omarchyPath = lib.mkOption {
      type = lib.types.str;
      default = "/run/current-system/sw/share/omarchy";
      description = "Path to Omarchy's share tree inside Flea's runtime. Set this in the NixOS module when it is enabled.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default =
        if osEnabled then
          osConfig.programs.flea.package
        else
          base.override {
            withHtmlPreview = cfg.htmlPreview;
            extraPackages = enabledOptionals ++ cfg.extraPackages;
            inherit (cfg) omarchyPath;
          };
      defaultText = lib.literalExpression "the NixOS Flea package when enabled, otherwise pkgs.flea overridden with Home Manager dependency options";
      description = "Flea package to install for this user.";
    };

    defaultFileManager.enable = lib.mkEnableOption "Flea as the default file manager. Use this option instead of `flea --default` or the Settings > About switch, which edit Home Manager-owned files";

    filePicker = {
      enable = lib.mkEnableOption "Flea as the file picker. Use this option instead of `flea --picker`, `flea --default`, or the Settings > About switch. On the first switch, move the existing mutable hyprland-portals.conf aside or set its Home Manager file's force = true";
      extraConfig = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          default = "hyprland;gtk";
          "org.freedesktop.impl.portal.Secret" = "gnome-keyring";
        };
        description = "Additional [preferred] portal lines to retain, such as this host's default and Secret settings. A default= line is written only when supplied here.";
      };
    };

    hyprland.bindings.enable = lib.mkEnableOption ''Flea's two Omarchy file-manager keys. Add `pcall(require, "hypr.flea-binds")` to Hyprland's bindings.lua. Use this option instead of `flea --default` or the Settings > About switch'';
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion =
              !osEnabled
              || !(
                explicitlyDefined options.programs.flea.htmlPreview
                || lib.any explicitlyDefined (builtins.attrValues options.programs.flea.optionalDependencies)
                || explicitlyDefined options.programs.flea.extraPackages
                || explicitlyDefined options.programs.flea.omarchyPath
                || explicitlyDefined options.programs.flea.package
              );
            message = "programs.flea: with the NixOS module enabled, set htmlPreview, optionalDependencies, extraPackages, omarchyPath and package there; Home Manager reuses the NixOS package";
          }
        ];
        home.packages = [ cfg.package ];
      }

      (lib.mkIf cfg.defaultFileManager.enable {
        xdg.mimeApps.enable = true;
        xdg.mimeApps.defaultApplications."inode/directory" = "com.thisisgm.flea.desktop";
        xdg.dataFile."dbus-1/services/org.freedesktop.FileManager1.service".text = ''
          # Written by Home Manager programs.flea.defaultFileManager.
          [D-BUS Service]
          Name=org.freedesktop.FileManager1
          Exec=${
            cfg.package.fhs or (throw "programs.flea.package must be this flake's flea (it needs passthru.fhs)")
          }/bin/flea-fhs /usr/lib/flea/flea-filemanager1
        '';
      })

      (lib.mkIf cfg.filePicker.enable {
        xdg.configFile."xdg-desktop-portal/hyprland-portals.conf".text = ''
          [preferred]
          org.freedesktop.impl.portal.FileChooser=flea;gtk
        ''
        + lib.concatStringsSep "" (
          lib.mapAttrsToList (name: value: "${name}=${value}\n") cfg.filePicker.extraConfig
        );
      })

      (lib.mkIf (cfg.hyprland.bindings.enable || cfg.filePicker.enable) {
        xdg.configFile."hypr/flea-binds.lua".text = ''
          -- Load with pcall(require, "hypr.flea-binds") in bindings.lua.
        ''
        + lib.optionalString cfg.hyprland.bindings.enable ''
          hl.unbind("SUPER + SHIFT + F")
          o.bind("SUPER + SHIFT + F", "File manager", { launch = '${lib.getExe cfg.package} --gui' })
          hl.unbind("SUPER + ALT + SHIFT + F")
          o.bind("SUPER + ALT + SHIFT + F", "File manager (cwd)", { launch = '${lib.getExe cfg.package} --gui "$(omarchy-cmd-terminal-cwd)"' })
        ''
        + lib.optionalString cfg.filePicker.enable ''
          o.window("com.thisisgm.flea.picker", { tag = "+floating-window" })
        '';
      })
    ]
  );
}
