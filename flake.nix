{
  description = "chezterm -- a Wayland terminal emulator written in Chez Scheme";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      # Wayland only, and the FFI bindings assume glibc on Linux.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Libraries the generated FFI (src/chezterm/ffi.ss) opens with
      # load-shared-object at run time.  libc comes with Chez itself.
      runtimeLibs =
        pkgs: with pkgs; [
          wayland
          libxkbcommon
          freetype
          fontconfig
        ];
    in
    {
      packages = forAllSystems (pkgs: {
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.chezterm;

        chezterm = pkgs.stdenv.mkDerivation {
          pname = "chezterm";
          version = "0-unstable-${self.lastModifiedDate or "19700101"}";

          src = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./Makefile
              ./src
              ./tools
              ./tests
              ./chezterm.desktop
              ./chezterm.scm.example
            ];
          };

          nativeBuildInputs = [
            pkgs.chez
            pkgs.makeWrapper
          ];

          makeFlags = [
            "SCHEME=${lib.getExe pkgs.chez}"
            "PREFIX=${placeholder "out"}"
          ];

          # The tests load the FFI library, which opens the shared objects.
          doCheck = true;
          checkTarget = "test";
          preCheck = ''
            export LD_LIBRARY_PATH=${lib.makeLibraryPath (runtimeLibs pkgs)}
          '';

          postFixup = ''
            wrapProgram $out/bin/chezterm \
              --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath (runtimeLibs pkgs)}
          '';

          meta = {
            description = "Wayland terminal emulator written in Chez Scheme";
            mainProgram = "chezterm";
            platforms = lib.platforms.linux;
          };
        };
      });

      apps = forAllSystems (
        pkgs:
        let
          chezterm = self.packages.${pkgs.stdenv.hostPlatform.system}.chezterm;
        in
        {
          default = self.apps.${pkgs.stdenv.hostPlatform.system}.chezterm;
          chezterm = {
            type = "app";
            program = lib.getExe chezterm;
            meta.description = chezterm.meta.description;
          };
        }
      );

      checks = forAllSystems (
        pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
        in
        {
          # Builds the package and runs `make test` (sources and optimized build).
          chezterm = self.packages.${system}.chezterm;

          formatting =
            pkgs.runCommand "check-formatting"
              {
                nativeBuildInputs = [ self.formatter.${system} ];
              }
              ''
                cp -r ${self} src
                chmod -R u+w src
                cd src
                treefmt --ci --tree-root .
                touch $out
              '';
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          inputsFrom = [ self.packages.${pkgs.stdenv.hostPlatform.system}.chezterm ];
          # c2ffi for `make bindings`.
          packages = [ pkgs.c2ffi ];
          LD_LIBRARY_PATH = lib.makeLibraryPath (runtimeLibs pkgs);
        };
      });
    };
}
