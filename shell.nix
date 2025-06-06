let
  sources = import ./npins;

  pkgs = import sources.nixpkgs { };

  inherit (pkgs) lib;

  ghc-nix = import "${sources."ghc.nix"}/shell.nix" {
    withIde = true;
  };

  flake-compat = import sources.flake-compat;

  ghc-rts = (flake-compat { src = ./rust; }).shellNix;

  ghc-rts-shell = ghc-rts.devShells.${builtins.currentSystem}.default;
in
ghc-nix.overrideAttrs (
  old:
  (lib.attrsets.genAttrs [
    "buildInputs"
    "nativeBuildInputs"
    "propagatedBuildInputs"
    "propagatedNativeBuildInputs"
  ] (k: (old.${k} or [ ]) ++ ghc-rts-shell.${k}))
  // {
    CONFIG_ARGS = old.CONFIGURE_ARGS;
  }
)
