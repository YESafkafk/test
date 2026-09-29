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

      version = builtins.head (
        builtins.match ''.*\(define version "([^"]*)"\).*'' (builtins.readFile ./src/chezterm/app.ss)
      );

      runtimeLibs =
        pkgs: with pkgs; [
          wayland
          libxkbcommon
          freetype
          fontconfig
        ];

      devHeaders =
        pkgs: with pkgs; [
          wayland.dev
          libxkbcommon.dev
          freetype.dev
          fontconfig.dev
        ];

      # c2ffi is a bare libclang tool: it knows neither the clang resource
      # headers nor where Nix keeps the system headers.  Keep llvmPackages in
      # step with the one pkgs.c2ffi is built with.
      c2ffiFlags =
        pkgs:
        lib.concatStringsSep " " (
          [
            "--nostdinc"
            "-i ${pkgs.llvmPackages_21.clang}/resource-root/include"
            "-i ${lib.getDev pkgs.stdenv.cc.libc}/include"
          ]
          ++ map (p: "-i ${p}/include") (devHeaders pkgs)
        );

      # fontconfig configuration with a monospace font, for the renderer tests.
      fontsConf = pkgs: pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };

      source =
        files:
        lib.fileset.toSource {
          root = ./.;
          fileset = lib.fileset.unions files;
        };

      buildSource = source [
        ./Makefile
        ./src
        ./tools
        ./tests
        ./chezterm.desktop
        ./chezterm.scm.example
      ];

      bindingsSource = source [
        ./Makefile
        ./ffi
        ./tools
        ./protocols
      ];

      scheme = pkgs: lib.getExe pkgs.chez;
    in
    {
      packages = forAllSystems (
        pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
        in
        {
          default = self.packages.${system}.chezterm;

          chezterm = pkgs.callPackage ./nix/package.nix {
            inherit version;
            src = buildSource;
          };

          # `make bindings protocols` with c2ffi from nixpkgs: the generated
          # src/chezterm/{ffi,protocols}.ss, plus ffi-linked.ss, generated
          # with the store paths the package uses.
          bindings = pkgs.stdenv.mkDerivation {
            pname = "chezterm-bindings";
            inherit version;
            src = bindingsSource;

            nativeBuildInputs = [
              pkgs.chez
              pkgs.c2ffi
              pkgs.pkg-config
            ];
            buildInputs = devHeaders pkgs;

            makeFlags = [ "SCHEME=${scheme pkgs}" ];
            buildPhase = ''
              runHook preBuild
              export C2FFI_FLAGS="${c2ffiFlags pkgs}"
              mkdir -p src/chezterm
              make bindings protocols $makeFlags
              make bindings $makeFlags FFI_LIB=build/ffi-linked.ss SHARED_OBJECTS="${
                self.packages.${system}.chezterm.sharedObjects
              }"
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              install -Dm644 -t $out src/chezterm/ffi.ss src/chezterm/protocols.ss build/ffi-linked.ss
              runHook postInstall
            '';
          };
        }
      );

      apps = forAllSystems (
        pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
          chezterm = self.packages.${system}.chezterm;
          app = description: program: {
            type = "app";
            program = "${program}";
            meta = { inherit description; };
          };
          inCheckout = name: text: {
            inherit name;
            runtimeInputs = [
              pkgs.chez
              pkgs.gnumake
            ];
            text = ''
              if [ ! -f tests/run.ss ] || [ ! -f ffi/spec.ss ]; then
                echo "${name}: run this from the root of a chezterm checkout" >&2
                exit 1
              fi
              ${text}
            '';
          };
        in
        {
          default = self.apps.${system}.chezterm;
          chezterm = app chezterm.meta.description (lib.getExe chezterm);

          # The test suite on the working tree.  The committed bindings load
          # libraries by soname, so here they come from LD_LIBRARY_PATH.
          test = app "Run the test suite in the current checkout" (
            lib.getExe (
              pkgs.writeShellApplication (
                inCheckout "chezterm-test" ''
                  export LD_LIBRARY_PATH=${lib.makeLibraryPath (runtimeLibs pkgs)}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
                  export FONTCONFIG_FILE=''${FONTCONFIG_FILE:-${fontsConf pkgs}}
                  make test SCHEME=scheme "$@"
                ''
              )
            )
          );

          # Regenerate src/chezterm/ffi.ss and protocols.ss in the checkout.
          bindings = app "Regenerate the FFI bindings and protocol descriptions" (
            lib.getExe (
              pkgs.writeShellApplication (
                inCheckout "chezterm-bindings" ''
                  make bindings protocols SCHEME=scheme C2FFI=${lib.getExe pkgs.c2ffi} \
                    C2FFI_FLAGS="${c2ffiFlags pkgs}" \
                    FT_INC=${lib.getDev pkgs.freetype}/include/freetype2 "$@"
                ''
              )
            )
          );
        }
      );

      checks = forAllSystems (
        pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
          packages = self.packages.${system};
        in
        {
          # Package build; its installCheck runs `chezterm --version`.
          chezterm = packages.chezterm;

          # Both passes of `make test`: from source with run-time checks and
          # against the optimized build.
          tests = packages.chezterm.overrideAttrs {
            pname = "chezterm-tests";
            doCheck = true;
            checkTarget = "test";
            preCheck = ''
              export FONTCONFIG_FILE=${fontsConf pkgs}
              export XDG_CACHE_HOME=$TMPDIR/cache
            '';
            doInstallCheck = false;
            installPhase = "touch $out";
          };

          # The committed generated files are what the generators produce
          # (with the pinned nixpkgs headers), and relinking them for the
          # package gives the same file as generating with store paths.
          generated =
            pkgs.runCommand "chezterm-check-generated"
              {
                nativeBuildInputs = [
                  pkgs.chez
                  pkgs.diffutils
                ];
              }
              ''
                diff -u ${./src/chezterm/ffi.ss} ${packages.bindings}/ffi.ss
                diff -u ${./src/chezterm/protocols.ss} ${packages.bindings}/protocols.ss
                scheme --libdirs ${./tools} --script ${./tools/c2ffi-gen.ss} relink \
                  ${./src/chezterm/ffi.ss} relinked.ss ${packages.chezterm.sharedObjects}
                diff -u ${packages.bindings}/ffi-linked.ss relinked.ss
                touch $out
              '';

          formatting =
            pkgs.runCommand "chezterm-check-formatting"
              {
                nativeBuildInputs = [ self.formatter.${system} ];
              }
              ''
                cp -r ${self} tree
                chmod -R u+w tree
                cd tree
                treefmt --ci
                touch $out
              '';

          # Headless sway in a VM: start chezterm, type into it, screenshot.
          # Needs KVM (or a lot of patience).
          vm = import ./nix/vm-test.nix {
            inherit pkgs;
            chezterm = packages.chezterm;
          };
        }
      );

      # nixfmt is the RFC 166 style formatter (nixfmt-rfc-style is an alias).
      # No Scheme formatter: there is none for Chez that keeps the existing
      # hand-aligned layout, and the generated files come from pretty-print.
      formatter = forAllSystems (
        pkgs:
        pkgs.treefmt.withConfig {
          runtimeInputs = [ pkgs.nixfmt ];
          settings = {
            tree-root-file = "flake.nix";
            on-unmatched = "debug";
            formatter.nixfmt = {
              command = "nixfmt";
              includes = [ "*.nix" ];
            };
          };
        }
      );

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.chez
            pkgs.gnumake
            pkgs.c2ffi
            pkgs.pkg-config
            self.formatter.${pkgs.stdenv.hostPlatform.system}
            # manual testing in a headless compositor
            pkgs.sway
            pkgs.wtype
            pkgs.grim
            pkgs.wl-clipboard
          ];
          buildInputs = devHeaders pkgs;
          # `make`, `make test` and build/chezterm use the committed bindings,
          # which load the libraries by soname.
          LD_LIBRARY_PATH = lib.makeLibraryPath (runtimeLibs pkgs);
          # For `make bindings`.
          C2FFI_FLAGS = c2ffiFlags pkgs;
        };
      });
    };
}
