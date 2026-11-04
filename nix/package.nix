{
  lib,
  stdenvNoCC,
  fetchurl,
  runCommand,
  writeShellScript,
  writeShellScriptBin,
  buildFHSEnv,
  runtimeShell,
  bubblewrap,
  glibc,
  python3,
  gobject-introspection,
  glib,
  expect,
  bat,
  util-linux,
  gvfs,
  jq,
  quickjs-ng,
  ripgrep,
  shared-mime-info,
  udisks,
  usbmuxd,
  wl-clipboard,
  xdg-terminal-exec,
  xdg-utils,
  poppler,
  poppler-utils,
  mpv-unwrapped,
  vulkan-loader,
  libGL,
  wayland,
  diffutils,
  git,
  quickshell,
  fontconfig,
  freetype,
  gdk-pixbuf,
  libheif,
  libxcb,
  libxkbcommon,
  hicolor-icon-theme,
  qt6,
  _7zz,
  libarchive,
  ffmpeg,
  ffmpegthumbnailer,
  imagemagick,
  libreoffice,
  tailscale,
  zoxide,
  dropbox-cli,
  withHtmlPreview ? true,
  extraPackages ? [ ],
  omarchyPath ? "/run/current-system/sw/share/omarchy",
}:

let
  omarchyLink =
    runCommand "flea-omarchy-link" { }
      "mkdir -p $out/share; ln -s ${omarchyPath} $out/share/omarchy";
  bwrapShim = writeShellScriptBin "bwrap" ''
    exec ${bubblewrap}/bin/bwrap --ro-bind /nix/store /nix/store --ro-bind ${glibc}/etc ${glibc}/etc "$@"
  '';
  sevenzip7z = runCommand "7z-link" { } "mkdir -p $out/bin; ln -s ${_7zz}/bin/7zz $out/bin/7z";
  optionalPackages = {
    sevenzip = sevenzip7z;
    inherit
      libarchive
      ffmpeg
      ffmpegthumbnailer
      imagemagick
      libreoffice
      tailscale
      zoxide
      ;
    dropbox = dropbox-cli;
  };

  flea-bin = stdenvNoCC.mkDerivation rec {
    pname = "flea-bin";
    version = "0.4.0";

    src = fetchurl {
      url = "https://github.com/thisisgm/flea/releases/download/v${version}/flea-v${version}-linux-x86_64.tar.gz";
      hash = "sha256-76RmxJFiKMrW43T58zshbvI29TUVdY/dxQLGly9cUNc=";
    };

    dontConfigure = true;
    dontBuild = true;
    # Upstream's binaries run unmodified inside the FHS env.
    dontPatchELF = true;
    dontStrip = true;
    # Helper shebangs (/usr/bin/python3, /usr/bin/expect) resolve inside the FHS env.
    dontPatchShebangs = true;
    # The four ui/{,boot/}{Commons,Ui} links point into /usr/share/omarchy and dangle here.
    dontCheckForBrokenSymlinks = true;

    # Mirrors upstream packaging/flea-bin/PKGBUILD package(), with $out as /usr; the pacman hook is skipped.
    installPhase = ''
      runHook preInstall

      install -Dm755 flea "$out/bin/flea"
      install -Dm755 flea-gui "$out/bin/flea-gui"
      install -Dm755 tools/flea-gio-auth "$out/lib/flea/flea-gio-auth"
      install -Dm755 tools/flea-udisks "$out/lib/flea/flea-udisks"
      install -Dm755 tools/flea-portal "$out/lib/flea/flea-portal"
      install -Dm644 packaging/flea.portal -t "$out/share/xdg-desktop-portal/portals"
      install -Dm644 packaging/org.freedesktop.impl.portal.desktop.flea.service -t "$out/share/dbus-1/services"
      install -Dm755 tools/flea-filemanager1 "$out/lib/flea/flea-filemanager1"
      install -Dm644 packaging/com.thisisgm.flea.FileManager1.service -t "$out/share/dbus-1/services"
      install -Dm755 tools/flea-mpris "$out/lib/flea/flea-mpris"
      install -Dm644 packaging/com.thisisgm.flea.desktop -t "$out/share/applications"
      install -Dm644 packaging/com.thisisgm.flea.svg -t "$out/share/icons/hicolor/scalable/apps"
      install -Dm644 LICENSE THIRD-PARTY-LICENSES.txt -t "$out/share/licenses/flea"

      install -Dm644 ui/qmldir ui/*.qml ui/*.js -t "$out/share/flea/ui"
      install -Dm644 ui/js/*.js ui/js/*.mjs -t "$out/share/flea/ui/js"
      install -Dm644 ui/vendor/*.mjs -t "$out/share/flea/ui/vendor"
      install -Dm644 ui/vendor/LICENSES/* -t "$out/share/flea/ui/vendor/LICENSES"
      install -Dm644 ui/boot/shell.qml ui/boot/picker.qml ui/boot/fleatab.qml ui/boot/tabtearoff.qml -t "$out/share/flea/ui/boot"
      install -Dm644 shelf/manifest.json shelf/README.md shelf/*.qml shelf/*.js -t "$out/share/flea/shelf"
      for catalog in i18n/*/flea.json; do install -Dm644 "$catalog" "$out/share/flea/$catalog"; done

      sed -i "s/^  \"version\": \"[^\"]*\",\$/  \"version\": \"${version}-1\",/" "$out/share/flea/shelf/manifest.json"
      grep -qF "  \"version\": \"${version}-1\"," "$out/share/flea/shelf/manifest.json" \
        || { echo "flea-bin: shelf/manifest.json does not carry the version ${version}-1" >&2; exit 1; }

      ln -s /usr/share/omarchy/shell/Commons "$out/share/flea/ui/Commons"
      ln -s /usr/share/omarchy/shell/Ui "$out/share/flea/ui/Ui"
      ln -s /usr/share/omarchy/shell/Commons "$out/share/flea/ui/boot/Commons"
      ln -s /usr/share/omarchy/shell/Ui "$out/share/flea/ui/boot/Ui"

      runHook postInstall
    '';

    meta = {
      description = "File manager for Omarchy (upstream release binaries)";
      homepage = "https://github.com/thisisgm/flea";
      license = with lib.licenses; [
        asl20
        bsd2
        bsd3
        cc0
        isc
        mit
        mpl20
        unicode-30
        zlib
      ];
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
      mainProgram = "flea";
      platforms = [ "x86_64-linux" ];
    };
  };

  flea-fhs = buildFHSEnv {
    name = "flea-fhs";
    runScript = writeShellScript "flea-fhs-exec" ''exec "$@"'';
    dieWithParent = false;
    profile = ''
      export GI_TYPELIB_PATH=/usr/lib/girepository-1.0 GIO_EXTRA_MODULES=/usr/lib/gio/modules
      chmod -R u+w "''${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/io.github.thisisgm.flea-shelf" 2>/dev/null || true
    '';
    extraBuildCommands = ''
      test -d "$out/usr/bin" -a ! -L "$out/usr/bin" || { echo "flea-fhs: usr/bin is not a real directory" >&2; exit 1; }
      tools="bat soffice libreoffice"
      for f in "$out"/usr/share/thumbnailers/*.thumbnailer; do
        [ -e "$f" ] || continue
        tools="$tools $(sed -n 's/^\(Try\)\?Exec=\([^ ]*\).*/\2/p' "$f" | xargs -r -n1 basename)"
      done
      for t in $(printf '%s\n' $tools | sort -u); do
        p="$out/usr/bin/$t"
        [ -L "$p" ] || continue
        real=$(readlink -f "$p"); rm "$p"; cp "$real" "$p"
        echo "flea-fhs: real file $t"
      done
    '';
    targetPkgs =
      p:
      [
        flea-bin
        bwrapShim
        omarchyLink
        (python3.withPackages (ps: [ ps.pygobject3 ]))
        gobject-introspection
        glib
        expect
        bat
        util-linux
        gvfs
        jq
        quickjs-ng
        ripgrep
        shared-mime-info
        udisks
        usbmuxd
        wl-clipboard
        xdg-terminal-exec
        xdg-utils
        poppler
        poppler-utils
        mpv-unwrapped
        vulkan-loader
        libGL
        wayland
        diffutils
        git
        quickshell
        fontconfig
        freetype
        gdk-pixbuf
        libheif
        libxcb
        libxkbcommon
        hicolor-icon-theme
      ]
      ++ lib.optionals withHtmlPreview [
        qt6.qtdeclarative
        qt6.qtwebengine
      ]
      ++ extraPackages;
  };

  flea =
    runCommand "flea-${flea-bin.version}"
      {
        passthru = {
          unwrapped = flea-bin;
          fhs = flea-fhs;
          inherit optionalPackages;
        };
        meta = flea-bin.meta // {
          description = "File manager for Omarchy (FHS runtime)";
        };
      }
      ''
        mkdir -p "$out/bin" "$out/share/xdg-desktop-portal/portals" "$out/share/dbus-1/services"
        cat > "$out/bin/flea" <<'EOF'
        #!${runtimeShell}
        exec ${flea-fhs}/bin/flea-fhs /usr/bin/flea "$@"
        EOF
        cat > "$out/bin/flea-gui" <<'EOF'
        #!${runtimeShell}
        exec ${flea-fhs}/bin/flea-fhs /usr/bin/flea-gui "$@"
        EOF
        chmod +x "$out/bin/flea" "$out/bin/flea-gui"
        ln -s ${flea-bin}/share/applications "$out/share/applications"
        ln -s ${flea-bin}/share/icons "$out/share/icons"
        ln -s ${flea-bin}/share/licenses "$out/share/licenses"
        cp ${flea-bin}/share/xdg-desktop-portal/portals/flea.portal "$out/share/xdg-desktop-portal/portals/"
        for service in ${flea-bin}/share/dbus-1/services/*.service; do
          sed 's|^Exec=/usr/lib/flea/|Exec=${flea-fhs}/bin/flea-fhs /usr/lib/flea/|' "$service" > "$out/share/dbus-1/services/''${service##*/}"
        done
      '';
in
flea
