{
  inputs = {
    nixpkgs_.url = github:deemp/flakes?dir=source-flake/nixpkgs;
    nixpkgs.follows = "nixpkgs_/nixpkgs";
    flake-utils_.url = github:deemp/flakes?dir=source-flake/flake-utils;
    flake-utils.follows = "flake-utils_/flake-utils";
    flakes-tools.url = github:deemp/flakes?dir=flakes-tools;
    drv-tools.url = github:deemp/flakes?dir=drv-tools;
    devshell.url = github:deemp/flakes?dir=devshell;
  };
  outputs = inputs: inputs.flake-utils.lib.eachDefaultSystem
    (system:
      let
        pkgs = inputs.nixpkgs.legacyPackages.${system};
        inherit (inputs.devshell.functions.${system}) mkCommands mkRunCommands mkRunCommandsDir mkShell;

        hcl = import ./nix-files/hcl.nix;
        tfTools = import ./nix-files/tf-tools.nix { inherit pkgs system; inherit (inputs) drv-tools; };
        tests = (import ./nix-files/tests.nix { inherit pkgs system; inherit (inputs) drv-tools; });

        packages = tests // tfTools.packages;
        devShells.default = mkShell {
          packages = [ ];
          commands =
            mkRunCommands "test" tests
            ++ mkRunCommands "tf-tools" tfTools.packages;
        };
      in
      {
        inherit (tfTools) functions;
        inherit packages hcl devShells;
      });

  nixConfig = {
    extra-trusted-substituters = [
      https://nix-community.cachix.org
      https://hydra.iohk.io
      https://deemp.cachix.org
    ];
    extra-trusted-public-keys = [
      nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=
      hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ=
      deemp.cachix.org-1:9shDxyR2ANqEPQEEYDL/xIOnoPwxHot21L5fiZnFL18=
    ];
  };
}
