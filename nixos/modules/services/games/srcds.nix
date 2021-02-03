{ config, pkgs, lib, ... }:
with lib;

let
  cfg = config.services.srcds;

  mkServerService = name: config: {
    description = "SRCDS Server ${name}";

    bindsTo = [ "srcds-install-${config.installation}.service" ];
    after = [ "srcds-install-${config.installation}.service" ];
    wantedBy = [ "srcds-install-${config.installation}.service" "multi-user.target" ];

    serviceConfig = {
      User = "srcds";
      Restart = "always";
      WorkingDirectory = "${cfg.dataDir}";
    };

    path = [ pkgs.unixtools.ifconfig ];

    script = ''
      cd ${config.installation}

      ${cfg.steamPackages.steam-fhsenv.run}/bin/steam-run \
        ./srcds_run \
          -game ${config.game} \
          -port ${builtins.toString config.port} \
          +clientport ${builtins.toString config.clientPort} \
          +tv_port ${builtins.toString config.sourceTVPort} \
          ${strings.concatStringsSep " " config.srcdsArgs} \
    '';
  };

  mkInstallationService = name: config: 
  let 
    dir = cfg.dataDir + "/" + name;
    managedFiles = dir + "/.nix-managed-files";
    originalFiles = dir + "/.original-files";
  in {
    description = "Install ${name}";

    serviceConfig = {
      User = "srcds";
      WorkingDirectory = cfg.dataDir;
      Type = "oneshot";
      RemainAfterExit = "yes";
    };

    script = ''
      mkdir -p ${originalFiles}
      touch ${managedFiles}

      cd ${dir}

      # Delete all files created by nix and restore original files
      for file in $(cat ${managedFiles}); do
        rm -f "$file"
        if [ -f "${originalFiles}/$file" ]; then
          mv "${originalFiles}/$file" "$file"
        fi
      done
      rm -rf ${originalFiles}/*
      rm ${managedFiles}

      ${cfg.steamPackages.steamcmd}/bin/steamcmd \
        +login anonymous \
        +force_install_dir ${dir} \
        +app_update ${builtins.toString config.appID} \
        +quit

      # Copy extraConfigrationFiles from nix store and move original files
      ${strings.concatStringsSep "\n\n" (attrsets.mapAttrsToList (name: content: ''
        echo "${name}" >> ${managedFiles}
        if [ -f "${name}" ]; then
          mkdir -p "$(dirname "${originalFiles}/${name}")"
          mv "${name}" "${originalFiles}/${name}"
        fi
        mkdir -p "$(dirname ${name})"
        cat << EOF > ${name}
        ${content}
        EOF
      '') config.extraConfigFiles)}
    '';
  };

in {
  options = {
    services.srcds = {
      enable = mkEnableOption "Enable srcds servers";

      dataDir = mkOption {
        type = types.path;
        default = "/var/lib/srcds";
        description = ''
          The directory where all server installations will be stored.
        '';
      };

      steamPackages = mkOption {
        type = types.attrs;
        default = pkgs.steamPackages;
        description = "The steam packages.";
      };

      installations = mkOption {
        description = ''
          Collection of games to be installed. Each game will be installed into a a subdirectory of
          <option>services.srcds.dataDir</option>. A systemd service called <literal>srcds-install-$name</literal> will be
          created for each installation. To update a installation simply restart the corresponding systemd service.
        '';
        type = with types; attrsOf (submodule {
          options = {
            appID = mkOption {
              type = int;
              example = 740;
              description = "App ID of the game";
            };

            extraConfigFiles = mkOption {
              default = {};
              type = types.attrsOf types.lines;
              example = { "csgo/cfg/autoexec.cfg" = ''rcon_password "yeet"''; };
              description = ''
                Files in the installation directory to be added or overwritten. Whenever the systemd service is restarted all
                files changed by this option will be restored to their original state. This is done to ensure reproducibility.
              '';
            };

          };
        });
      };

      servers = mkOption {
        description = ''
          Servers to be started. A systemd service called <literal>srcds-$name</literal> will be created for each server.
        '';
        type = with types; attrsOf (submodule {
          options = {
            installation = mkOption {
              type = str;
              description = ''
                Installation to use for the server. Must be a key of <option>services.srcds.installations</option>. The server
                will be stopped or restarted when the systemd service of the specified installation is stopped or restarted.
              '';
            };

            game = mkOption {
              type = str;
              description = "Game to start. Will pass -game to srcds_run";
              example = "csgo";
            };

            srcdsArgs = mkOption {
              type = types.listOf types.str;
              default = [ "+game_type 1" "+game_mode 2" "+mapgroup mg_allclassic" "+map de_dust" ];
              description = ''
                Arguments to pass to srcds_run. <literal>-game</literal>, <literal>-port</literal>, <literal>+clientport</literal>
                and <literal>+tv_port</literal> should be specified using their respective options.
              '';
            };

            port = mkOption {
              type = types.port;
              default = 27015;
              description = ''
                Port for game transmission, pings and RCON.
              '';
            };

            sourceTVPort = mkOption {
              type = types.port;
              default = 27020;
              description = ''
                Port for sourceTV
              '';
            };

            clientPort = mkOption {
              type = types.port;
              default = 27005;
              description = ''
                Client port
              '';
            };

            openFirewall = mkOption {
              type = types.bool;
              default = false;
              description = ''
                Whether to open the firewall for the specified ports.
              '';
            };
          };
        });
      };
    };
  };

  config = mkIf cfg.enable {
    users.users.srcds = {
      description = "Source Dedicated Server owner";
      home = cfg.dataDir;
      createHome = true;
    };

    networking.firewall = let
      mkFirewall = _: serverConfig: {
        allowedTCPPorts = [ serverConfig.port ];
        allowedUDPPorts = [ serverConfig.sourceTVPort serverConfig.clientPort serverConfig.port ];
      };
    in with attrsets; zipAttrsWith (_: vals: lists.flatten vals) (mapAttrsToList mkFirewall cfg.servers);

    systemd.services = with attrsets; let
      servers = mapAttrs' (name: config: { name = "srcds-${name}"; value = mkServerService name config; }) cfg.servers;
      installs = mapAttrs' (name: config: { name = "srcds-install-${name}"; value = mkInstallationService name config; })
        cfg.installations;
    in servers // installs;
  };

  meta.maintainers = with lib.maintainers; [ f4814n ];
}

