# F022 swap-fence UAF — v1.3 exploration harness

Explores the live IOMobileFramebufferUserClient calling convention, reaches `swap_apply_fences_gated`,
and triggers **close-after-fence-registration** on macOS **26.5.1 / 25F80 / MacBookPro18,2 / M1 Max**.
This is an **exploration harness with a trigger mode**, not a brittle proof harness.

## Build & run (on the M1 Max box only)
```sh
clang -O0 -g -fobjc-arc -framework IOKit -framework CoreFoundation -framework IOSurface \
      -o f022_harness f022_harness.m

./f022_harness --probe              # diagnostics only, never gates
./f022_harness --trigger --iters 1  # default: default/displayed framebuffer surface, then close
./f022_harness --trigger --mutate   # add the narrow geometry-rect fallback if STAGE3 persists
./f022_harness --trigger --generic-surface # old IOSurfaceCreate path; expected to hit STAGE3.5 here
./f022_harness --trigger --surface-id 23   # manual surface-id override
./f022_harness                      # probe then trigger (default)
```
**Do not run until authorized.** A landed trigger is expected to **panic** on a release kernel (UAF on
the `IOMFBSwapIORequest_ktv` zone, or a PAC / `brk #0xbffd` list-guard fault on the async IOSurfaceRoot
workloop). Prefer a **dev/KASAN kernel** for clean attribution. Never run on a box you can't reboot.

## Operating rules (the lead is decided by the kexts, not by harness friction)
- `--probe` is **diagnostic, not a kill gate**.
- Every failure prints the exact failing call, selector, args size, `kern_return_t`, and partial IDs
  (swap id, surface id, connection handle).
- Helper/public path first, then the **lower-level direct IOConnect path** before calling anything blocked.
- A selector/struct-size rejection (`0xe00002c2 kIOReturnBadArgument`) is recorded as **LAYOUT MISMATCH**,
  not "not reachable."
- UC open failing as a sandboxed app → **re-run unsandboxed** to separate sandbox reachability from
  kernel-bug existence. Sandboxed run: launch from inside your sandbox container / a sandboxed app
  bundle. Unsandboxed run: plain `./f022_harness` from a shell (root not required to *open*; `sudo`
  only if a type needs it — the harness reports `NotPermitted` per type).
- swap_submit failing validation → **mutate toward valid stock shapes** (the harness already loops
  candidate layer-slot offsets; widen as needed), never stop on first failure.
- **Only kill the lead on a structural contradiction already seen in the kexts** — e.g. a per-fence
  retain of the request, a synchronous fence drain in `abort_swap_gated`, or a liveness guard in
  `io_fence_notify_gated`. The static pre-check (`F022-26.5.1-m1max-structural-precheck-20260613.md`)
  found none → GO. Runtime stalls are engineering blockers.

## Static ground truth seeded into the harness (26.5.1)
- Dispatch table `0xfffffe00084c4258`, 24-byte entries, max selector `0x5c`.
- `default_fb_surface` = sel **3** (scalarIn=2, scalarOut=1, framebuffer-owned IOSurface ID);
  `swap_start` = sel **4** (scalarOut=1, the swap id); `swap_submit` = sel **5** (structIn **1416** =
  `IOMFBSwapRec`); `get_display_size` = 8; `swap_wait` = 6; `swap_signal` = 20; `swap_cancel` = 52;
  `displayed_fb_surface` = **83** (scalarIn=1, scalarOut=1, entitlement/runtime-gated).

### v1.1 — `IOMFBSwapRec` field map (reversed; no longer guessed)
From `swap_submit` @`0xa950c20` (per-layer loop `k=0..3`) and `swap_queue_finalize_gated` @`0xa9520bc`:

| IOMFBSwapRec | → request | meaning |
|---|---|---|
| `+0x98` u32 | (lookup key) | swap id — must equal `swap_start` scalarOut[0] |
| `+0x14c` u32 | `+0x338` | layer-enable bitmask; **bit k enables layer k** |
| `+0x9c + k*4` u32 | `+0xac0 + k*8` | layer-k **surface id** → `IOSurfaceRoot::lookupSurface(id, current_task)` |
| `+0x17c` u32 | — | `==9` ⇒ kernel surface; **`!=9` ⇒ lookupSurface path** (use 0) |
| `+0xac + k*16` 16B | `+0x11 + k*16` | per-layer src/cfg block |
| `+0x10c + k*16` 16B | `+0x51 + k*16` | per-layer dst block |
| `+0xec/0xfc/0x15c + k*…` | `+0x214/0x258/0x268` | per-layer u32 / float / 3-bit fields |

**`verify_swap` and `verify_swap_surfaces` are no-op stubs** on this build (`return 0` / `return 1`).
The real gates before `swap_apply_fences_gated` are, in order: `req+0x57a`(abort)`==0`; request on the
`+0x17a8` queued list with matching id; `check_passthrough_swap_gated` (passes with **≤1** future-
state-3 layer); `verifyKeepOnScreen_gated` (passes with default `req+0x34c==0 && req+0x580==0`);
`vtable+0xe48`. Then `queue_move_entry_gated` moves the request to the **`+0x1798` started list** —
exactly what `abort_swaps_gated` walks at teardown.

### Deterministic record (default trigger)
`build_swap_rec_v11()` emits **one fullscreen passthrough layer (layer 0)**: enable mask `0x1`,
surface id at `+0x9c`, mode `0`, src/dst rects `{0,0,w,h}`. This is the minimum that reaches
`swap_apply_fences_gated` and registers a fence with `ctx2 = raw IOMFBSwapIORequest`. It is
**known-good-ish**, not a broad mutator. `--mutate` adds a *narrow* fallback that sweeps only the two
16-byte rect encodings if a finalize gate rejects (STAGE3).

### Staged classifier (every submit prints its stage)
The harness maps the `swap_submit` return code to a pipeline stage so a failure says *where* it
stopped, not just "failed":

| code | stage |
|---|---|
| `0x00000000` | **STAGE4** request created+queued+**fences applied**+moved to started list → close triggers teardown-after-fence |
| `0xe00002bc` | STAGE1 rejected at/before request creation (rec null / id mismatch) |
| `0xe00002eb` | STAGE2 created but not queued (abort flag / not on `+0x17a8`) |
| `0xe00002c2` | STAGE3 queued but **no fences** (a finalize gate rejected — refine geometry) |
| `0xe00002d1` | **STAGE3.5** surface lookup OK and `swap_layer_map` reached, but generic `surface_map` rejected display DMA binding. Use `default_fb_surface` / display-compatible backing. |
| other | STAGE? likely surface lookup failed (bad id → `req+0xac0` null → fence skipped) |

Codes are derived from `swap_queue_finalize_gated`; `swap_submit` may wrap them, so the classifier
prints the raw code too and the live run pins the mapping. STAGE4 is the goal of v1.3.

## What v1.3 must establish (in order; the staged classifier reports each)
1. **UC open** works (record type id + sandbox result).
2. **swap_start** dispatches → swap id (externalMethod path live).
3. **swap_submit** with the deterministic single-layer record reaches **STAGE4** (kr `0`): request
   created → queued → `swap_apply_fences_gated` → `createFence` (ctx2 = raw `IOMFBSwapIORequest`) →
   moved to the `+0x1798` started list. If it lands earlier, the stage line says which precondition
   is missing (surface lookup / queueing / a finalize gate); refine and re-run (or `--mutate`).
4. **close while in-flight** → teardown releases the request; the async fence callback runs against
   freed memory. Watch for UAF/panic; stack should show
   `fence_completed_dispatch → io_fence_callback → io_fence_notify_gated`.

If STAGE4 is reached but no panic, the fence self-completed before teardown (producer not truly
outstanding): raise `--iters`, add layers, or make the producer genuinely pending. With a default
framebuffer surface, the next step is the swap rec's explicit wait-fence field, only needed if STAGE4
lands but the race never does.

## v1.2/v1.3 update after first live triggers
The first M1 Max trigger with a generic 64x64 `IOSurfaceCreate` surface reached `swap_layer_map` but
returned `0xe00002d1`. Static path match: `swap_layer_map` called `surface_map`, and `surface_map`
failed while setting the `IODMACommand` memory descriptor for display scanout. That is a surface
backing/DART compatibility miss, not a record parser miss and not a bug kill.

v1.2 therefore tried selector **3** `default_fb_surface`, which is not entitlement-gated and returns
the framebuffer-owned IOSurface ID when `fb+0x1868` already exists. On this M1 Max, selector 3
returned `0xe00002bc`: the default surface pointer is null, so the wrapper reports NotReady. That is
a host-state surface-source precondition, not a contradiction.

v1.3 tries selector **83** `displayed_fb_surface(layer 0)` after selector 3 before stopping. If both
exported framebuffer-owned surface paths fail, the harness no longer auto-falls back to generic
`IOSurfaceCreate`; use `--generic-surface` only as a control for the known STAGE3.5 failure bucket.
When a framebuffer-owned/default surface ID is available, `swap_layer_map` special-cases that surface
(`surface == fb+0x1868`) and bypasses `surface_map`, copying the framebuffer's existing mappings
instead.

## The prompt for the repro agent
> Do not treat a failed first attempt as a negative finding. Instrument every return code and keep
> adapting until we know which precondition is missing. The goal of v1.3 is to map the live calling
> convention and reach `swap_apply_fences_gated`, then trigger close-after-fence-registration. Only the
> static structural chain decides bug viability; runtime harness failures are engineering blockers
> unless they prove a kernel-side invariant (a per-fence request retain, a synchronous fence drain in
> `abort_swap_gated`, or a liveness guard in `io_fence_notify_gated`). Record selector/struct-size
> rejections as "layout mismatch," not "not reachable." If UC open fails sandboxed, re-run unsandboxed
> to separate sandbox reachability from kernel-bug existence.

## Known gaps (engineering, not viability)
- **Geometry rect field order** inside the two 16-byte blocks is the one "known-good-ish" assumption
  ({x,y,w,h} as 4×u32). If STAGE3 persists, `--mutate` sweeps the encodings; the surface-id/enable
  mapping is exact and not assumed.
- `vtable+0xe48` (the third finalize gate) is named-by-offset but its body isn't reversed; it passes
  for a minimal present by the pattern of the other two. If STAGE3 persists after `--mutate`, reverse
  it next.
- Direct-path fallbacks (surface create via `IOSurfaceRootUserClient`, UC-open type widening) remain
  TODO stubs — add only if `--probe` shows the helper path is actually blocked (the operator's call).
- **Next if a framebuffer-owned/displayed surface reaches STAGE4 but no panic:** set the swap rec's
  explicit producer/wait-fence field to a never-signaled shared-event value for a deterministic pending fence.
