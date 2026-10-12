{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let
  cfg = config.services.valheim;
  valheimUser = "valheim";
  valheimGroup = "valheim";

  # Valheim server startup script
  startScript = pkgs.writeShellScriptBin "valheim-start" ''
    export LD_LIBRARY_PATH="/var/lib/valheim/.local/share/Steam/Steamapps/common/Valheim dedicated server/linux64:$LD_LIBRARY_PATH"
    export SteamAppId=892970

    # The server is installed in the Steam directory structure
    STEAM_SERVER_DIR="/var/lib/valheim/.local/share/Steam/Steamapps/common/Valheim dedicated server"

    # Ensure the server directory exists
    mkdir -p "$STEAM_SERVER_DIR"

    # Check if server exists, if not download it
    if [ ! -f "$STEAM_SERVER_DIR/valheim_server.x86_64" ]; then
      echo "Valheim server not found, downloading via SteamCMD..."
      ${cfg.steamCmdPackage}/bin/steamcmd +login anonymous +force_install_dir "$STEAM_SERVER_DIR" +app_update 896660 validate +quit
    fi

    # SteamGameServer looks for steamclient.so under $HOME/.steam/sdk64
    mkdir -p "$HOME/.steam/sdk64"
    if [ -f "$STEAM_SERVER_DIR/linux64/steamclient.so" ]; then
      ln -sf "$STEAM_SERVER_DIR/linux64/steamclient.so" "$HOME/.steam/sdk64/steamclient.so"
    fi

    # Set working directory to the server location
    cd "$STEAM_SERVER_DIR" || exit 1

    echo "Starting Valheim server..."
    valheimPassword="${cfg.password}";
    ${optionalString (cfg.passwordFile != null) ''
      # Read from a systemd credential if present, else from the passwordFile directly
      if [ -n "$CREDENTIALS_DIRECTORY" ] && [ -f "$CREDENTIALS_DIRECTORY/valheim-password" ]; then
        valheimPassword=$(cat "$CREDENTIALS_DIRECTORY/valheim-password");
      elif [ -f "${cfg.passwordFile}" ]; then
        valheimPassword=$(cat "${cfg.passwordFile}");
      fi
    ''}
    exec ${pkgs.steam-run}/bin/steam-run ./valheim_server.x86_64 \
      -name "${cfg.serverName}" \
      -port ${toString cfg.port} \
      -world "${cfg.worldName}" \
      -password "$valheimPassword" \
      -public ${if cfg.public then "1" else "0"} \
      -nographics -batchmode -server -autostart \
      -maxplayers ${toString cfg.maxPlayers} \
      ${optionalString cfg.enableSaveDebug "-savedebug"} \
      ${optionalString cfg.enableDebug "-debug"}
  '';
in
{
  options.services.valheim = {
    enable = mkEnableOption "Valheim game server";

    serverName = mkOption {
      type = types.str;
      default = "NixOS Valheim Server";
      description = "Name of the Valheim server";
    };

    port = mkOption {
      type = types.int;
      default = 2456;
      description = "Port for the Valheim server";
    };

    worldName = mkOption {
      type = types.str;
      default = "World";
      description = "Name of the world";
    };

    password = mkOption {
      type = types.str;
      default = "changeme";
      description = "Password for the server";
    };

    passwordFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to a file containing the server password. Mutually exclusive with password.";
    };

    public = mkOption {
      type = types.bool;
      default = false;
      description = "Whether the server is public (1) or private (0)";
    };

    enableSaveDebug = mkOption {
      type = types.bool;
      default = false;
      description = "Enable save debugging";
    };

    enableDebug = mkOption {
      type = types.bool;
      default = false;
      description = "Enable debug mode";
    };

    maxPlayers = mkOption {
      type = types.int;
      default = 10;
      description = "Maximum number of players";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open ports in the firewall for the Valheim server";
    };

    steamCmdPackage = mkOption {
      type = types.package;
      default = pkgs.steamcmd;
      description = "SteamCMD package to use for downloading the server";
    };
  };

  config = mkIf cfg.enable {
    # Create valheim user and group
    users.users.${valheimUser} = {
      isNormalUser = true;
      group = valheimGroup;
      home = "/var/lib/valheim";
      createHome = true;
      description = "Valheim Server User";
      uid = config.ids.uids.${valheimUser} or null;
    };

    users.groups.${valheimGroup} = {
      gid = config.ids.gids.${valheimUser} or null;
    };

    # Open firewall ports if requested
    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ];
    networking.firewall.allowedUDPPorts = mkIf cfg.openFirewall [
      cfg.port
      (cfg.port + 1)
      (cfg.port + 2)
      (cfg.port + 3)
    ];

    # Systemd service
    systemd.services.valheim = {
      description = "Valheim Server";
      wantedBy = [ "multi-user.target" ];
      # The first start downloads the server via SteamCMD, so wait for a real network
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];

      serviceConfig = {
        Type = "simple";
        User = "${valheimUser}";
        Group = "${valheimGroup}";
        # No WorkingDirectory: it may not exist yet on a fresh install, and the
        # start script cd's into it itself after (re)creating it.
        ExecStart = "${startScript}/bin/valheim-start";
        Restart = "always";
        RestartSec = 10;
        Environment = [
          "SteamAppId=892970"
        ];

        # Directory creation and permissions
        StateDirectory = "valheim";
        StateDirectoryMode = "0755";

        # Hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadOnlyPaths = [ "/" ];
        ReadWritePaths = [
          "/var/lib/valheim"
          "/tmp"
          "/var/tmp"
        ];
      }
      # Make a root-only passwordFile (e.g. sops 0400) readable as a systemd credential
      // optionalAttrs (cfg.passwordFile != null) {
        LoadCredential = "valheim-password:${cfg.passwordFile}";
      };
    };

    # Install required packages
    environment.systemPackages = [
      startScript
      cfg.steamCmdPackage
    ];
  };
}
