# Fable II on PS5: handoff notes

The state of the Fable 2 Recomp PS5 port as of 2026-11-03, written so another
person or AI can pick it up. It covers scope, where everything lives, how to
build, deploy and debug, what was fixed (with measurements), and what is open.
`docs/PS5.md` is the shorter user-facing build guide.

## 1. Scope

- **Goal:** run himdo's Fable 2 static recompilation (Xbox 360, on the ReXGlue
  SDK) natively on a jailbroken PS5 as a homebrew title. It follows the same
  approach as the owner's earlier ports, re:Blue (Blue Dragon, PPSA99213) and
  Lost Odyssey (PPSA99212).
- **Title:** ID `PPSA99214`, name "Fable II". It installs to
  `/data/homebrew/PPSA99214/` on the console.
- **Status:**
  - Boots, plays intro movies, takes controller input, and runs gameplay.
  - Normal gameplay holds about 29–30 fps (the game caps itself at 30).
  - The heaviest spot tested runs a steady 21–22 fps. Before this work it ran
    7–15 fps with 100–700 ms hitches. That spot is early Bowerstone (child
    section, "Follow the glowing trail", walking toward the crowd in the
    square).
- **Current focus:** performance in that spot. The emulated GPU's command
  thread is the bottleneck at about 95% busy, and the game's own main thread
  is also busy (the overlay showed 96%).

## 2. Repositories and branches

Use the Blue Dragon layout: PS5 work lives on a separate default branch, and
upstream stays untouched.

| Repo | Branch | Contents |
|---|---|---|
| `dragonscales123/Fable-2-RecompPS5` (fork of `himdo/Fable-2-Recomp`) | `ps5-port` (default) | All PS5 work. `master` = upstream. |
| `dragonscales123/rexglue-sdk-PS5` | `fable2-ps5` | The SDK this title uses: the PS5 SDK port with himdo's Fable 2 SDK changes merged in (merge `f3ce378`), plus everything below. Submodule `thirdparty/rexglue-sdk`. |
| same | `ps5-port` | **re:Blue's base. Do not modify.** |

When the SDK changes, commit and push to `fable2-ps5`. Then bump the fork's
gitlink (`thirdparty/rexglue-sdk`) on `ps5-port`.

Every commit message ends with these lines:

```
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01BFJw9rF4UDhasyFvbdjxS4
```

## 3. Toolchain and build

The owner builds on his PC in WSL. This is faster than a cloud container. He
says when a build is done, and the assistant uploads it to the console.

**Paths:**
- **WSL tree:** `~/Fable-2-RecompPS5`. It was moved out of the bluedragon
  folder on purpose; keep it separate.
- **Toolchain:** `~/bluedragon-ps5`, shared with re:Blue and Lost Odyssey.
  - Payload SDK: `~/bluedragon-ps5/PS5_VulkanTemplate/.deps/native/ps5-payload-sdk`
    (mihawk-99's PS5_PayloadSDK, clang 20, prospero-lld).
  - PS5_Vulkan with RADV, linked statically:
    `~/bluedragon-ps5/PS5_Vulkan/.deps/native/radv-release/lib/libvulkan_radeon.ps5.a`.
  - RADV is built by `PS5_Vulkan/tools/build-radv.sh release` from the Mesa
    fork at `~/bluedragon-ps5/PS5_Mesa`, pinned revision `47e9eb6`. That fork
    is not on GitHub; its PS5 winsys lives in `src/amd/vulkan/winsys/ps5/`.
- **Personal settings:** `ps5/build.local.sh` (git-ignored) sets `copy_to=`,
  `PS5_PAYLOAD_SDK=` and `PS5_VULKAN_DIR=`.

**Build command:**
```
cd ~/Fable-2-RecompPS5 && git pull && git submodule update --init thirdparty/rexglue-sdk && ps5/build.sh 2>&1 | tee build.log
```

**Build outputs** (`copy_to` is the OneDrive folder):
- Title folder: `C:\Users\drago\OneDrive\Desktop\Fable2RecompPS5\PPSA99214\`
  (`eboot.bin`, `sce_sys`, `sce_module/libc.prx`, Lua scripts, config).
- Unstripped ELF for symbolizing:
  `C:\Users\drago\OneDrive\Desktop\Fable2RecompPS5\symbols\fable_2.elf`.

**Build notes:**
- `ps5/build.sh` builds the host `rexglue` codegen tool first. It regenerates
  the recompiled C++ when rexglue or `fable_2_manifest.toml` changes; that
  takes about 3.5 minutes, then a full recompile.
- `ps5/link-title.sh` links with prospero-lld and makes the fake SELF with
  ps5-native-tool. It also:
  - Merges the large-code-model `.ltext/.lrodata/.ldata/.lbss` sections.
    Otherwise there are over 65,279 sections, which the converter cannot read.
  - Wraps `exit`, `_exit` and `_Exit` (a title must ask the shell to close).
  - Wraps `radv_ps5_sleep_us` (see 6.3).
  - Packages `libc.prx`.
  - Fails on null imports.
- Large code model: `-mcmodel=large`. VMA symbols are renamed `rexsdk_*` in
  the runtime and the Xenos GPU archive (`cmake/rex_ps5_isolate_vma.cmake`).
  The Xenos GPU is a static archive pulled in by a strong anchor
  (`src/ui/gpu_plugin_link_ps5.cpp`).

## 4. Deploying and the console's files

**Deploying:** the assistant uses the ps5-bridge tools (`ps5_upload`,
`ps5_list`, `ps5_download`, `ps5_read_text`, `ps5_klog`). The bridge's
relative paths default to Lost Odyssey's folder, so always pass absolute
`/data/homebrew/PPSA99214/...` paths. To deploy, upload `PPSA99214\eboot.bin`
to `/data/homebrew/PPSA99214/eboot.bin` with its sha256. The game files
(`default.xex`, `data/`, `nxeart`) are already on the console.

**Files the title writes** (`/app0` is the title folder):

| File | What it is |
|---|---|
| `logs/fable_2_NNN.log` | Runtime log, one per launch. Contains `[fps-meter]` lines every 5 s. |
| `boot.txt` | Startup breadcrumbs, env switches read, exit status. |
| `faults.txt` | First 200 faults the exception handler saw, plus every unhandled one with stack code addresses. |
| `profile.txt` | Sampling profiler output (when `REX_PROFILE=1`). |
| `cache/shaders/shareable/4D5307F1.xsh` and `4D5307F1.fbo.vk.xpso` | Persistent shader and pipeline cache. |
| `ps5-env.txt` | Runtime switches (next section). |

### ps5-env.txt (runtime switches, no rebuild needed)

Each line is `KEY=VALUE`, set as an environment variable before startup.
`REX_<CVAR>=value` overrides any SDK setting.

Current file on the console:
```
REX_LOG_FLUSH_INTERVAL=1        # flush log every second (a crash keeps its last lines)
FABLE2_FPS_METER=1              # [fps-meter] rate / worst frame every 5 s
REX_PROFILE=1                   # sampling profiler -> profile.txt (costs a little; turn off for play)
REX_SHARED_MEMORY_HOT_PAGES=true      # already the PS5 default in code
REX_CLEAR_MEMORY_PAGE_STATE=false     # already the PS5 default in code
REX_SHOW_DEBUG_OVERLAY=true     # performance overlay at startup; L3+R3 toggles
```

Other switches:
- `REX_VSYNC=0` uncaps the frame rate. Tested: the slow stretches are real
  work, not vsync steps.
- `FABLE2_RADV_WAIT_US` sets how long the RADV GPU wait sleeps between polls
  (default 100; 0 = yield).
- `REX_PROFILE_HZ` and `REX_PROFILE_INTERVAL` tune the profiler.
- `REX_DIAG_LOAD_PROFILE=true` logs guest-thread sleeps, waits and yields each
  second (`[load-prof]`).
- `FABLE2_XAM_TRACE=1`.
- Build option `FABLE2_PS5_DEBUG_HEAP=ON` enables the checking allocator.

## 5. Debugging tools built for this port

- **Symbolizing:** the load base is `0x400000`. `profile.txt` and fault
  offsets are already `rip - 0x400000` (raw rips in `faults.txt` need the
  subtraction). Symbolize against the matching `symbols/fable_2.elf`:
  `llvm-symbolizer-20 --obj=fable_2.elf --functions=linkage <offsets>`.
- **Sampling profiler:** `src/core/ps5_profiler.cpp`, enabled with
  `REX_PROFILE=1`.
  - Every registered thread is interrupted with SIGPROF (about 250 Hz per
    thread) and its rip is recorded.
  - Every 10 s, `profile.txt` gets one entry per busy thread:
    - `thread "<name>" samples= in-title= outside=` and the hottest offsets.
    - `o` lines: raw rips outside the title (libc or kernel).
    - `c` and `k` lines: the title caller, and a 6-deep call chain (from a
      stack scan) for library and system-call samples.
  - A `counters/s:` line gives `mprotect` calls, invalidations by cause,
    GPU-written bytes, uploads, and hot-page bytes.
  - The stack scan is bounded by the thread's stack top, from
    `pthread_attr_get_np`.
- **Performance overlay:** the F3 debug overlay, extended for PS5
  (`src/ui/overlay/debug_overlay.cpp`).
  - Shows guest FPS; GPU-emulation, render and game thread load; GPU upload
    MB/s; write faults and protects per second; direct and flexible memory.
  - L3 + R3 toggles it (`include/rex/input/overlay_combo.h`).
    `show_debug_overlay` opens it at startup. Text scales with screen height.
  - Thread load comes from signalling the thread (SIGPROF), whose handler reads
    its own `CLOCK_THREAD_CPUTIME_ID`. On the PS5, `pthread_getcpuclockid`
    returns the caller's clock, so a thread's CPU time cannot be read from
    another thread.
  - The first try published CPU time from hot paths. It cost about 25% of the
    frame rate and missed the render thread.
  - **The signal-based version (fork `713e124`, SDK `4444d81`) is pushed but
    not yet tested on the console.**
- **Crash tooling:**
  - `boot.txt` breadcrumbs.
  - `faults.txt` fault log with stack code addresses.
  - Unhandled faults are chained to the previous handler.
  - Checking heap (`FABLE2_PS5_DEBUG_HEAP`).

## 6. What was fixed

### 6.1 Getting it to build, boot and run

- **SDK on PS5:** an SDL Vulkan surface; Vulkan instance through
  `vk_icdGetInstanceProcAddr` with `VK_KHR_display`; the Xenos GPU as a static
  archive with VMA renames.
- **Codegen naming:** codegen renamed `fable_2` to `fable2` (`parse_app_name`);
  fixed. The libmspack submodule check failed on a clean checkout; fixed.
- **Link:** merged the section overflow; anchored `rex_gpu_create`.
- **Controller mappings:** `gamecontrollerdb.txt` is found in the title
  folder.
- **4× game speed:** the host tick frequency is 1 GHz on non-Apple POSIX
  (`clock_posix.cpp`).
- **Crash at the Microsoft logo:** heap damage at guest thread exit.
  - The setjmp map moved behind a `thread_local` pointer (emulated TLS cannot
    run a non-trivial destructor at thread exit).
  - Guest threads end by longjmp-ing back to the thread start, not with
    `pthread_exit`, whose unwinding ran destructors on freed objects.
- **XAM trace:** made thread-safe. (It crashed when it wasn't.)

### 6.2 Performance at the heavy spot

| Step | Result there |
|---|---|
| Start | 7–15 fps, 100–700 ms hitches, every pipeline recompiled each run |
| Pipeline cache persists (SDK `416804e`). Pipeline records were read by exact count, so the stream never hit EOF and every later `fwrite` failed silently on the PS5 libc; it now seeks to EOF first | hitches drop on second runs; fps unchanged |
| Type-0 register packets written as one range (`47f3bcb`) | ~16–18 fps |
| **`skip_msr` actually applied** (fork `4e2bd8b`). Codegen reads its flags from `[entrypoint]`; himdo's `skip_msr = true` sat inside the last `[[entrypoint.midasm_hook]]` table, so every `mtmsrd r13` took the SDK global lock (25,248 sites). The render thread took it tens of thousands of times a second and the GPU thread spent ~1/3 of its time waiting | first slow part 16→25 fps; worst stretch steady 17.6 fps, hitches gone |
| Hot pages, byte-precise checks (`0bcf602`, `75fec27`, `378efcf`) | 17.6 → 20.6 |
| RADV wait sleeps 1 ms → 100 µs (fork `f9c1d77`) | no measurable change, kept |
| `clear_memory_page_state` off on PS5 (`e974e93`). It marked every CPU-uploaded page stale each frame (~330 MB/s of re-uploads) | 20.7 → 21.5 with hot pages on |
| Texture descriptor-set reuse within a frame (`1a6d37d`) | no change; most descriptor work is constant buffers |

**Hot pages** (`shared_memory_hot_pages`, on by default on PS5):
- Pages the CPU keeps rewriting after the GPU reads them are no longer
  write-watched. A write fault plus re-protection costs two `mprotect` calls
  with TLB shootdowns, and 16 KiB host pages make false sharing worse.
- Instead, each request compares the requested bytes with a CPU-side shadow of
  the last upload, and uploads only if they changed.
- Pages under a texture watch are watched again.
- First version bug: textures request their range before they watch it, so
  movie frames went unwatched and the intro movie was black. Fixed.
- The hot set resets every 300 frames.

**Setting combinations measured** (all with the movie and visuals correct
unless noted):

| Hot pages | `clear_memory_page_state` | fps | Notes |
|---|---|---|---|
| off | on | 20.7 | ~350 MB/s re-uploads |
| off | off | 19.8 | ~6,400 mprotect/s |
| on | off | 21.5 | ~1,500 mprotect/s; current default |
| on, first version | off | 23.7 | broke movies |

## 7. Current profile of the heavy spot (GPU command thread)

- **Per-draw work:** about 68%, spread thin. The largest items are
  `UpdateBindings` (~5%) and `radv_UpdateDescriptorSets` (~4%). After that:
  texture-cache lookups, `copy_and_swap`, register writes and
  `ac_set_buf_desc_word3`.
- **Hot-page byte comparisons:** ~9% (the `memcmp` is in libc).
- **RADV GPU-wait polling:** ~7%.
- **mprotect:** ~3%.
- **The render thread ("3D Engine")** spins in `GpuProgressCheck` and
  `FrameLimiterWait` waiting for the GPU thread. Any time saved on the GPU
  thread becomes frame rate.

## 8. Open items, next steps

1. **Test the signal-based overlay thread loads** (`713e124`). Expect about
   21–22 fps again, and real loads for all three threads.
2. **Dynamic uniform buffers for the constants descriptor set**, the likely
   next win (~5%).
   - Today, every draw whose constants change allocates and writes a new set
     of 5 `UNIFORM_BUFFER` descriptors.
   - Use `UNIFORM_BUFFER_DYNAMIC` in `descriptor_set_layout_constants_`, write
     one set per uniform-buffer-pool buffer, and pass offsets in
     `vkCmdBindDescriptorSets`.
   - The SPIR-V does not change.
3. **Cheaper hot-page checks** (~9%). For example, compare a hash or checksum
   of the requested bytes, or only re-check pages whose block faulted
   recently.
4. **The game's main thread is busy too** (the overlay showed 96%, not yet
   cross-checked). If the GPU thread gets faster, the game thread may become
   the limit. Profile `GameThread` then.
5. RADV GPU-wait polling is ~7%. It is mostly real GPU work; changing it
   further needs the Mesa fork.
6. Clean-up before any release:
   - Turn off `REX_PROFILE`; keep the fps meter optional.
   - Consider making `REX_SHOW_DEBUG_OVERLAY` off by default (it already is in
     code).
7. Ideas not tried:
   - Regenerating hotfunc overrides for the PS5 codegen (`FABLE2_HOTFUNCS` is
     OFF on PS5).
   - Uncapping with `REX_VSYNC=0` once 30 fps holds.

## 9. Gotchas learned

- **TOML:** keys after a `[[table]]` header belong to that table entry. Codegen
  flags must sit in `[entrypoint]`, before the first `[[entrypoint.*]]`.
- **The PS5 libc is strict about stdio:** on a `+` stream, a write after a
  read needs a seek first, or every write fails silently.
- **PS5 host pages are 16 KiB** (guest pages are 4 KiB):
  - `mprotect` is expensive.
  - Write-watch false sharing is 4× worse.
  - Invalidation widening covers up to 1 MB.
  - Heap operations take the global lock (`AcquireHostPageReconcileLock`).
- **Threads:** emulated TLS (`-femulated-tls`) cannot run non-trivial
  `thread_local` destructors at thread exit. Don't use `pthread_exit` for
  guest threads.
- **SIGPROF** (profiler and overlay) interrupts syscalls. The handler must
  preserve `errno` and must not read past a thread's stack top.
- **Thread CPU time:** `pthread_getcpuclockid` returns the caller's clock on
  the PS5. Use the signal approach.
- **Frame rate steps:** the game paces on 60 Hz vblanks, so capped frame rates
  step at 30/15/10/7.5. Uncap with `REX_VSYNC=0` to see the true cost.
- **Shader cache:** Fable's 4D5307F1 cache needs a play-through per area to
  fill. It persists now.
- **The ps5-bridge `newest-log`** resolves to Lost Odyssey's folder. List
  `/data/homebrew/PPSA99214/logs` instead.

## 10. Key files

| Area | Fork (`Fable-2-RecompPS5`) | SDK (`rexglue-sdk-PS5`, `fable2-ps5`) |
|---|---|---|
| Build and packaging | `ps5/build.sh`, `ps5/link-title.sh`, `cmake/Fable2Ps5.cmake`, `ps5/ps5-env.example.txt`, `ps5/sce_sys/` | `cmake/rexglue_helpers.cmake`, `cmake/rex_ps5_isolate_vma.cmake` |
| Title start, exit, libc | `src/platform/ps5_title.cpp`, `ps5_libc.cpp`, `ps5_debug_heap.cpp`, `ps5_radv_wait.cpp` | `src/core/threading_posix.cpp`, `exception_handler_posix.cpp`, `clock_posix.cpp`, `memory_ps5.cpp` |
| Codegen config | `fable_2_manifest.toml` (`skip_msr` in `[entrypoint]`) | `src/codegen/` |
| GPU emulation | | `src/graphics/command_processor.cpp`, `shared_memory.cpp`, `vulkan/command_processor.cpp`, `vulkan/pipeline_cache.cpp`, `vulkan/shared_memory.cpp` |
| Diagnostics | `src/diagnostics/fps_meter.h` | `src/core/ps5_profiler.{h,cpp}`, `src/ui/overlay/debug_overlay.cpp`, `src/input/input_system.cpp` (L3+R3) |
