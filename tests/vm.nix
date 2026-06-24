{ self, nixpkgs }:

{
  name = "termix";

  nodes.machine = { ... }: {
    imports = [ self.nixosModules.default ];
    nixpkgs.overlays = [ self.overlays.default ];

    services.termix = {
      enable = true;
      port = 8080;
      # guacamole managed + default-on (exercises the guacd dependency path).
    };

    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 4096;
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("guacamole-server.service")
    machine.wait_for_unit("termix.service")
    machine.wait_for_unit("termix-nginx.service")

    # Backend API comes up on its internal port and is proxied by nginx.
    machine.wait_for_open_port(30001)
    machine.wait_for_open_port(8080)

    # nginx serves the SPA at the root.
    machine.succeed("curl -fsS http://localhost:8080/ | grep -qi '<!doctype html'")

    # /health is proxied through nginx to the backend.
    machine.succeed("curl -fsS http://localhost:8080/health")

    # Secrets were auto-generated and persisted.
    machine.succeed("test -f /var/lib/termix/.env")

    # opkssh was pre-placed from nixpkgs (no runtime GitHub download needed).
    machine.succeed("test -e /var/lib/termix/opkssh/opkssh-linux-amd64")
    machine.succeed("/var/lib/termix/opkssh/opkssh-linux-amd64 --version")
  '';
}
