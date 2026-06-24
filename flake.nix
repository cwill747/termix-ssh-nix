{
  description = "Nix flake for Termix-SSH: build the frontend & backend and run it as a NixOS service (with guacd, no Docker)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Tracks the latest commit of Termix's main branch. Bump with:
    #   nix flake update termix-src
    termix-src = {
      url = "github:Termix-SSH/Termix";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      termix-src,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f (
            import nixpkgs {
              inherit system;
              overlays = [ self.overlays.default ];
            }
          )
        );
    in
    {
      overlays.default = final: _prev: {
        termix = final.callPackage ./pkgs/termix.nix { src = termix-src; };
      };

      packages = forAllSystems (pkgs: {
        default = pkgs.termix;
        termix = pkgs.termix;
        # Static SPA assets (the `frontend` output of the termix derivation).
        termix-frontend = pkgs.termix.frontend;
        # Runnable backend bundle (dist/backend + node_modules + launcher).
        termix-backend = pkgs.termix;
      });

      nixosModules.default = import ./modules/termix.nix;
      nixosModules.termix = self.nixosModules.default;

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.nodejs_24
            pkgs.prefetch-npm-deps
          ];
        };
      });

      checks =
        forAllSystems (pkgs: {
          build = pkgs.termix;
        })
        // {
          # NixOS VM integration test (Linux only).
          x86_64-linux.vm =
            (import "${nixpkgs}/nixos/lib/testing-python.nix" {
              system = "x86_64-linux";
            }).simpleTest
              (import ./tests/vm.nix { inherit self nixpkgs; });
        };

      formatter = forAllSystems (pkgs: pkgs.nixfmt-rfc-style);
    };
}
