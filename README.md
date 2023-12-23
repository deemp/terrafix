# Terrafix

Writing in Terraform [configuration syntax](https://www.terraform.io/language/syntax/configuration) often violates the [DRY](https://en.wikipedia.org/wiki/Don%27t_repeat_yourself) principle due to lack of named types and other features. Let's **fix** it!

This repo contains a `Nix` [eDSL](https://wiki.haskell.org/Embedded_domain_specific_language) which can be translated into [HCL](https://github.com/hashicorp/hcl), a language used by [Terraform](https://www.terraform.io/). In other words, we can use the power of Nix to generate understandable HCL expressions.

## Related works

- [Pulumi](https://www.pulumi.com/) - infrastructure as code
- [Terraform CDK](https://developer.hashicorp.com/terraform/cdktf) - provision infrastructure using familiar programming languages
- [nickel](https://github.com/tweag/nickel) - a new configuration language
- [terranix](https://github.com/terranix/terranix) - a popular tool that generates `terraform.json`
- [nixform](https://github.com/brainrake/nixform) - another tool that generates `terraform.json` from a Nix eDSL
- [xinomorf](https://github.com/kreisys/xinomorf) - a pretty outdated tool that generates terraform configurations

## Repo contents

- [language definition](.nix/hcl.nix)
  - eDSL implementation
  - expressions for Terraform's built-in functions (see [Limitations](#limitations))
  - anti-boilerplate functions
- [expressions](.nix/test-data.nix) used in tests
- [scripts](.nix/tf-tools.nix)
  - to generate Terraform files from the given `Nix` expressions
  - to naively convert the existing Terraform files into `.nix` files (see [Tests](#tests))

## Prerequisites

- Knowledge of Nix syntax
  - [Nix Language](https://nixos.org/manual/nix/unstable/language/index.html)
    - more specifically, [Data Types](https://nixos.org/manual/nix/unstable/language/values.html#attribute-set)
  - [Learn Nix in Y minutes](https://learnxinyminutes.com/docs/nix/)

- (Optionally) Understanding of Flakes
  - [Flakes](https://github.com/deemp/the-little-things/blob/7f9703e2d7f8a3cbf39344cddb7868421b4fcc6d/README.md#flakes) info

## Sample test

This is one of the [test expressions](.nix/test-data.nix). It's taken from [here](https://github.com/deemp/devops-labs/blob/d40ddd922b33d9639a76cd2d028d4f753a5d04a3/.nix/terraform/docker.nix#L1). The below Nix snippets are in `let in` blocks to have a better syntax highlighting.

There are 2 apps: `app_purescript` and `app_python`. Each of them has a server written in a corresponding language, and these servers show the current time in a browser. Their Docker containers were pushed to Docker Hub. On a host, these apps are under the directories `./app_purescript` and `./app_python`. In Docker containers, each app's code is placed under the `/app` directory.

There is some data that is needed to run the apps. This data is described in `dockerVariables`. Here, notable fields are: `DOCKER_PORT` - internal port inside a Docker container, `HOST` - the address of a host on which to run the container, `NAME` - a new name for a container, `PORT` - the external port. It is worth to mention that all fields of the object in `type` are the same for both apps, except for the `HOST_PORT`. Also, the names of their variables differ. We can use `Nix` functions to use the same template inside `dockerVariables` to declare the variables for both apps:

```nix
let
  appPurescript = "app_purescript";
  appPython = "app_python";
  apps = [ appPurescript appPython ];
  
  # x may have a custom __toString
  _mod = x: { _ = "${toString x}"; try = "try_${x}"; path = "path_${x}"; renamed = "renamed_${x}"; };

  # we can apply a modifier _mod to consistently use the forms of `app`
  dockerVariables = mkVariables (modifyMapMerge apps _mod (app:
    {
      "${app._}" = {
        type = object {
          DIR = optional string "/app";
          DOCKER_PORT = optional number 80;
          HOST = optional string "0.0.0.0";
          NAME = optional string "${app.renamed}";
          HOST_PORT = number;
        };
      };
    }));
in
```

When producing HCL, we'll get such code in `variables.tf`:

```hcl
variable "app_purescript" {
  type = object({
    DIR         = optional(string, "/app")
    DOCKER_PORT = optional(number, 80)
    HOST        = optional(string, "0.0.0.0")
    HOST_PORT   = number
    NAME        = optional(string, "renamed_app_purescript")
  })
}
variable "app_python" {
  type = object({
    DIR         = optional(string, "/app")
    DOCKER_PORT = optional(number, 80)
    HOST        = optional(string, "0.0.0.0")
    HOST_PORT   = number
    NAME        = optional(string, "renamed_app_python")
  })
}
```

Next, we need the values. We can supply just the necessary data, namely `HOST_PORT`-s, and a set of variables. The mapping between the set of names in `dockerTfvars` and the set of names in `dockerVariables` should be injective. The missing values will be generated automatically according to their variables' types. Thus, if necessary, we can supply the empty set to `mkVariableValues`. In this case, the Nix expression will be:

```nix
let
  dockerTfvars = mkVariableValues dockerVariables {
    "${appPython}" = {
      HOST_PORT = 8002;
    };
    "${appPurescript}" = {
      HOST_PORT = 8003;
    };
  };
in
```

These `tfvars` will be mapped over the supplied set of `variables` to produce a set of values in `terraform.tfvars`:

```hcl
app_purescript = {
  DIR         = "/app"
  DOCKER_PORT = 80
  HOST        = "0.0.0.0"
  HOST_PORT   = 8003
  NAME        = "renamed_app_purescript"
}

app_python = {
  DIR         = "/app"
  DOCKER_PORT = 80
  HOST        = "0.0.0.0"
  HOST_PORT   = 8002
  NAME        = "renamed_app_python"
}
```

Furthermore, we will be able to use the accessors like `var.app_python.HOST_PORT` to get the same expression (`var.app_python.HOST_PORT`) in Terraform code.

Finally, we compose the main Terraform file.

There is a couple of rules. We should place a block `A` before the block `B` if:

1. `B` depends on `A`, e.g., uses its accessor

   - Here, `resource.docker_container.${app.try}` accesses `var.${app._}.DIR;`. Hence, this `var` should be supplied by previos expressions.

1. `A` should be rendered before `B`

   - Notice that in the corresponding Terraform code, the `terraform` block is placed before locals and `resource.docker_image`.
   - On the other hand, as `resource.docker_image` and `locals` are given in the same set, `locals` precedes the `resource` blocks. This happens because `locals` is lexicographically smaller than `resource` and because `Nix` orders the elements of a set lexicographically.

Again, we use the same template to declare the `docker_image` and both `locals`. These `locals` assume that `main.tf` is at `./terraform/docker/main.tf`. So, the whole expression is:

```nix
let
  dockerMain = with _lib;
    mkBlocks_ dockerTfvars.__
      {
        terraform = b {
          required_providers = b {
            docker = a {
              source = "kreuzwerker/docker";
              version = "~> 2.22.0";
            };
          };
        };
      }
      (__: with __; modifyMapMerge apps _mod (app: {
        resource.docker_image = {
          "${app.try}" = b {
            name = "dademd/${app._}:latest";
            keep_locally = false;
          };
        };
        locals = b {
          # bb means x: "${x}"
          "${app.path}" = abspath [ "${bb path.root}/../../${app._}" ];
        };
      }))
      # this __ is to pass the variables created in previous expressions into this one
      # alternatively, here, we can write __.var."${app}".DIR;
      (__: with __; modifyMapMerge apps _mod (app: {
        resource.docker_container.${app.try} = b {
          image = docker_image.${app.try} "image_id";
          name = app.try;
          restart = "always";
          volumes = b {
            container_path = var.${app._}.DIR;
            host_path = local."${app.path}";
            read_only = false;
          };
          ports = b {
            internal = var.${app._}.DOCKER_PORT;
            external = var.${app._}.HOST_PORT;
          };
          env = [ "HOST=${bb var.${app._}.HOST}" "PORT=${bb var.${app._}.DOCKER_PORT}" ];
          host = b {
            host = "localhost";
            ip = var.${app._}.HOST;
          };
        };
      }));
in
```

In fact, we can supply the missing accessors via a sequence of strings, as in `image = docker_image.${app.try} "image_id";`. This is useful when a block was declared by a provider, and we don't want to rewrite it and supply as a Nix expression.

The corresponding `main.tf`:

```hcl
terraform {
  required_providers = {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 2.22.0"
    }
  }
}
locals {
  path_app_purescript = abspath("${path.root}/../../app_purescript")
  path_app_python     = abspath("${path.root}/../../app_python")
}
resource "docker_image" "try_app_purescript" {
  keep_locally = false
  name         = "dademd/app_purescript:latest"
}
resource "docker_image" "try_app_python" {
  keep_locally = false
  name         = "dademd/app_python:latest"
}
resource "docker_container" "try_app_purescript" {
  env = [
    "HOST=${var.app_purescript.HOST}",
    "PORT=${var.app_purescript.DOCKER_PORT}"
  ]
  host {
    host = "localhost"
    ip   = var.app_purescript.HOST
  }
  image = docker_image.try_app_purescript.image_id
  name  = "try_app_purescript"
  ports = {
    external = var.app_purescript.HOST_PORT
    internal = var.app_purescript.DOCKER_PORT
  }
  restart = "always"
  volumes = {
    container_path = var.app_purescript.DIR
    host_path      = local.path_app_purescript
    read_only      = false
  }
}
resource "docker_container" "try_app_python" {
  env = [
    "HOST=${var.app_python.HOST}",
    "PORT=${var.app_python.DOCKER_PORT}"
  ]
  host {
    host = "localhost"
    ip   = var.app_python.HOST
  }
  image = docker_image.try_app_python.image_id
  name  = "try_app_python"
  ports = {
    external = var.app_python.HOST_PORT
    internal = var.app_python.DOCKER_PORT
  }
  restart = "always"
  volumes = {
    container_path = var.app_python.DIR
    host_path      = local.path_app_python
    read_only      = false
  }
}
```

Overall, we can notice that definitely a lot of expressions have almost complete duplicates. We believe that whenever this is the case, such expressions should be generated from DRY Nix code.

## Tests

1. Enter the repo

  ```console
  git clone https://github.com/deemp/terrafix
  ```

1. Run tests. This will also write into Terraform files expressions generated from [test-data](test-data.nix). Also, the tests will quite naively translate these expressions back into Nix under './tf2nix'

```console
nix run .#testCases
```

1. Convert a `.tf` file into a `.nix` one and get the output under `./converted`:

```console
nix run .#convertTf2Nix docker/main.tf
```

To run the individual tests, see the outputs of

```console
nix flake show
```

And then run one of them:

```console
nix run .#testDocs
```

## Disclaimer

The author is not an experienced Terraform user. That's why, he may have missed some Terraform's features that can make one's code DRY.

The author likes Nix and likes generating configs using this language.

## Limitations

There are some HCL constructs that aren't yet supported. To name a few:

- [ ] modules and output variables
- Modules should probably be implemented similarly to `mkBlocks`
- output variables - as `resources` and `variables`
- [ ] [Conditional expressions](https://developer.hashicorp.com/terraform/language/expressions/conditionals)
- They require making conditional accessors or merging accessors for objects in both options
- [ ] Possibly, some [built-in](https://developer.hashicorp.com/terraform/language/functions) functions
- For now, they're all constructed using simple language constructs. It's highly likely that some of them use more advanced constructs (to be checked)
- [ ] Output variables
- Need a function that will extract them from blocks
- [ ] Indices and [splat expressions](https://www.terraform.io/language/expressions/references#references-to-resource-attributes)
- can pass them as special objects inside lists to accessors, like `some_list [_ast_]` to mean `some_list[*]`
- [ ] `__functor` like in accessors to allow continuing the expressions after functions like `values(aws_instance.example)[*].id`
- [ ] `for` [expressions and conditionals](https://www.terraform.io/language/expressions/for)

## Comparisons

### terranix

1. `terrafix` is an eDSL and it doesn't suggest any new infrastructure or mechanisms. It is a means to produce `Terraform` code (`.tf`, `.tfvars`) from `Nix` code. On the other hand, `terranix` suggests a [module system](https://terranix.org/documentation/modules/), which is different from the Terraform's one, [documentation generation](https://terranix.org/), and it compiles to `.json`.

1. In the author's opinion, for debugging, finding the mapping between `.tf` files and `.nix` files is easier than between `.json` and `.nix`. Also, one may utilize Terraform's Language Server to find the errors in the generated code. To add, `terrafix` looks pretty similar to HCL, so there is a highly error-prone script to convert the existing Terraform files into `.nix`. It [worked](#tests) for simple examples though.

1. Currently, `terrafix` has similar syntactic sugar, and, hopefully, the same compile-time safety due to `accessors`. In `terrafix`, it's possible to use an accessor generated from previous blocks + add the missing fields:

    ```nix
      image = config.resource.hcloud_server.myserver.image "id";
    ```

    This will look like `image = config.resource.hcloud_server.myserver.image.id` in the Terraform code.
    Additionally, there will be a Nix compile time error if such an accessor is missing. Please, search the word `accessor` on the [README](.#) page of `terrafix` to see more examples.

    In `terranix`, one [may write](https://terranix.org/documentation/terranix-vs-hcl/)

    ```nix
      image = config.resource.hcloud_server.myserver.image;
    ```

    However, the author is not sure if in `.json` it won't become a string stored in `config.resource.hcloud_server.myserver.image`.

1. `terrafix` can (naively) render all Terraform's standard functions. There seems to be no such functionality in `terranix`

1. `terrafix` is an experimental language, so it has a lot of limitations. E.g. modules like `dockerMain` can only be mixed into an argument of `mkBlocks_` of another module to make their variables available inside. See more [limitations](#limitations).

## Contribute

### Issues and PRs

[issues](https://docs.github.com/en/issues/tracking-your-work-with-issues/about-issues) and [Pull requests](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/proposing-changes-to-your-work-with-pull-requests/about-pull-requestsgit) are welcome! E.g. you may submit a missing language feature request or implementation.

### Prerequisites

See these for additional info:

- [codium-generic](https://github.com/deemp/flakes/tree/main/templates/codium/generic#readme) - info just about `VSCodium` and extensions.
- [nix-vscode-extensions](https://github.com/nix-community/nix-vscode-extensions) (pinned [here](https://github.com/deemp/flakes/blob/main/source-flake/vscode-extensions/flake.nix)).
- [Prerequisites](https://github.com/deemp/flakes#prerequisites).
- [Troubleshooting](https://github.com/deemp/flakes/blob/main/README/Troubleshooting.md)

### Code

1. [Install Nix](https://github.com/deemp/flakes/blob/main/README/InstallNix.md).
1. [Install direnv](https://github.com/deemp/flakes/blob/main/README/InstallNix.md#direnv).
1. Run `devShells` in this repo directory.

   - Option 1: run `direnv allow` to use `direnv`.
   - Option 2: run `devShells` manually.

      ```console
      nix develop nix-dev/
      nix develop
      ```

1. (Optionally) Start `VSCodium`.

    ```console
    nix run nix-dev/#codium .
    ```

## Configs

- [.markdownlint.jsonc](./.markdownlint.jsonc) - for `markdownlint` from the extension `davidanson.vscode-markdownlint`
- [.envrc](./.envrc) - for [direnv](https://github.com/direnv/direnv).
- [ci.yaml](.github/workflows/ci.yaml) - a generated `GitHub Actions` workflow. See [workflows](https://github.com/deemp/flakes/tree/main/workflows).
