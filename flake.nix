{
  inputs.flakes.url = "github:deemp/flakes";

  outputs =
    inputs:
    let
      inputs_ =
        let flakes = inputs.flakes.flakes; in
        {
          inherit (flakes.source-flake) flake-utils nixpkgs formatter;
          inherit (flakes) devshell drv-tools;
          inherit flakes;
        };

      outputs = outputs_ { } // { inputs = inputs_; outputs = outputs_; };

      outputs_ =
        inputs__:
        let inputs = inputs_ // inputs__; in

        inputs.flake-utils.lib.eachDefaultSystem
          (system:
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
          })
        // {
          inherit (inputs) formatter;
        };
    in
    outputs;

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
