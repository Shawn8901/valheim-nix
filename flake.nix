{
  description = "Valheim dedicated game server NixOS module";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      # Valheim server binaries are x86_64-linux only
      forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" ];

      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

      packagesFor =
        system:
        import ./packages/valheim-server {
          pkgs = pkgsFor system;
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          packages = packagesFor system;
        in
        packages
        // {
          default = packages.valheim-server;
        }
      );

      checks = forAllSystems packagesFor;

      formatter = forAllSystems (system: (pkgsFor system).nixfmt-tree);

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              nixfmt
              steamcmd
              steam-run
            ];
          };
        }
      );

      nixosModules.default = import ./modules;
    };
}
