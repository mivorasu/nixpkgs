{
  lib,
  aiohttp,
  buildPythonPackage,
  fetchFromGitHub,
  loguru,
  numpy,
  pythonOlder,
  setuptools,
  unasync,
  urllib3,
}:

buildPythonPackage rec {
  pname = "pyosohotwaterapi";
  version = "1.1.5";
  pyproject = true;

  disabled = pythonOlder "3.10";

  src = fetchFromGitHub {
    owner = "osohotwateriot";
    repo = "apyosohotwaterapi";
    tag = version;
    hash = "sha256-jE8cwC18/M58WOVpMsUjIDVmFXLBvPwaAXOSZatpjX0=";
  };

  # https://github.com/osohotwateriot/apyosohotwaterapi/pull/3
  pythonRemoveDeps = [ "pre-commit" ];

  build-system = [
    setuptools
    unasync
  ];

  dependencies = [
    aiohttp
    loguru
    numpy
    urllib3
  ];

  preBuild = ''
    export HOME=$(mktemp -d)
  '';

  # Module has no tests
  doCheck = false;

  pythonImportsCheck = [ "apyosoenergyapi" ];

  meta = {
    description = "Module for using the OSO Hotwater API";
    homepage = "https://github.com/osohotwateriot/apyosohotwaterapi";
    changelog = "https://github.com/osohotwateriot/apyosohotwaterapi/releases/tag/${src.tag}";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ fab ];
  };
}
