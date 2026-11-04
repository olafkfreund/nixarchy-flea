{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      flea = pkgs.callPackage ./nix/package.nix { };
    in
    {
      packages.x86_64-linux = {
        inherit flea;
        flea-bin = flea.unwrapped;
        default = flea;
      };
    };
}
