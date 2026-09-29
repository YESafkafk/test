{
  lib,
  stdenv,
  chez,
  wayland,
  libxkbcommon,
  freetype,
  fontconfig,
  # Ctrl+click on a URL runs xdg-open.  Appended to PATH, so a system-wide
  # xdg-open wins; override with null to leave it out.
  xdg-utils,
  version,
  src,
}:

let
  # The shared objects src/chezterm/ffi.ss loads (sonames from ffi/spec.ss),
  # as SONAME=PATH with store paths, so nothing depends on LD_LIBRARY_PATH.
  # libc is the one Chez itself is linked against.
  sharedObjects =
    let
      so = pkg: name: "${name}=${lib.getLib pkg}/lib/${name}";
    in
    lib.concatStringsSep " " [
      (so stdenv.cc.libc "libc.so.6")
      (so wayland "libwayland-client.so.0")
      (so wayland "libwayland-cursor.so.0")
      (so libxkbcommon "libxkbcommon.so.0")
      (so freetype "libfreetype.so.6")
      (so fontconfig "libfontconfig.so.1")
    ];
  scheme = lib.getExe chez;
in
stdenv.mkDerivation {
  pname = "chezterm";
  inherit version src;

  nativeBuildInputs = [ chez ];

  postPatch = ''
    make relink SCHEME=${scheme} SHARED_OBJECTS="${sharedObjects}"
  '';

  makeFlags = [
    "SCHEME=${scheme}"
    "PREFIX=${placeholder "out"}"
  ]
  ++ lib.optional (xdg-utils != null) "RUNTIME_PATH=${lib.makeBinPath [ xdg-utils ]}";

  # The test suite runs in checks.<system>.tests of the flake.
  doCheck = false;

  # The library paths are only inside compiled Scheme code; record them in
  # plain text too so the runtime closure never depends on Nix finding them
  # in the (possibly compressed) fasl files.
  postInstall = ''
    echo ${sharedObjects} | tr ' ' '\n' > $out/lib/chezterm/shared-objects
  '';

  # Loading the program loads (chezterm ffi), which opens every library.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    $out/bin/chezterm --version | grep -Fx "chezterm ${version}"
    runHook postInstallCheck
  '';

  passthru = { inherit sharedObjects; };

  meta = {
    description = "Wayland terminal emulator written in Chez Scheme";
    mainProgram = "chezterm";
    platforms = lib.platforms.linux;
  };
}
