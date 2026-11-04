{
  lib,
  stdenvNoCC,
  fetchurl,
}:

let
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
in
flea-bin
