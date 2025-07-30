{ grafanaPlugin, lib }:

grafanaPlugin {
  pname = "grafana-lokiexplore-app";
  version = "1.0.22";
  zipHash = "sha256-y1WJ1RxUbJSsiSApz3xvrARefNnXdZxDVfzeGfDZbFo=";
  meta = {
    description = "Browse Loki logs without the need for writing complex queries";
    license = lib.licenses.agpl3Only;
    teams = [ lib.teams.fslabs ];
    platforms = lib.platforms.unix;
  };
}
