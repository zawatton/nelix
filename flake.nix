{
  description = "nelix development environment and local checks";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      checks = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          check = pkgs.stdenvNoCC.mkDerivation {
            pname = "nelix-check";
            version = "0.1.0";
            src = self;

            nativeBuildInputs = [
              pkgs.emacs-nox
              pkgs.gnumake
              pkgs.git
              pkgs.python3
              pkgs.perl
            ];

            # The build sandbox has no /usr/bin/env, which the gate scripts'
            # `#!/usr/bin/env bash' shebangs need; point them at the store bash.
            postPatch = ''
              patchShebangs bin packaging tools
            '';

            dontConfigure = true;
            dontBuild = true;
            doCheck = true;

            checkPhase = ''
              runHook preCheck
              export HOME="$TMPDIR/home"
              mkdir -p "$HOME"
              # -k: one failed gate must not hide the gates after it; a failed nix build
              # only shows its log, so report every failure in a single run.
              make -k check
              runHook postCheck
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p "$out"
              touch "$out/check-passed"
              runHook postInstall
            '';
          };
        });

      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.curl
              pkgs.emacs-nox
              pkgs.git
              pkgs.gnumake
              pkgs.nix
              pkgs.ripgrep
            ];

            NIX_CONFIG = "experimental-features = nix-command flakes";
          };
        });

      formatter = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        pkgs.nixpkgs-fmt);
    };
}
