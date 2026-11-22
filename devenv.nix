{
  pkgs,
  lib,
  config,
  inputs,
  ...
}:

{
  # https://devenv.sh/basics/
  env.GREET = "waylock-custom";

  # https://devenv.sh/packages/
  packages = [
    pkgs.git
    pkgs.zig
    pkgs.wayland
    pkgs.wayland-scanner
    pkgs.wayland-protocols
    pkgs.libxkbcommon
    pkgs.cairo
    pkgs.pam
    pkgs.pkg-config
    pkgs.scdoc
    pkgs.wlroots
  ];

  # https://devenv.sh/languages/
  languages.zig.enable = true;

  # https://devenv.sh/scripts/
  scripts.build.exec = ''
    zig build -Doptimize=ReleaseSafe
  '';

  scripts.test.exec = ''
    zig build test
  '';

  # https://devenv.sh/basics/
  enterShell = ''
    echo "waylock-custom devenv"
    zig version
    pkg-config --modversion wayland-client
  '';

  # See full reference at https://devenv.sh/reference/options/
}
