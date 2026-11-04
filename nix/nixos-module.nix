{
  config,
  lib,
  pkgs,
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
  enabledOptionals = lib.attrValues (
    lib.filterAttrs (name: _: cfg.optionalDependencies.${name}) base.optionalPackages
  );
in
{
  options.programs.flea = {
    enable = lib.mkEnableOption ''
      Flea, the Omarchy file manager. This registers Flea system-wide: the package, its
      portal file chooser backend, its D-Bus services, and the gvfs/udisks2/usbmuxd services
      it relies on. It does not make Flea the default for anything; use the Home Manager
      module for that. Note that the shipped `com.thisisgm.flea.FileManager1.service`
      claims `org.freedesktop.FileManager1` system-wide, as Arch's package does. When
      several file managers claim it, the user-level file written by Home Manager's
      `programs.flea.defaultFileManager` decides which one wins
    '';

    htmlPreview = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Include qt6-webengine for HTML previews (large closure).";
    };

    optionalDependencies = lib.mapAttrs (
      name: _:
      lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Add the optional dependency `${name}` to Flea's FHS environment.";
      }
    ) base.optionalPackages;

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Extra packages to put in Flea's FHS environment (e.g. more thumbnailers).";
    };

    omarchyPath = lib.mkOption {
      type = lib.types.str;
      default = "/run/current-system/sw/share/omarchy";
      description = ''
        Where Omarchy's data tree (shell Commons/Ui, default/i18n/locales.json) lives on this
        host. It appears as /usr/share/omarchy inside Flea's FHS environment.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = base.override {
        withHtmlPreview = cfg.htmlPreview;
        extraPackages = enabledOptionals ++ cfg.extraPackages;
        inherit (cfg) omarchyPath;
      };
      defaultText = lib.literalExpression ''
        pkgs.flea.override {
          withHtmlPreview = config.programs.flea.htmlPreview;
          extraPackages = <enabled optionalDependencies> ++ config.programs.flea.extraPackages;
          inherit (config.programs.flea) omarchyPath;
        }
      '';
      description = "The Flea package to install. The default applies the options above.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
    xdg.portal.enable = lib.mkDefault true;
    xdg.portal.extraPortals = [ cfg.package ];
    services.dbus.packages = [ cfg.package ];
    services.gvfs.enable = lib.mkDefault true;
    services.udisks2.enable = lib.mkDefault true;
    services.usbmuxd.enable = lib.mkDefault true;
    programs.dconf.enable = lib.mkDefault true;
  };
}
