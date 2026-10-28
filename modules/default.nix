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

    # Download (or update) the server binaries via SteamCMD
    steamcmd_update() {
      ${cfg.steamCmdPackage}/bin/steamcmd +login anonymous +force_install_dir "$STEAM_SERVER_DIR" +app_update 896660 validate +quit
    }

    # Download the server on first start, and optionally refresh it on every start
    if [ ! -f "$STEAM_SERVER_DIR/valheim_server.x86_64" ]; then
      echo "Valheim server not found, downloading via SteamCMD..."
      steamcmd_update
    ${optionalString cfg.autoUpdate ''
      else
        echo "Checking for Valheim server updates via SteamCMD..."
        steamcmd_update
    ''}
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

    # Valheim refuses to boot with a short password, or one that appears in the world name
    if [ "''${#valheimPassword}" -lt 5 ]; then
      echo "ERROR: the server password must be at least 5 characters long" >&2
      exit 1
    fi
    case "$valheimPassword" in
      *"${cfg.worldName}"*)
        echo "ERROR: the server password must not contain the world name" >&2
        exit 1
        ;;
    esac

    exec ${pkgs.steam-run}/bin/steam-run ./valheim_server.x86_64 \
      -name "${cfg.serverName}" \
      -port ${toString cfg.port} \
      -world "${cfg.worldName}" \
      -password "$valheimPassword" \
      -public ${if cfg.public then "1" else "0"} \
      -nographics -batchmode -autostart \
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
      type = types.nullOr types.str;
      default = null;
      description = "Path to a file containing the server password. Mutually exclusive with password. Use a string path (as produced by sops) so the secret is not copied into the Nix store.";
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

    autoUpdate = mkOption {
      type = types.bool;
      default = false;
      description = "Run a SteamCMD update check (app_update 896660 validate) on every server start instead of only downloading when missing.";
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
    # Input validation: the server silently refuses to boot on bad passwords
    assertions = [
      {
        assertion = cfg.passwordFile == null || cfg.password == "changeme";
        message = "services.valheim: `password` and `passwordFile` are mutually exclusive; leave `password` at its default when using `passwordFile`.";
      }
      {
        assertion = cfg.passwordFile != null || lib.stringLength cfg.password >= 5;
        message = "services.valheim: the server password must be at least 5 characters long.";
      }
      {
        assertion = cfg.passwordFile != null || !lib.hasInfix cfg.password cfg.worldName;
        message = "services.valheim: the server password must not appear inside the world name.";
      }
    ];

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

    # Open firewall ports if requested (Valheim only uses port and port+1)
    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ];
    networking.firewall.allowedUDPPorts = mkIf cfg.openFirewall [
      cfg.port
      (cfg.port + 1)
    ];

    # Systemd service
    systemd.services.valheim = {
      description = "Valheim Server";
      wantedBy = [ "multi-user.target" ];
      # The first start downloads the server via SteamCMD, so wait for a real network
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];

      serviceConfig = {
        Type = "exec";
        User = "${valheimUser}";
        Group = "${valheimGroup}";
        # No WorkingDirectory: it may not exist yet on a fresh install, and the
        # start script cd's into it itself after (re)creating it.
        ExecStart = "${startScript}/bin/valheim-start";
        Restart = "always";
        RestartSec = 10;

        # Directory creation and permissions
        StateDirectory = "valheim";
        StateDirectoryMode = "0755";

        # Hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ "/var/lib/valheim" ];
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
