{ pkgs, system, drv-tools }:
let
  inherit (drv-tools.lib.${system}) mkShellApp framedBrackets concatStringsNewline mkBin withMan;
  man = drv-tools.lib.${system}.man;
  inherit (pkgs.lib.strings) escapeShellArg concatMapStringsSep;
  inherit (pkgs.lib.lists) unique;
  inherit (builtins) isList dirOf map isString;

  writeTF = writeFile ".tf";
  writeFile = extension: expr: filePath:
    withMan
      (mkShellApp {
        name = "hcl-write-file";
        text = ''
          printf ${escapeShellArg "${expr}"} > ${filePath}${extension}
          terraform fmt ${filePath}${extension}
        '';
        runtimeInputs = [ pkgs.terraform ];
        description = ''Write an `HCL` expression into `${filePath}${extension}` and format it'';
      })
      (x: ''
        ${man.DESCRIPTION}
        ${x.meta.description}
      '');

  writeTfvars = writeFiles_ ".auto.tfvars";
  writeTFs = writeFiles_ ".tf";
  writeFiles = writeFiles_ "";
  writeFiles_ = extension: data:
    assert isList data;
    let
      dirs = unique (map ({ filePath, ... }: dirOf filePath) data);
      f = concatMapStringsSep "\n";
    in
    withMan
      (mkShellApp {
        name = "hcl-write-files";
        text = concatStringsNewline
          [
            (f (dir: "mkdir -p '${dir}'") dirs)
            (f ({ expr, filePath }: "printf ${escapeShellArg "${expr}"} > '${filePath}${extension}'") data)
            ("printf '${framedBrackets "written files"}'")
            (f ({ filePath, ... }: "printf ${escapeShellArg "${filePath}\n"}") data)
            ("printf '${framedBrackets "formatted files"}'")
            (f (dir: "terraform fmt ${dir}") dirs)
          ];
        runtimeInputs = [ pkgs.terraform ];
        description = "Write `HCL` expressions into corresponding `FILE_PATH${extension}`-s";
      })
      (x:
        ''
          ${man.DESCRIPTION}
          ${x.meta.description} and format the parent directories of these files.
        ''
      );

  # remove newlines between characters
  # https://stackoverflow.com/a/31109819
  # interactively compose sed expressions
  # https://sed.js.org/
  # -r for extended regexp
  tf2nix = outDir: filePaths:
    assert isList filePaths && isString outDir;
    let
      dirs = unique (map (filePath: "${outDir}/${dirOf filePath}") filePaths);
      f = concatMapStringsSep "\n";
      out = filePath: ''${outDir}/${filePath}'';
      transform = tfPath: nixPath: assert isString tfPath && isString nixPath;
        ''
          printf 'let\n' > "${nixPath}"
          sed -r '
            s/(\w+)\s+"/\1./g; 
            s/(\s*)(\w+)\s*=\s*(.+)("|\w|]|})$/\1\2 = \3\4;/g; 
            H;1h;$!d;x; s/}\n\n*\)/})/g;  
            s/(\w)\s+=\s+\{/\1 = a {/g; 
            s/("|^(\s*)(\w+))\s+\{/\1 = b {/g;
            s/(\]|\)|\})\n/\1;\n/g; 
            s/(\w+)"\s+"(\w+)/\1.\2/g; 
            s/(\w+)"\s+=/\1 =/g;
            s/(\n\s+\w+)\s+\{/\1 = b {/g;
            s/(}|")\s*,/\1/g;
            ' "${tfPath}" >> "${nixPath}"
          printf '\nin' >> "${nixPath}"
        '';
    in
    withMan
      (mkShellApp
        {
          name = "tf2nix";
          text = concatStringsNewline [
            (f (dir: ''mkdir -p "${dir}"'') dirs)
            ("printf '${framedBrackets "wrote temporary files"}'")
            (f (filePath: ''cat "${filePath}" > "${out filePath}" && printf '%s\n' "${out filePath}"'') filePaths)
            ("printf '${framedBrackets "formatted files"}'")
            (f (dir: ''terraform fmt "${dir}"'') dirs)
            (f (filePath: transform (out filePath) "${out filePath}.nix") filePaths)
            ("printf '${framedBrackets "removed temporary files"}'")
            (f (filePath: ''rm "${out filePath}" && printf "%s\n" "${out filePath}"'') filePaths)
          ];
          runtimeInputs = [ pkgs.terraform pkgs.gnused ];
          description = ''Naively convert `Terraform` files to `Nix`'';
        }
      )
      (x:
        ''
          ${man.DESCRIPTION}
          ${x.meta.description}. Write the resulting files under `${outDir}`.
          Put expressions in a file into `let in` blocks to reduce the amount of syntax errors
        ''
      );
  convertTf2Nix =
    let
      out = "converted";
      tf2nix_ = tf2nix out [ "$1" ];
    in
    withMan
      (
        mkShellApp {
          name = "convert-tf-to-nix";
          text = ''
            mkdir -p "${out}/$(dirname "$1")"
            ${mkBin tf2nix_} $1
          '';
          description = "Convert a given `.tf` file to Nix and write it under `${out}/PATH`";
        }
      )
      (x: ''
        ${man.DESCRIPTION}
        ${x.meta.description}

        ${man.EXAMPLES}
        `${x.name} A/file.tf`
        :   convert `file.tf` to `${out}/A/file.nix`
      '');
in
{
  lib = {
    inherit
      convertTf2Nix
      tf2nix
      writeFiles
      writeFiles_
      writeTF
      writeTFs
      writeTfvars
      ;
  };
  packages = {
    inherit convertTf2Nix;
  };
}
