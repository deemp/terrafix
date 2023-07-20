{ pkgs, system, drv-tools }:
let
  inherit (drv-tools.lib.${system})
    mkShellApp mkBin framedBrackets framedBrackets_ concatStringsNewline;
  inherit (pkgs.lib.attrsets) mapAttrsToList;
  inherit ((import ./tf-tools.nix { inherit pkgs system drv-tools; }).lib) writeFiles tf2nix;

  testData = (import ./test-data.nix { inherit pkgs system; });

  tests = {
    testDocs = with testData; writeFiles [
      { expr = docsMain; filePath = "docs/main.tf"; }
      { expr = docsVariables; filePath = "docs/variables.tf"; }
      { expr = docsTfvars; filePath = "docs/terraform.tfvars"; }
    ];

    testDocker = with testData; writeFiles [
      { expr = dockerMain; filePath = "docker/main.tf"; }
      { expr = dockerVariables; filePath = "docker/variables.tf"; }
      { expr = dockerTfvars; filePath = "docker/terraform.tfvars"; }
    ];

    testYandexCloud = with testData; writeFiles [
      { expr = ycMain; filePath = "yc/main.tf"; }
    ];

    # have lexicographically greater names than tests writing TFs
    # as the below tests depend on the results of the above tests
    testDocs2Nix = tf2nix "tf2nix" [ "docs/main.tf" "docs/variables.tf" "docs/terraform.tfvars" ];
    testDocker2Nix = tf2nix "tf2nix" [ "docker/main.tf" "docker/variables.tf" "docker/terraform.tfvars" ];
    testYandexCloud2Nix = tf2nix "tf2nix" [ "yc/main.tf" ];
  };

  testCases = mkShellApp {
    name = "run-tests";
    description = "Run all tests";
    text = concatStringsNewline (
      mapAttrsToList
        (
          name: val: concatStringsNewline [
            (''printf '${framedBrackets_ "\n" "" name}' '')
            (mkBin val)
            (
              ''printf '${framedBrackets_ "\n" "\n\n" "test verdict : %s"}' \
                "$(if [[ $? == 0 ]]; then printf "ok"; else printf "not ok"; fi)"''
            )
          ]
        )
        tests
    );
  };
in
{
  inherit testCases;
} // tests
