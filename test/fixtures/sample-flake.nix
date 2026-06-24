{
  description = "Doc 33 M3 test fixture: a minimal flake with emacsPackages.melpaBuild blocks.";
  outputs = { self }: {
    packages.x86_64-linux = {
      s = pkgs.emacsPackages.melpaBuild {
        pname = "s";
        version = "0.0.0";
        src = pkgs.fetchFromGitHub {
          owner = "magnars";
          repo = "s.el";
          rev = "b4b8c03fcef316a27f75633fe4bb990aeff6e705";
          sha256 = "sha256-vLjIvhsyn1gsk1IMM0clpRE6sExNVaXcKr3XffnPXWw=";
        };
      };
      ace-window = pkgs.emacsPackages.melpaBuild {
        pname = "ace-window";
        version = "0.0.0";
        src = pkgs.fetchFromGitHub {
          owner = "abo-abo";
          repo = "ace-window";
          rev = "77115afc1b0b9f633084cf7479c767988106c196";
          sha256 = "sha256-testaceplaceholderhashvalueforfixtureonly=";
        };
        packageRequires = with pkgs.emacsPackages; [ avy ];
      };
    };
  };
}
