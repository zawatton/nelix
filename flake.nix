{
  description = "anvil-pkg development environment and local checks";

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
            pname = "anvil-pkg-check";
            version = "0.1.0";
            src = self;

            nativeBuildInputs = [
              pkgs.emacs-nox
              pkgs.gnumake
              pkgs.git
            ];

            dontConfigure = true;
            dontBuild = true;
            doCheck = true;

            checkPhase = ''
              runHook preCheck
              export HOME="$TMPDIR/home"
              mkdir -p "$HOME"
              make check
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
