{
  inputs = {
    nixpkgs_.url = "github:deemp/flakes?dir=source-flake/nixpkgs";
    nixpkgs.follows = "nixpkgs_/nixpkgs";
    codium.url = "github:deemp/flakes?dir=codium";
    flake-utils_.url = "github:deemp/flakes?dir=source-flake/flake-utils";
    flake-utils.follows = "flake-utils_/flake-utils";
    vscode-extensions_.url = "github:deemp/flakes?dir=source-flake/nix-vscode-extensions";
    vscode-extensions.follows = "vscode-extensions_/vscode-extensions";
    devshell.url = "github:deemp/flakes?dir=devshell";
    flakes-tools.url = "github:deemp/flakes?dir=flakes-tools";
    workflows.url = "github:deemp/flakes?dir=workflows";
  };
  outputs = inputs: inputs.flake-utils.lib.eachDefaultSystem
    (system:
      let
        pkgs = inputs.nixpkgs.legacyPackages.${system};
        inherit (inputs.codium.functions.${system}) mkCodium writeSettingsJSON;
        inherit (inputs.codium.configs.${system}) extensions extensionsCommon settingsNix settingsCommon;
        inherit (inputs.vscode-extensions.extensions.${system}) vscode-marketplace open-vsx;
        inherit (inputs.devshell.functions.${system}) mkCommands mkRunCommands mkRunCommandsDir mkShell;
        inherit (inputs.workflows.functions.${system}) writeWorkflow nixCIDir;
        inherit (inputs.flakes-tools.functions.${system}) mkFlakesTools;

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
          writeSettings = writeSettingsJSON settingsCommon;

          # --- Flakes ---

          # Scripts that can be used in CI
          inherit (mkFlakesTools [ "." "nix-dev" ]) updateLocks pushToCachix;

          # --- GH Actions

          # A script to write GitHub Actions workflow file into `.github/ci.yaml`
          writeWorkflows = writeWorkflow "ci" (nixCIDir "nix-dev/");
        };

        tools = [ pkgs.terraform pkgs.terraform-ls ];

        devShells.default = mkShell {
          packages = tools;
          commands =
            mkCommands "tools" tools
            ++ mkRunCommands "ide" { "codium ." = packages.codium; inherit (packages) writeSettings; }
            ++ mkRunCommandsDir "nix-dev" "infra" { inherit (packages) updateLocks pushToCachix writeWorkflows; }
            ++ [{ name = "nix develop"; help = "Run project devshell"; }];
        };
      in
      {
        inherit packages devShells;
      });

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
