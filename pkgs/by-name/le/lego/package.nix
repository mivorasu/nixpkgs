{
  lib,
  fetchFromGitHub,
  buildGoModule,
  nixosTests,
}:

buildGoModule rec {
  pname = "lego";
  version = "4.23.1";

  src = fetchFromGitHub {
    owner = "go-acme";
    repo = "lego";
    tag = "v${version}";
    hash = "sha256-lFsxUPFFZpsGqcya70El04AefFPBubqA/abhY7Egz8Q=";
  };

  vendorHash = "sha256-L9fjkSrWoP4vs+BlWyEgK+SF3tWQFiEJjd0fJqcruVM=";

  doCheck = false;

  subPackages = [ "cmd/lego" ];

  ldflags = [
    "-s"
    "-w"
    "-X main.version=${version}"
  ];

  meta = {
    description = "Let's Encrypt client and ACME library written in Go";
    license = lib.licenses.mit;
    homepage = "https://go-acme.github.io/lego/";
    teams = [ lib.teams.acme ];
    mainProgram = "lego";
  };

  passthru.tests = {
    lego-http = nixosTests.acme.http01-builtin;
    lego-dns = nixosTests.acme.dns01;
  };
}
