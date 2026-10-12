{ pkgs }:

let
  valheimTools = pkgs.writeShellApplication {
    name = "valheim-server";
    runtimeInputs = [
      pkgs.steamcmd
      pkgs.steam-run
    ];
    text = ''
      echo "Valheim server tools available:"
      echo "  - steamcmd: ${pkgs.steamcmd}/bin/steamcmd"
      echo "  - steam-run: ${pkgs.steam-run}/bin/steam-run"
      echo ""
      echo "Use these tools with the NixOS module to run a Valheim dedicated server."
    '';

    meta = with pkgs.lib; {
      description = "Valheim dedicated game server tools (steamcmd + steam-run)";
      license = licenses.mit;
      platforms = [ "x86_64-linux" ];
    };
  };
in
{
  valheim-server = valheimTools;
}
