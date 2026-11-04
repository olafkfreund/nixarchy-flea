{
  description = "Flea (thisisgm/flea) for NixOS and Home Manager: upstream release binaries in an FHS runtime";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Used only by `checks`.
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      ...
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      inherit (nixpkgs) lib;
      flea = pkgs.callPackage ./nix/package.nix { };
      # Every optional dependency on, except dropbox: dropbox-cli needs the unfree dropbox (allowUnfree).
      allOptionals = lib.genAttrs (builtins.attrNames flea.optionalPackages) (n: n != "dropbox");

      # Eval-only checks: the assertion runs while the check derivation is evaluated, nothing big is built.
      evalCheck =
        name: cond: msg:
        assert lib.assertMsg cond "${name}: ${msg}";
        pkgs.runCommand name { } "touch $out";

      nixosSys = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          self.nixosModules.flea
          {
            programs.flea.enable = true;
            programs.flea.optionalDependencies = allOptionals;
            boot.isContainer = true;
            system.stateVersion = "26.05";
          }
        ];
      };

      hmUser = {
        home = {
          username = "t";
          homeDirectory = "/home/t";
          stateVersion = "26.05";
        };
      };
      hmConf = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          self.homeManagerModules.flea
          hmUser
          {
            programs.flea = {
              enable = true;
              defaultFileManager.enable = true;
              filePicker.enable = true;
              hyprland.bindings.enable = true;
              htmlPreview = false;
              optionalDependencies = allOptionals;
              extraPackages = [ pkgs.hello ];
              omarchyPath = "/opt/omarchy";
            };
          }
        ];
      };

      hmUnderNixos =
        hmExtra:
        nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            self.nixosModules.flea
            home-manager.nixosModules.home-manager
            {
              programs.flea.enable = true;
              boot.isContainer = true;
              system.stateVersion = "26.05";
              users.users.t.isNormalUser = true;
              home-manager.users.t = {
                imports = [
                  self.homeManagerModules.flea
                  hmUser
                  hmExtra
                ];
                programs.flea.enable = true;
              };
            }
          ];
        };
      failedAssertions = sys: lib.filter (a: !a.assertion) sys.config.assertions;
    in
    {
      packages.${system} = {
        inherit flea;
        flea-bin = flea.unwrapped;
        default = flea;
      };

      overlays.default = final: _prev: {
        flea = final.callPackage ./nix/package.nix { };
        flea-bin = (final.callPackage ./nix/package.nix { }).unwrapped;
      };

      nixosModules = {
        flea = ./nix/nixos-module.nix;
        default = self.nixosModules.flea;
      };
      homeManagerModules = {
        flea = ./nix/hm-module.nix;
        default = self.homeManagerModules.flea;
      };

      formatter.${system} = pkgs.nixfmt;

      checks.${system} = {
        flea-bin-layout = pkgs.runCommand "flea-bin-layout" { b = flea.unwrapped; } ''
          set -eu
          for f in bin/flea bin/flea-gui share/flea/ui/boot/shell.qml share/flea/shelf/manifest.json \
                   share/applications/com.thisisgm.flea.desktop share/xdg-desktop-portal/portals/flea.portal; do
            test -e "$b/$f" || { echo "missing $f" >&2; exit 1; }
          done
          test "$(ls "$b/lib/flea" | wc -l)" -eq 5 || { echo "expected 5 helpers" >&2; exit 1; }
          grep -qF '"version": "${flea.unwrapped.version}-1",' "$b/share/flea/shelf/manifest.json"
          test ! -e "$b/share/libalpm"
          touch $out
        '';

        flea-services = pkgs.runCommand "flea-services" { f = flea; } ''
          set -eu
          n=0
          for s in "$f"/share/dbus-1/services/*.service; do
            grep -q '^Exec=${flea.fhs}/bin/flea-fhs /usr/lib/flea/' "$s" || { echo "bad Exec in $s" >&2; exit 1; }
            n=$((n + 1))
          done
          test "$n" -eq 2
          touch $out
        '';

        fhs-rootfs = pkgs.runCommand "fhs-rootfs" { r = flea.fhs.fhsenv; } ''
          set -eu
          for f in "$r"/usr/share/thumbnailers/*.thumbnailer; do
            test ! -L "$f" || { echo "$f is still a symlink" >&2; exit 1; }
            if grep -qE '^(Try)?Exec=/nix/store/' "$f"; then echo "$f still names a store path" >&2; exit 1; fi
            for p in $(sed -nE 's#^(Try)?Exec=(/usr/bin/[^ ]+).*#\2#p' "$f"); do
              test -f "$r$p" -a ! -L "$r$p" || { echo "$p is not a real file" >&2; exit 1; }
            done
          done
          test -x "$r/usr/bin/qml6"
          test -d "$r/usr/lib64/qt-6/qml/QtWebEngine"
          touch $out
        '';

        nixos-module =
          let
            c = nixosSys.config;
          in
          evalCheck "nixos-module" (
            builtins.elem c.programs.flea.package c.xdg.portal.extraPortals
            && c.services.gvfs.enable
            && c.services.udisks2.enable
            && builtins.elem c.programs.flea.package c.environment.systemPackages
          ) "portal, gvfs, udisks2 or systemPackages missing";

        hm-module =
          let
            c = hmConf.config;
            binds = c.xdg.configFile."hypr/flea-binds.lua".text;
            portals = c.xdg.configFile."xdg-desktop-portal/hyprland-portals.conf".text;
            fm1 = c.xdg.dataFile."dbus-1/services/org.freedesktop.FileManager1.service".text;
          in
          evalCheck "hm-module" (
            lib.hasInfix ''o.bind("SUPER + SHIFT + F"'' binds
            && lib.hasInfix ''o.window("com.thisisgm.flea.picker"'' binds
            && lib.hasInfix "FileChooser=flea;gtk" portals
            && !(lib.hasInfix "default=" portals)
            && lib.hasInfix (builtins.unsafeDiscardStringContext "Exec=${c.programs.flea.package.fhs}/bin/flea-fhs /usr/lib/flea/flea-filemanager1") fm1
            && c.xdg.mimeApps.defaultApplications."inode/directory" == [ "com.thisisgm.flea.desktop" ]
            && builtins.elem c.programs.flea.package c.home.packages
          ) "generated files or package wrong";

        hm-under-nixos =
          let
            good = hmUnderNixos { };
            bad = hmUnderNixos { programs.flea.htmlPreview = false; };
          in
          evalCheck "hm-under-nixos" (
            good.config.home-manager.users.t.programs.flea.package == good.config.programs.flea.package
            && failedAssertions good == [ ]
            && failedAssertions bad != [ ]
          ) "HM must reuse the NixOS package, and reject HM-side dependency options";
      };
    };
}
