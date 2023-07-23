{
  inputs.flakes.url = "github:deemp/flakes";
  outputs = inputs:
    let flakes = inputs.flakes; in
    flakes.makeFlake {
      inputs = {
        inherit (flakes.all) nixpkgs formatter devshell drv-tools;
        inherit flakes;
      };
      perSystem = { inputs, system }:
        let
          pkgs = inputs.nixpkgs.legacyPackages.${system};
          inherit (inputs.devshell.lib.${system}) mkCommands mkRunCommands mkRunCommandsDir mkShell;

          hcl = import ./nix-files/hcl.nix;
          tfTools = import ./nix-files/tf-tools.nix { inherit pkgs system; inherit (inputs) drv-tools; };
          tests = (import ./nix-files/tests.nix { inherit pkgs system; inherit (inputs) drv-tools; });

          packages = tests // tfTools.packages;
          devShells.default = mkShell {
            packages = [ ];
            commands =
              mkRunCommands "test" tests
              ++ mkRunCommands "tf-tools" tfTools.packages
              ++ [{ name = "nix develop nix-dev/"; help = "Run project devshell"; }];
          };
        in
        {
          inherit (tfTools) lib;
          inherit packages hcl devShells;
          formatter = inputs.formatter.${system};
        };
    };

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
