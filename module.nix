{ pkgs, lib, config, ... }:
let
  inherit (lib) 
    mkOption
    mkPackageOption
    mkEnableOption
    mkIf
    types;
  inherit (builtins)
    elem
    head
    tail
    map
    filter
    length;

  cfg = config.services.media-manager;

  settings-format = pkgs.formats.toml {};
  settings-file = settings-format.generate "config.toml" cfg.settings;

  rules = (cfg.settings.indexers.title_scoring_rules or []) 
          ++ (cfg.settings.indexers.indexer_flag_scoring_rules or []);
  rule-names = lib.catAttrs "name" rules;
  
  duplicates = list:
                if length list <= 1 then [] else (
                  (if elem (head list) (tail list) then [ (head list) ] else []) 
                  ++ (duplicates (tail list))
                );

  rule-sets = cfg.settings.indexers.scoring_rule_sets or [];
  rule-set-names = lib.catAttrs "name" rule-sets;
  
  rule-set-undefined-rules = rule-set: filter (name: ! (elem name rule-names)) rule-set.rule_names;
  rule-sets-with-undefined-rules = filter (rs: length (rule-set-undefined-rules rs) != 0) rule-sets;  
in
{
  options = {
    services.media-manager = {
      enable = mkEnableOption { 
        description = "MediaManager"; 
      };
      
      package = mkPackageOption pkgs "MediaManager" { 
        default = [ "media-manager" ];
      };
      
      user = mkOption {
        description = "The user to run MediaManager as";
        type = types.str;
        default = "media-manager";
      };

      group = mkOption {
        description = "The group to run MediaManager as";
        type = types.str;
        default = "media-manager";
      };

      dataDir = mkOption {
        description = "Directory where MediaManager manages files";
        type = types.path;
      };

      host = mkOption {
        description = "IP address to bind to";
        type = types.str;
        default = "::1";
        example = "0.0.0.0";
      };

      port = mkOption {
        description = "Port number to bind to";
        type = types.port;
        default = 8000;
      };

      environmentFile = mkOption {
        description = ''
          Path to file storing environment variables to be passed to the service.

          See https://maxdorninger.github.io/MediaManager/configuration.html#configuring-secrets for details on the
          variable naming.
        '';
        type = types.nullOr types.path;
        default = null;
        example = "/run/secrets/media-manager.env";
      };

      settings = mkOption {
        description = ''
          Settings for MediaManager.

          See https://maxdorninger.github.io/MediaManager/configuration.html for details.
        '';
        default = {};
        type = types.submodule {
          freeformType = settings-format.type;
          options = {
            misc = {
              image_directory = mkOption {
                type = types.path;
                default = "${cfg.dataDir}/images";
                defaultText = "\${cfg.dataDir}/images";
              };
              tv_directory = mkOption {
                type = types.path;
                default = "${cfg.dataDir}/tv";
                defaultText = "\${cfg.dataDir}/tv";
              };
              movie_directory = mkOption {
                type = types.path;
                default = "${cfg.dataDir}/movies";
                defaultText = "\${cfg.dataDir}/movies";
              };
              torrent_directory = mkOption {
                type = types.path;
                default = "${cfg.dataDir}/torrents";
                defaultText = "\${cfg.dataDir}/torrents";
              };
            };
            database = {
              host = mkOption {
                description = "Postgres hostname. Leave empty for unix socket";
                type = types.str;
                default = "";
                example = "remote-db.example.com";
              };
              user = mkOption {
                description = "Username to use for postgres access";
                type = types.str;
                default = cfg.postgres.user;
                defaultText = "`cfg.postgres.user`";
              };
              dbname = mkOption {
                description = "Database name for MediaManager";
                type = types.str;
                default = cfg.postgres.user;
                defaultText = "`cfg.postgres.user`";
              };
            };
          };
        };
      };

      postgres = {
        enable = mkEnableOption {
          description = "Whether to configure Postgres for MediaManager";
        };
        user = mkOption {
          description = ''
            Postgres database user. Note that if this differs from the MediaManager
            service user, you need to manually set up a user mapping. See:
            https://nixos.org/manual/nixos/stable/#module-services-postgres-authentication
          '';
          type = types.str;
          default = cfg.user;
          defaultText = "\${cfg.user}";
        };
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = length (duplicates rule-names) == 0;
        message = let
          error-info = lib.concatMapStrings (name: "  - ${name}\n") (duplicates rule-names);
        in
          "mediamanager-nix: The following rules were defined multiple times:\n${error-info}";
      }
      {
        assertion = length (duplicates rule-set-names) == 0;
        message = let
          error-info = lib.concatMapStrings (name: "  - ${name}\n") (duplicates rule-set-names);
        in
          "mediamanager-nix: The following rule sets were defined multiple times:\n${error-info}";
      }
      {
        assertion = length (rule-sets-with-undefined-rules) == 0;
        message = let
          print-rules = rs: lib.concatMapStrings (name: "${name} ") (rule-set-undefined-rules rs);
          error-info = lib.concatMapStrings 
            (rs: "  - [ ${print-rules rs}] in rule set ${rs.name}\n") 
            rule-sets-with-undefined-rules;
          in
            "mediamanager-nix: The following rule sets are referring to undefined rules:\n${error-info}";
      }
    ];

    users.users = lib.optionalAttrs (cfg.user == "media-manager") {
      media-manager = {
        isSystemUser = true;
        group = cfg.group;
      };
    };

    users.groups = lib.optionalAttrs (cfg.group == "media-manager") { 
      media-manager = {};
    };

    systemd.services."media-manager" = {
      description = "the MediaManager service";

      wantedBy = [ "multi-user.target" ];
      requires = [ "postgresql.service" ];
      after = [ "network.target" "postgresql.service" ];
      enable = true;

      enableStrictShellChecks = true;

      environment = {
        CONFIG_FILE = settings-file;
        LOG_FILE = "/var/log/media-manager/log.json";
        PUBLIC_VERSION = cfg.package.version;
        FRONTEND_FILES_DIR = "${cfg.package}/assets/frontend";
        FRONTEND_FOLLOW_SYMLINKS = "true";
      };

      script = ''
        test -v MEDIAMANAGER_AUTH__TOKEN_SECRET \
          || MEDIAMANAGER_AUTH__TOKEN_SECRET=$(${lib.getExe pkgs.openssl} rand -hex 64)

        export MEDIAMANAGER_AUTH__TOKEN_SECRET

        ${cfg.package}/bin/media-manager-run-migrations
        
        ${cfg.package}/bin/media-manager-launch \
          --host '${cfg.host}' \
          --port ${toString cfg.port} \
          --proxy-headers
      '';
      
      unitConfig = {
        RequiresMountsFor = [
          cfg.settings.misc.movie_directory
          cfg.settings.misc.tv_directory
          cfg.settings.misc.image_directory
          cfg.settings.misc.torrent_directory
        ];
      };

      serviceConfig = {
        LogsDirectory = "media-manager";
        StateDirectory = "media-manager";
        EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
        WorkingDirectory = "/var/lib/media-manager";
        User = cfg.user;
        Group = cfg.group;
        Restart = "always";
        RestartSec = "5s";
        Type = "simple";
      };
    };

    services.postgresql = mkIf cfg.postgres.enable {
      enable = true;
      ensureDatabases = [ cfg.postgres.user ]; # keep name consistent
      ensureUsers = [
        {
          name = cfg.postgres.user;
          ensureDBOwnership = true;
        }
      ];
    };
  };
}