let
  sources = import ./npins;

  nixpkgs =
    let
      flake-lock = builtins.fromJSON (builtins.readFile rust/flake.lock);

      nixpkgs-locked = flake-lock.nodes.nixpkgs.locked;
    in
    builtins.fetchGit {
      url = "https://github.com/${nixpkgs-locked.owner}/${nixpkgs-locked.repo}";
      rev = nixpkgs-locked.rev;
      shallow = true;
    };

  pkgs = import nixpkgs { };

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
