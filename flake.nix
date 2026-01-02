{
  description = "Package MediaManager for nix consumption";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    media-manager = {
      url = "github:maxdorninger/MediaManager";
      flake = false;
    };

    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      pyproject-nix,
      uv2nix,
      pyproject-build-systems,
      media-manager,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      forAllSystems = lib.genAttrs lib.systems.flakeExposed;

      workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = media-manager; };

      overlay = workspace.mkPyprojectOverlay {
        sourcePreference = "wheel";
      };

      overrides = final: prev:
        let
          inherit (final) resolveBuildSystem;
          inherit (builtins) mapAttrs;
          buildSystemOverrides = {
            "bencoder".setuptools = [];
          };
        in
        mapAttrs (
          name: spec:
          prev.${name}.overrideAttrs (old: {
            nativeBuildInputs = old.nativeBuildInputs ++ resolveBuildSystem spec;
          })
        ) buildSystemOverrides;

      pythonSets = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          python = lib.head (pyproject-nix.lib.util.filterPythonInterpreters {
            inherit (workspace) requires-python;
            inherit (pkgs) pythonInterpreters;
          });
        in
        (pkgs.callPackage pyproject-nix.build.packages {
          inherit python;
        }).overrideScope
          (
            lib.composeManyExtensions [
              pyproject-build-systems.overlays.wheel
              overlay
              overrides
              (final: prev: {
                mediamanager = prev.mediamanager.overrideAttrs (old: {
                  patches =  (old.patches or []) ++ [
                    (pkgs.fetchpatch2 {
                      name = "allow-following-symlinks-in-frontend-dir.patch";
                      url = "https://github.com/strangeglyph/MediaManager/commit/64f01cc9197b41de5895691aae6da9a13449ab5b.patch?full_index=1";
                      hash = "sha256-qpBuuhDNMbH7c9K1G8LgF/Cta990t5rtUXmLsq4D+VY=";
                    })
                  ];
                });
              })
            ]
          )
      );

    in
    {
      packages = forAllSystems (system: 
        let
          pythonSet = pythonSets.${system};
          pkgs = nixpkgs.legacyPackages.${system};
          mm-pkgs = self.outputs.packages.${system};
          inherit (pkgs.callPackages pyproject-nix.build.util { }) mkApplication;
        in
        {
          virtual-env = (pythonSet.mkVirtualEnv "media-manager-env" workspace.deps.default)
                          .overrideAttrs (old: {
                            venvIgnoreCollisions = old.venvIgnoreCollisions ++ [ "*/fastapi" ];
                          });

          assets = pkgs.runCommand "media-manager-assets" {} ''
            mkdir -p $out/assets

            cp -r ${media-manager}/alembic $out/assets/alembic
            cp ${media-manager}/alembic.ini $out/assets/alembic.ini
          '';

          frontend = pkgs.buildNpmPackage rec {
            pname = "mediamanager-frontend";
            version = "0.0.0-nix";

            src = "${media-manager}/web";
            npmDeps = pkgs.importNpmLock {
              npmRoot = "${media-manager}/web";
            };

            npmConfigHook = pkgs.importNpmLock.npmConfigHook;

            path_prefix = "";
            
            env = {
              PUBLIC_API_URL = "${path_prefix}";
              BASE_PATH = "${path_prefix}/web";
              PUBLIC_VERSION = version;
            };

            postInstall = ''
              mkdir -p $out/assets
              cp -r build $out/assets/frontend
            '';
          };

          default = pkgs.symlinkJoin {
            name = "media-manager";
            version = mm-pkgs.frontend.version;

            paths = [
              mm-pkgs.virtual-env
              mm-pkgs.assets
              mm-pkgs.frontend

              (pkgs.writeShellScriptBin "media-manager-run-migrations" ''
                cd ${mm-pkgs.assets}/assets
                ${mm-pkgs.virtual-env}/bin/alembic upgrade head
              '')

              (pkgs.writeShellScriptBin "media-manager-launch" ''
                LOCATION=$(${mm-pkgs.virtual-env}/bin/python -c 'import media_manager; print(media_manager.__file__)')
                ${mm-pkgs.virtual-env}/bin/fastapi run $(dirname $LOCATION)/main.py $@
              '')
            ];
          };
        }
      );

      overlays.default = final: prev: {
        media-manager = self.outputs.packages."${prev.stdenv.hostPlatform.system}".default;
      };

      nixosModules.default = {
        imports = [ ./module.nix ];
        config.nixpkgs.overlays = [ self.outputs.overlays.default ];
      };

      checks = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
          {
            default = pkgs.testers.runNixOSTest {
              name = "mediamanager integration test";
              node.pkgsReadOnly = false;
              nodes.machine = { config, pkgs, ...}: {
                imports = [ self.outputs.nixosModules.default ];
                config = {
                  services.media-manager = {
                    enable = true;
                    package = self.outputs.packages."${system}".default;
                    postgres.enable = true;
                    port = 12345;
                    dataDir = "/tmp";
                    settings = {
                      misc.frontend_url = "http://[::1]:12345";
                    };
                  };
                  
                  systemd.tmpfiles.settings."10-mediamanager" = {
                    "/tmp/movies".d = { user = config.services.media-manager.user; };
                    "/tmp/shows".d = { user = config.services.media-manager.user; };
                    "/tmp/images".d = { user = config.services.media-manager.user; };
                    "/tmp/torrents".d = { user = config.services.media-manager.user; };
                  };
                };
              };
              testScript = { nodes, ... }: ''
                machine.wait_for_unit("media-manager.service")
              '';
            };
          }
      );
    };
}
