{
  description = "A library for interacting with databases in Zig";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    odbc-drivers = {
      url = "github:rupurt/odbc-drivers-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    flake-utils,
    nixpkgs,
    zig-overlay,
    odbc-drivers,
    ...
  }: let
    systems = ["x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin"];
    outputs = flake-utils.lib.eachSystem systems (system: let
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          zig-overlay.overlays.default
          odbc-drivers.overlay
        ];
      };
      shellBuildInputs = [
        pkgs.pkg-config
        pkgs.odbc-driver-pkgs.db2-odbc-driver
        pkgs.odbc-driver-pkgs.postgres-odbc-driver
        pkgs.unixODBC
      ];
      shellPackages =
        []
        ++ pkgs.lib.optionals (pkgs.stdenv.isLinux) [
          pkgs.strace
        ];
    in {
      # packages exported by the flake
      packages = {};

      # nix run
      apps = {
      };

      # nix fmt
      formatter = pkgs.alejandra;

      # nix develop -c $SHELL
      devShells = {
        default = pkgs.mkShell.override {stdenv = pkgs.clangStdenv;} {
          name = "zig 0.11.0 dev shell";

          buildInputs =
            shellBuildInputs
            ++ [
              pkgs.zigpkgs."0.11.0"
            ];

          packages = shellPackages;
        };

        master = pkgs.mkShell.override {stdenv = pkgs.clangStdenv;} {
          name = "zig 0.12.0-dev dev shell";

          buildInputs =
            shellBuildInputs
            ++ [
              pkgs.zigpkgs.master
            ];

          packages = shellPackages;
        };
      };
    });
  in
    outputs;
}
