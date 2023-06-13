{ pkgs, system ? builtins.currentSystem }:
let
  inherit (import ./hcl.nix { inherit pkgs; })
    optional_ optional object list b a _lib mapMerge
    mkVariables mkVariableValues mkBlocks mkBlocks_
    string number bool bb qq modifyMapMerge
    ;
  inherit (pkgs.lib.attrsets) genAttrs;
  # Tests -----------
  # inspired by Terraform docs
  docsMain = mkBlocks {
    terraform = b {
      required_providers = b {
        docker = a {
          source = "kreuzwerker/docker";
          version = "~> 2.22.0";
        };
      };
    };
    resource.type.b = b { d = b { }; };
    resource.type.a = with _lib; b {
      t = tomap [{ a = "b"; c = "d"; }];
      s = abs [ (ceil [ (floor [ (-3.5) ]) ]) ];
    };
  };

  docsType = list (object {
    name = string;
    enabled = optional bool true;
    website = optional
      (object {
        index_document = optional string "index.html";
        error_document = optional string "error.html";
        routing_rules = optional_ string;
      })
      { };
  });

  docsVariables = mkVariables {
    a = { type = object { a = number; }; };
    b = { type = optional string "b"; };
    buckets = { type = docsType; };
    c = { type = optional (optional_ (object { c = optional string ""; })) { }; };
    d = { type = optional_ string; default = "hey"; };
  };

  docsTfvars = mkVariableValues docsVariables {
    a = { a = 100; };
    b = "c";
    buckets = [
      {
        name = "production";
        website = {
          routing_rules =
            ''
              [
                {
                  "Condition" = { "KeyPrefixEquals": "img/" }
                  "Redirect"  = { "ReplaceKeyPrefixWith": "images/" }
                }
              ]
            '';
        };
      }
      {
        name = "archived";
        enabled = false;
      }
      {
        name = "docs";
        website = {
          index_document = "index.txt";
          error_document = "error.txt";
        };
      }
    ];
  };

  # Yandex Cloud

  ycMain = with _lib;
    mkBlocks_ docsMain.__
      {
        terraform = b {
          required_providers = b {
            yandex = a {
              source = "yandex-cloud/yandex";
            };
          };
          required_version = ">= 0.13";
        };
      }
      (__: with __; {
        provider.yandex = b {
          zone = "ru-central1-a";
        };
      })
      (__: with __; {
        resource.yandex_vpc_network.network-1 = b {
          name = "network1";
        };
      })
      (__: with __; {
        resource.yandex_vpc_subnet.subnet-1 = b {
          name = "subnet1";
          zone = "ru-central1-a";
          network_id = yandex_vpc_network.network-1 "id";
          v4_cidr_blocks = [ "192.168.10.0/24" ];
        };
      })
      (__: with __; mapMerge
        [{ cores = 2; memory = 2; vm = "1"; }
          { cores = 4; memory = 4; vm = "2"; }]
        (x:
          {
            resource.yandex_compute_instance."vm-${x.vm}" = b {
              name = "terraform2";
              resources = b {
                cores = x.cores;
                memory = x.memory;
              };
              boot_disk = b {
                initialize_params = b {
                  image_id = "fd8ingbofbh3j5h7i8ll";
                };
              };
              network_interface = b {
                subnet_id = yandex_vpc_subnet.subnet-1 "id";
                nat = true;
              };
              metadata = a {
                user-data = file [ "./meta" ];
              };
            };
          }
        )
      )
      (__: with __; modifyMapMerge [ 1 2 ] toString
        (x:
          {
            output."internal_ip_address_vm_${x}" = b {
              value = yandex_compute_instance."vm-${x}".network_interface "0" "ip_address";
            };
            output."external_ip_address_vm_${x}" = b {
              value = yandex_compute_instance."vm-${x}".network_interface "0" "nat_ip_address";
            };
          }
        )
      )
  ;

  # Docker

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

  dockerTfvars = mkVariableValues dockerVariables {
    "${appPython}" = {
      HOST_PORT = 8002;
    };
    "${appPurescript}" = {
      HOST_PORT = 8003;
    };
  };

  # should place expr A before and separately from expr B:
  # if B depends on A (uses its accessors)
  # if we want A to be rendered before B
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
      # this __ is to pass variables created in previous expressions into this one
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
{
  inherit dockerMain dockerTfvars dockerVariables;
  inherit docsMain docsTfvars docsVariables;
  inherit ycMain;
}
