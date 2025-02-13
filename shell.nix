let
  sources = import ./npins;

  pkgs = import sources.nixpkgs { };

  inherit (pkgs) lib;

  ghc-nix = import "${sources."ghc.nix"}/shell.nix" {
    withIde = true;
  };

  ghc-rts =
    (builtins.getFlake "git+file:ghc-rts?ref=main").devShells.${builtins.currentSystem}.default;
in
ghc-nix.overrideAttrs (
  old:
  (lib.attrsets.genAttrs [
    "buildInputs"
    "nativeBuildInputs"
    "propagatedBuildInputs"
    "propagatedNativeBuildInputs"
    "shellHook"
  ] (k: (old.${k} or [ ]) ++ ghc-rts.${k}))
  // {
    shellHook = old.shellHook + ghc-rts.shellHook;
  }
)
