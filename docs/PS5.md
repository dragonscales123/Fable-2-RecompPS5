# Fable 2 Recomp on the PS5 (homebrew)

This branch (`ps5-port`) builds Fable 2 Recomp as a homebrew title for a
jailbroken PS5. It renders through the ReXGlue SDK's Xenos GPU emulation on
its Vulkan backend, with Mesa's RADV linked into the title, and runs on the
SDK's PS5 port (github.com/dragonscales123/rexglue-sdk-PS5, branch
`fable2-ps5`: the PS5 port with himdo's Fable 2 SDK changes merged in).

Status: **work in progress, not yet booted on a console.** The SDK's Xenos
GPU has not run on the PS5 before; re:Blue PS5 and Lost Odyssey PS5 render
through plume instead.

You need your own Fable 2 GOTY (USA/Europe) disc. Nothing from the game is in
this repository, and nothing derived from it should be published.

## What you need

- Ubuntu 24.04 (WSL works; keep the work tree in the Linux filesystem, not
  under `/mnt/c`).
- clang/lld 20 (`clang-20`, `clang++-20`).
- mihawk-99's PS5 toolchain, as for re:Blue PS5 (its `docs/PS5.md` lists the
  commits): the payload SDK, and PS5_Vulkan with its RADV release archive
  built.
- This repository with its SDK submodule:

  ```
  git clone -b ps5-port https://github.com/dragonscales123/Fable-2-RecompPS5.git
  cd Fable-2-RecompPS5
  git submodule update --init thirdparty/rexglue-sdk
  ```

  `ps5/build.sh` initialises the SDK's own submodules and applies its PS5
  patches for SDL and FFmpeg the first time it runs.

`ps5/build.sh` looks for the toolchain next to this checkout, then in
`~/bluedragon-ps5` (the re:Blue PS5 work folder). Point it elsewhere with
`--sdk` (the built payload SDK: `toolchain/prospero.cmake` and
`bin/prospero-lld`) and `--vulkan` (PS5_Vulkan).

## Game files

Extract `default.xex`, `data/` and `nxeart` from your disc into `game/`
(ignored by git). The supported executable is the GOTY USA/Europe one
(`constants/game_versions.json`); the game checks its SHA-256 at start.

## Build

```
ps5/build.sh
```

Options: `--sdk`, `--vulkan`, `--title-id` (default `PPSA99214`; re:Blue PS5
is `PPSA99213` and Lost Odyssey PS5 `PPSA99212`). The script builds the SDK's
code generator for the host, generates and compiles the recompiled code, and
links the title with `ps5/link-title.sh`. The first build takes a long time.

On PS5 the hand-tuned guest function overrides (`src/core/hotfunc/`) are left
out (`FABLE2_HOTFUNCS=OFF`): they are copies of the stock v0.10.0 code
generator's output, and the PS5 SDK's generator emits different code.

The result is `out/build/ps5/dist/PPSA99214/`: `eboot.bin`, `sce_sys/`,
`sce_module/`, the recomp's Lua scripts in `data/scripts/recomp/`,
`fable2_config.toml` and `ps5-env.example.txt`.

The dashboard icon (`ps5/sce_sys/icon0.png`) is a plain placeholder. To use
your own, put a 512x512 PNG at `ps5/sce_sys/icon0.local.png`; git ignores it
and the build uses it in place of the placeholder.

## Install

1. Copy the title folder to `/data/homebrew/PPSA99214/` on the console.
2. Copy the contents of `game/` (`default.xex`, `data/`, `nxeart`) into that
   same folder: the game's content root is the folder `eboot.bin` is in.
3. Launch it from the home screen.

Saves, the shader and pipeline caches, logs and `fable2_config.toml` are
written next to `eboot.bin`. `/app0/boot.txt` records start-up and any early
crash; `ps5-env.txt` (from `ps5-env.example.txt`) sets SDK options.
