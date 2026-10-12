# AGENTS.md

## Project

Nix flake providing a Valheim dedicated game server NixOS module and a package bundling steamcmd + steam-run.

## Structure

- `flake.nix` — single flake input (`nixpkgs/nixos-unstable`), x86_64-linux only, `allowUnfree = true`
- `packages/valheim-server/default.nix` — returns an attrset `{ valheim-server = ... }` (a `writeShellApplication` bundling steamcmd + steam-run); the flake aliases it as `default` and reuses it as the sole check
- `modules/default.nix` — NixOS module: `services.valheim` options, systemd service, user/group, firewall rules, SteamCMD auto-download

## Commands

```
nix build .#               # builds default package (valheim-server)
nix build .#valheim-server # short attr alias, same derivation
nix flake show .
nix flake check            # build verification (checks = packages)
nix fmt                    # format .nix files (formatter.x86_64-linux = nixfmt-tree)
nix develop                # dev shell with nixfmt, steamcmd, steam-run
```

`nix flake check` never evaluates the NixOS module. To verify module changes, eval a throwaway NixOS config:

```
nix eval --impure --json --expr 'let
  flake = builtins.getFlake (toString ./.);
  pkgs = import flake.inputs.nixpkgs.outPath { system = "x86_64-linux"; config.allowUnfree = true; };
  n = pkgs.nixos { imports = [ flake.nixosModules.default ]; services.valheim.enable = true; };
in n.config.systemd.services.valheim.serviceConfig'
```

## Module usage

```nix
imports = [ (import /path/to/valheim { }).nixosModules.default ];
# or via flake input
imports = [ valheim.nixosModules.default ];
```

## Gotchas

- `allowUnfree = true` is required — Valheim is unfree software
- Server binaries are downloaded at runtime by SteamCMD (`app_update 896660`) into `/var/lib/valheim/.local/share/Steam/Steamapps/common/Valheim dedicated server`. The running server also sets `SteamAppId=892970` (the *client* app id) — the two IDs intentionally differ, don't "fix" them to match
- The start script symlinks `linux64/steamclient.so` into `$HOME/.steam/sdk64/` (SteamGameServer requires it) and quotes the 64-bit lib path (it contains a space). Don't "simplify" these away — the server silently fails to start without them
- `passwordFile` is optional. When set, it's loaded as a systemd `LoadCredential`, so root-only secret files (e.g. sops `0400`) work without loosening permissions; the start script reads `$CREDENTIALS_DIRECTORY/valheim-password`. In the script text the password flag must be `-password "$var"` — a literal `$$` is *not* a Nix `''`-string escape, so it stays as-is and bash expands `$$` to the PID
- `passwordFile` type is `types.str` — never `types.path`. A Nix `path` literal gets copied into the world-readable Nix store. sops produces a string path, which is safe
- The server refuses to boot with a password shorter than 5 characters or one that appears in the world name. The module asserts this at eval time for `password` and re-checks at runtime (the script uses Nix's `''${` escape for `${#...}`)
- The password is passed via `-password`, so it's visible in the process cmdline (`ps`, `systemctl status`) regardless of `passwordFile` — residual, unavoidable exposure on the host
- `autoUpdate = true` runs `+app_update 896660 validate` on every start instead of only when the binary is missing
- Default password is `"changeme"` — must be changed for production
- Firewall ports (only opened when `openFirewall = true`): TCP `port`; UDP `port`, `port+1` (Valheim doesn't use `port+2`/`port+3`)
- Systemd service uses `StateDirectory = "valheim"` for persistence, with strict sandboxing (`ProtectSystem = "strict"`, `Type = "exec"`, `ReadWritePaths = [ "/var/lib/valheim" ]`). There is deliberately no `WorkingDirectory` — it may not exist yet on a fresh install, and the start script `cd`'s into it itself
- Only x86_64-linux is supported (Valheim server is x86_64 only)
