{
  description = "C, Odin and Nim development environment for The Loong Game";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  # Rake, the language our hot kernels are written in; its wasm-simd128 profile
  # emits the C the judge compiles.
  inputs.rake = {
    url = "github:rakelang/rake/wasm-simd128";
    flake = false;
  };

  outputs = {
    nixpkgs,
    rake,
    ...
  }: let
    system = "x86_64-linux";
    pkgs = import nixpkgs {
      inherit system;
      config.allowUnfree = true;
    };
    # nixpkgs ships raygui as a header only; Odin's vendor:raylib/raygui
    # binding links a system libraygui built from that same header.
    rayguiLibrary = pkgs.stdenv.mkDerivation {
      pname = "raygui-library";
      inherit (pkgs.raygui) version;
      dontUnpack = true;
      buildInputs = [pkgs.raylib];
      buildPhase = ''
        cp ${pkgs.raygui}/include/raygui.h raygui.c
        $CC -O2 -fPIC -shared -DRAYGUI_IMPLEMENTATION raygui.c -lraylib -o libraygui.so
      '';
      installPhase = "install -Dm755 libraygui.so $out/lib/libraygui.so";
    };
    debugViewLibraries = [pkgs.raylib rayguiLibrary pkgs.glfw pkgs.libGL];
    # The official C API release, whose static libwasmtime.a fleet workers'
    # judge links, so it runs on any glibc 2.28 Linux (zig-judge-worker-build).
    wasmtimeRelease = pkgs.fetchzip {
      url = "https://github.com/bytecodealliance/wasmtime/releases/download/v48.0.1/wasmtime-v48.0.1-x86_64-linux-c-api.tar.xz";
      hash = "sha256-3AOW4u9wQln0Ws374gvEjOPKPgpdHQdDAlfrkZz6r+o=";
    };
    rakec = pkgs.ocamlPackages.buildDunePackage {
      pname = "rake";
      version = "0.3.0-alpha.1";
      src = rake;
      nativeBuildInputs = [pkgs.ocamlPackages.menhir pkgs.makeWrapper];
      buildInputs = [pkgs.ocamlPackages.ppx_deriving pkgs.ocamlPackages.cmdliner];
      # --verify-native compiles the emitted C for wasm32 and disassembles it,
      # which needs a clang without the host cc-wrapper's flags, pointed at its
      # own headers, which Nix keeps in a separate output.
      postFixup = let
        clang = pkgs.llvmPackages_20.clang-unwrapped;
        wasmClang = pkgs.writeShellScriptBin "clang" ''
          exec ${clang}/bin/clang -resource-dir=${clang.lib}/lib/clang/20 "$@"
        '';
      in ''
        wrapProgram $out/bin/rakec --prefix PATH : ${pkgs.lib.makeBinPath [
          wasmClang
          pkgs.llvmPackages_20.llvm
        ]}
      '';
    };
  in {
    packages.${system}.rakec = rakec;
    devShells.${system}.default = pkgs.mkShell {
      packages = [
        rakec
        pkgs.bubblewrap
        pkgs.clang_20
        pkgs.llvmPackages_20.clang-tools # clangd
        pkgs.just
        pkgs.jq
        pkgs.python3 # Historical article figure and profiling scripts.
        pkgs.watchexec
        pkgs.zig
        pkgs.zls
        pkgs.wasmtime.dev
        pkgs.wasmtime.lib
        pkgs.odin
        pkgs.ols
        pkgs.nim
        pkgs.nimble
        pkgs.nimlangserver
      ];
      buildInputs = debugViewLibraries ++ [pkgs.zlib pkgs.openssl pkgs.sqlite pkgs.capnproto];
      CAPNP_PREFIX = "${pkgs.capnproto}";
      WASMTIME_INCLUDE = "${pkgs.wasmtime.dev}/include";
      WASMTIME_LIB = "${pkgs.wasmtime.lib}/lib";
      WASMTIME_RELEASE = "${wasmtimeRelease}";
      UNSWBC_NO_UPDATE = "1";
      LD_LIBRARY_PATH = (pkgs.lib.makeLibraryPath ([pkgs.stdenv.cc.cc.lib] ++ debugViewLibraries)) + ":/run/opengl-driver/lib";
      shellHook = ''
        export LOONG_STORAGE_ROOT="$PWD/assets"
        export LOONG_BUILD_REGISTRY="$LOONG_STORAGE_ROOT/registry"
        mkdir -p build/tmp
      '';
    };
  };
}
