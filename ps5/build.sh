#!/usr/bin/env bash
# Fable 2 Recomp - build the PS5 homebrew title (docs/PS5.md), from re:Blue
# PS5's ps5/build.sh.
#
#   ps5/build.sh [--sdk DIR] [--vulkan DIR] [--title-id PPSAxxxxx] [--copy-to DIR]
#
# --copy-to DIR (or copy_to=DIR in ps5/build.local.sh, which git ignores):
# also copy the finished title folder to DIR/<TITLE_ID>/, e.g. a Windows
# folder under /mnt/c. A fable2_config.toml already there is kept.
#
# Needs: your own Fable 2 GOTY default.xex in game/ (or the repository root),
# the SDK submodule (thirdparty/rexglue-sdk, branch fable2-ps5), a PS5 payload
# SDK and PS5_Vulkan with its RADV release archive built, and clang/lld 20 on
# the host. Writes out/build/ps5/dist/<TITLE_ID>/.
#
# The SDK's code generator (rexglue) runs on this machine, never on the
# console. Fable 2's shaders are translated at run time by the SDK's Xenos GPU,
# so there is no host shader step.
#
# Paths default to the work folder this checkout sits in, then to
# ~/bluedragon-ps5 (the re:Blue PS5 toolchain), or PS5_PAYLOAD_SDK and
# PS5_VULKAN_DIR from the environment.
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
parent=$(dirname "$root")
first_dir() { # the first argument that is a directory
    local dir
    for dir in "$@"; do
        [[ -n $dir && -d $dir ]] && { echo "$dir"; return; }
    done
    echo "${1:-}"
}
# re:Blue's default first (the built SDK PS5_VulkanTemplate's bootstrap makes).
sdk=${PS5_PAYLOAD_SDK:-$(first_dir "$parent/PS5_VulkanTemplate/.deps/native/ps5-payload-sdk" \
    "$HOME/bluedragon-ps5/PS5_VulkanTemplate/.deps/native/ps5-payload-sdk" \
    "$parent/PS5_PayloadSDK/host" "$HOME/bluedragon-ps5/PS5_PayloadSDK/host")}
vulkan=${PS5_VULKAN_DIR:-$(first_dir "$parent/PS5_Vulkan" "$HOME/bluedragon-ps5/PS5_Vulkan")}
rexsdk=$root/thirdparty/rexglue-sdk
title_id=PPSA99214
copy_to=${FABLE2_PS5_COPY_TO:-}
# Personal settings (copy_to=..., PS5_PAYLOAD_SDK=..., PS5_VULKAN_DIR=...).
if [[ -f $root/ps5/build.local.sh ]]; then
    # shellcheck source=/dev/null
    source "$root/ps5/build.local.sh"
    sdk=${PS5_PAYLOAD_SDK:-$sdk}
    vulkan=${PS5_VULKAN_DIR:-$vulkan}
fi
while (($#)); do
    case $1 in
        --sdk) sdk=$2; shift 2 ;;
        --vulkan) vulkan=$2; shift 2 ;;
        --title-id) title_id=$2; shift 2 ;;
        --copy-to) copy_to=$2; shift 2 ;;
        *) echo "usage: ${0##*/} [--sdk DIR] [--vulkan DIR] [--title-id PPSAxxxxx] [--copy-to DIR]" >&2; exit 2 ;;
    esac
done
echo "payload SDK: $sdk${PS5_PAYLOAD_SDK:+ (from PS5_PAYLOAD_SDK)}"
echo "PS5_Vulkan:  $vulkan${PS5_VULKAN_DIR:+ (from PS5_VULKAN_DIR)}"
[[ -f $sdk/toolchain/prospero.cmake && -x $sdk/bin/prospero-lld ]] ||
    { echo "no built PS5 payload SDK at $sdk (--sdk; needs toolchain/ and bin/prospero-lld)" >&2; exit 2; }
[[ -f $vulkan/.deps/native/radv-release/lib/libvulkan_radeon.ps5.a ]] ||
    { echo "no RADV release archive in $vulkan (tools/build-radv.sh release)" >&2; exit 2; }
if [[ ! -f $rexsdk/include/rex/platform.h ]]; then
    git -C "$root" submodule update --init thirdparty/rexglue-sdk
fi
grep -q REX_PLATFORM_PS5 "$rexsdk/include/rex/platform.h" ||
    { echo "thirdparty/rexglue-sdk is not the PS5 SDK (rexglue-sdk-PS5, branch fable2-ps5)" >&2; exit 2; }
git -C "$rexsdk" submodule update --init --recursive --depth 1 > /dev/null

# Codegen reads default.xex from the repository root (fable_2_manifest.toml);
# the extracted disc lives in game/.
if [[ ! -e $root/default.xex && -f $root/game/default.xex ]]; then
    ln -s game/default.xex "$root/default.xex"
fi
[[ -f $root/default.xex ]] ||
    { echo "no default.xex: extract your Fable 2 GOTY disc into game/ (docs/PS5.md)" >&2; exit 2; }

# Submodule changes the PS5 needs, kept as patches because the submodules
# point at upstream: SDL and FFmpeg in the SDK. Each is applied once; an
# already-applied patch is left alone.
apply_patch() { # repo-dir patch
    if git -C "$1" apply --check -R "$2" 2> /dev/null; then
        return
    fi
    git -C "$1" apply --check "$2" ||
        { echo "${2##*/} neither applies nor is applied in $1" >&2; exit 1; }
    git -C "$1" apply --whitespace=nowarn "$2"
    echo "applied ${2##*/} in $1"
}
apply_patch "$rexsdk/thirdparty/sdl3" "$rexsdk/tools/patches/sdl-ps5.patch"
apply_patch "$rexsdk/thirdparty/FFmpeg" "$rexsdk/tools/patches/ffmpeg-ps5.patch"

host=$root/out/build/ps5-host
mkdir -p "$host"

# 1. The SDK's code generator, for this machine.
rexglue=$host/rexglue-sdk/bin/rexglue
if [[ ! -x $rexglue ]]; then
    cmake -S "$rexsdk" -B "$host/rexglue-sdk" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang-20 -DCMAKE_CXX_COMPILER=clang++-20 -DCMAKE_LINKER_TYPE=LLD \
        -DREXGLUE_ENABLE_TRACY=OFF > "$host/rexglue-sdk.configure.log"
    cmake --build "$host/rexglue-sdk" --target rexglue
    mkdir -p "$(dirname "$rexglue")"
    # The SDK writes its binaries to <sdk>/out/<platform>/.
    built=$(find "$rexsdk/out" -maxdepth 2 -type f -name rexglue -perm -u+x | head -1)
    [[ -n $built ]] || { echo "rexglue was not built" >&2; exit 1; }
    ln -sf "$built" "$rexglue"
else
    # Keep it current with the SDK sources (a no-op when nothing changed).
    cmake --build "$host/rexglue-sdk" --target rexglue > "$host/rexglue-sdk.build.log"
fi
# The code templates are compiled into rexglue but are not part of codegen's
# input fingerprint, so a rebuilt generator regenerates the game code.
codegen_stamp=$root/generated/default/codegen.build.stamp
if [[ -f $codegen_stamp && $(readlink -f "$rexglue") -nt $codegen_stamp ]]; then
    echo "rexglue changed: regenerating the recompiled code"
    rm -f "$codegen_stamp" "$root/generated/default/codegen.stamp" "$root/generated/default/recomp_patches.stamp"
fi

# 2. The title.
build=$root/out/build/ps5
# A build tree is tied to its toolchain: start afresh when it changes.
# (Recorded in our own file: the PS5 toolchain file rewrites CMake's cached
# CMAKE_TOOLCHAIN_FILE, so the cache can't be compared.)
toolchain=$(readlink -f "$sdk/toolchain/prospero.cmake")
toolchain_record=$build/ps5-toolchain.txt
if [[ -d $build && -f $toolchain_record && $(cat "$toolchain_record") != "$toolchain" ]]; then
    echo "toolchain changed: starting $build afresh"
    rm -rf "$build"
fi
mkdir -p "$build"
echo "$toolchain" > "$toolchain_record"
# Perf counters stay on (the SDK default): Fable2App reads the frame time
# through rex::perf::GetSnapshotCounter, which only exists with them. In a
# Release build the counting itself is compiled out.
configure() {
    cmake -S "$root" -B "$build" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$toolchain" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS_RELEASE="-O2 -DNDEBUG" -DCMAKE_CXX_FLAGS_RELEASE="-O2 -DNDEBUG" \
        -DCMAKE_VERBOSE_MAKEFILE=OFF \
        -DREXSDK_DIR="$rexsdk" -DREXGLUE_HOST_TOOL="$rexglue" \
        -DREXGLUE_ENABLE_TRACY=OFF \
        -DFABLE2_PS5_VULKAN_DIR="$vulkan" -DFABLE2_PS5_TITLE_ID="$title_id" \
        -DFABLE2_PS5_DEBUG_HEAP="${FABLE2_PS5_DEBUG_HEAP:-OFF}"
}
configure
# Codegen writes generated/default/sources.cmake; configure again to compile it.
cmake --build "$build" --target fable_2_codegen
configure
cmake --build "$build" --target fable_2 ${BUILD_JOBS:+-j "$BUILD_JOBS"}
echo "title folder: $build/dist/$title_id"
if [[ -n $copy_to ]]; then
    dest=$copy_to/$title_id
    mkdir -p "$dest"
    # Everything but a config the player already has there.
    (cd "$build/dist/$title_id" && tar -cf - --exclude=./fable2_config.toml .) | tar -xf - -C "$dest"
    [[ -f $dest/fable2_config.toml ]] || cp "$build/dist/$title_id/fable2_config.toml" "$dest/"
    echo "copied to: $dest"
fi
echo "copy it to /data/homebrew/$title_id/, and the contents of game/ (default.xex, data/, nxeart) into that same folder (docs/PS5.md)"
