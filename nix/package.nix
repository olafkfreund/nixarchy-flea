{
  lib,
  stdenv,
  rustPlatform,
  fetchFromGitHub,
  pkg-config,
  fontconfig,
  freetype,
  glib,
  gdk-pixbuf,
  libheif,
  libxcb,
  libxkbcommon,
  wayland,
  vulkan-loader,
  libGL,
  poppler,
  mpv-unwrapped,
}:

let
  flea-unwrapped = rustPlatform.buildRustPackage rec {
    pname = "flea";
    version = "0.4.0";

    src = fetchFromGitHub {
      owner = "thisisgm";
      repo = "flea";
      tag = "v${version}";
      hash = "sha256-zzGFgcpA2D3AwGKjt8H1cz9mwi/i/iqBNB4xLl35bZg=";
    };

    cargoLock = {
      lockFile = "${src}/Cargo.lock";
      outputHashes."gpui-pre-0.3.9" = "sha256-dG429jiK+hmafEIHSQRuL58tzS6XvbqCoTxIJuEe0MI=";
    };

    patches = [
      ./shelf-mode.patch
      ./nix-store-jail.patch
    ];

    cargoBuildFlags = [
      "--workspace"
      "--bins"
    ];
    doCheck = false;

    nativeBuildInputs = [ pkg-config ];
    buildInputs = [
      fontconfig
      freetype
      glib
      gdk-pixbuf
      libheif
      libxcb
      libxkbcommon
      wayland
      vulkan-loader
      libGL
      poppler
      mpv-unwrapped
    ];

    installPhase = ''
      runHook preInstall
      mkdir -p target/release
      cp target/${stdenv.hostPlatform.rust.cargoShortTarget}/release/{flea,flea-gui} target/release/
      make DESTDIR=$out VERSION=${version}-1 install
      mv $out/usr/* $out/ && rmdir $out/usr
      rm -r $out/share/libalpm
      runHook postInstall
    '';

    postFixup = ''
      for b in $out/bin/flea $out/bin/flea-gui; do
        patchelf --add-rpath ${
          lib.makeLibraryPath [
            vulkan-loader
            wayland
            libGL
            poppler
            mpv-unwrapped
          ]
        } $b
      done
    '';

    # Helper shebangs (/usr/bin/python3, /usr/bin/expect) resolve inside the FHS env.
    dontPatchShebangs = true;
    # The four ui/{,boot/}{Commons,Ui} links are meant to dangle.
    dontCheckForBrokenSymlinks = true;

    meta = {
      description = "File manager for Omarchy";
      homepage = "https://github.com/thisisgm/flea";
      license = lib.licenses.mit;
      mainProgram = "flea";
      platforms = [ "x86_64-linux" ];
    };
  };
in
flea-unwrapped
