{
  inputs = { };
  outputs =
    inputs:
    let
      inputs_ =
        let flakes = (import ../.).outputs.inputs.flakes; in
        {
          inherit (flakes.source-flake) flake-utils nixpkgs;
          inherit (flakes) codium devshell flakes-tools workflows;
        };

      outputs = outputs_ { } // { inputs = inputs_; outputs = outputs_; };

      outputs_ =
        inputs__:
        let inputs = inputs_ // inputs__; in
        inputs.flake-utils.lib.eachDefaultSystem
          (system:
          let
            pkgs = inputs.nixpkgs.legacyPackages.${system};
            inherit (inputs.codium.lib.${system}) mkCodium writeSettingsJSON;
            inherit (inputs.codium.lib.${system}) extensionsCommon settingsCommonNix extensions;
            inherit (inputs.devshell.lib.${system}) mkCommands mkRunCommands mkRunCommandsDir mkShell;
            inherit (inputs.workflows.lib.${system}) writeWorkflow nixCI;
            inherit (inputs.flakes-tools.lib.${system}) mkFlakesTools;

            nix-dev = "nix-dev/";

            packages = {
              # --- IDE ---

              # This part can be removed if you don't use `VSCodium`
              # We compose `VSCodium` with dev tools
              # This is to let `VSCodium` run on its own, outside of a devshell
              codium = mkCodium {
                # We use the common extensions
                extensions = extensionsCommon // {
                  # Next, we include the extensions from the pre-defined attrset
                  inherit (extensions) terraform;
                };
              };

              # a script to write `.vscode/settings.json`
              writeSettings = writeSettingsJSON settingsCommonNix;

              # --- Flakes ---

              # Scripts that can be used in CI
              inherit (mkFlakesTools { dirs = [ "." nix-dev ]; root = ./.; }) updateLocks saveFlakes format;

              # --- GH Actions

              # A script to write GitHub Actions workflow file into `.github/ci.yaml`
              writeWorkflows = writeWorkflow "ci" (nixCI {
                jobArgs = {
                  dir = nix-dev;
                  cacheNixArgs = {
                    linuxGCEnabled = true;
                    linuxMaxStoreSize = 5000000000;
                    macosGCEnabled = true;
                    macosMaxStoreSize = 5000000000;
                  };
                };
              });
            };

            tools = [ pkgs.terraform pkgs.terraform-ls ];

            devShells.default = mkShell {
              packages = tools;
              commands =
                mkCommands "tools" tools
                ++ mkRunCommandsDir nix-dev "ide" { "codium ." = packages.codium; inherit (packages) writeSettings; }
                ++ mkRunCommandsDir nix-dev "infra" { inherit (packages) updateLocks saveFlakes format writeWorkflows; }
              ;
            };
          in
          {
            inherit packages devShells;
          });
    in
    outputs;

  nixConfig = {
    extra-trusted-substituters = [
      "https://nix-community.cachix.org"
      "https://cache.iog.io"
      "https://deemp.cachix.org"
    ];
    extra-trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
      "deemp.cachix.org-1:9shDxyR2ANqEPQEEYDL/xIOnoPwxHot21L5fiZnFL18="
    ];
  };
}
