let
  sources = import nix/npins;

  nixpkgs =
    let
      flake-lock = builtins.fromJSON (builtins.readFile rust/flake.lock);

      locked = flake-lock.nodes.nixpkgs.locked;

      nixpkgs-ref = "github:${locked.owner}/${locked.repo}?rev=${locked.rev}";
    in
    builtins.getFlake nixpkgs-ref;

  pkgs = nixpkgs.legacyPackages.${builtins.currentSystem};

  inherit (pkgs) lib;

  ghc-nix = import "${sources."ghc.nix"}/shell.nix" {
    # inherit nixpkgs; # BROKEN: system & libobjc
    version = "9.15";
    hadrianCabal = hadrian/hadrian.cabal;
    useClang = true;
    withLlvm = true;
    withDocs = false;
    withIde = true;
    withZstd = false; # TODO: Investigate linking errors.
  };

  flake-compat = import sources.flake-compat;

  ghc-rust = (flake-compat { src = ./rust; }).shellNix;

  ghc-rust-shell = ghc-rust.devShells.${builtins.currentSystem}.default;

  crane = ghc-rust-shell.crane;
in
ghc-nix.overrideAttrs (old: {
  nativeBuildInputs = [
    crane.cargo
    crane.rustc
    crane.rustfmt
  ]
  ++ old.nativeBuildInputs;

  env = old.env // {
    CONFIG_ARGS = lib.concatStringsSep " " old.CONFIGURE_ARGS;

    NPINS_DIRECTORY = "nix/npins";
  };

  passthru = {
    inherit ghc-rust-shell pkgs;
  };
})
