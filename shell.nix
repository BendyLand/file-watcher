let
  nixpkgs = fetchTarball "https://github.com/NixOS/nixpkgs/archive/nixos-25.11.tar.gz";
  pkgs = import nixpkgs {};
in
pkgs.mkShell {
  buildInputs = [
    pkgs.zig_0_15
    pkgs.zls_0_15
    pkgs.pkg-config
  ];
}

