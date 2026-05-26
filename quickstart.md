# Quickstart

Clone anywhere. By default output goes next to the repo:

```text
<workspace>/applesauce
<workspace>/artifacts
```

For static Mach-O reverse-engineering helpers, see `static-re.md`.
For binary unit triage (emit → rank → packet), see `static-sequela.md`.

## Host State

Run once after booting the target OS:

```zsh
cd /path/to/applesauce
git pull
./tools/collect_campaign1_host_state.sh
```

## LaunchServices Stock Gate

On Tahoe 26.3:

```zsh
cd /path/to/applesauce
./tools/run_campaign1_stock_gate.sh background
```

## Force-Quit Gate

Run once on Tahoe 26.3 and once on Tahoe 26.4:

```zsh
cd /path/to/applesauce
git pull
./tools/run_campaign1_forcequit_gate.sh background
```

When prompted, force quit `LSStaleParent` from Dock or Apple menu > Force Quit.

Optional loaded-job variant:

```zsh
./tools/run_campaign1_forcequit_gate.sh pidjob
```

## Dyld Member Extraction

On Tahoe 26.3:

```zsh
cd /path/to/applesauce
git pull
./tools/collect_campaign1_dyld_members.sh 26.3 /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e
ls -l /usr/lib/libLaunchServicesSupport.dylib
file /usr/lib/libLaunchServicesSupport.dylib
```

On Tahoe 26.4:

```zsh
cd /path/to/applesauce
git pull
./tools/collect_campaign1_dyld_members.sh 26.4 /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e
ls -l /usr/lib/libLaunchServicesSupport.dylib
file /usr/lib/libLaunchServicesSupport.dylib
```

Main output:

```text
<workspace>/artifacts/dyld-members/<label>/selected/usr/lib/libLaunchServicesSupport.dylib
```

The dyld fallback extracts the full cache first, so expect time and disk use.

Send only:

```text
<workspace>/artifacts/dyld-members/26.3/metadata/
<workspace>/artifacts/dyld-members/26.3/selected/
<workspace>/artifacts/dyld-members/26.4/metadata/
<workspace>/artifacts/dyld-members/26.4/selected/
```

Do not send:

```text
full-extract/
members/
```

## Packet 004 FileProvider

On current Tahoe 26.5:

```zsh
cd /path/to/applesauce
git pull
./tools/collect_packet004_fileprovider_artifacts.sh 26.5 /
./tools/collect_packet004_dyld_members.sh 26.5 /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e
```

On Tahoe 26.4, if booted into it:

```zsh
cd /path/to/applesauce
git pull
./tools/collect_packet004_fileprovider_artifacts.sh 26.4 /
./tools/collect_packet004_dyld_members.sh 26.4 /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e
```

If 26.4 is only mounted from another boot, pass the mounted system root for
standalone artifacts and point the dyld script at the full 26.4
`dyld_shared_cache_arm64e` path you copied or mounted:

```zsh
./tools/collect_packet004_fileprovider_artifacts.sh 26.4 /Volumes/Tahoe-26.4
./tools/collect_packet004_dyld_members.sh 26.4 /path/to/26.4/dyld_shared_cache_arm64e
```

Send only:

```text
<workspace>/artifacts/packet004-fileprovider/26.4/metadata/
<workspace>/artifacts/packet004-fileprovider/26.4/analysis/
<workspace>/artifacts/packet004-fileprovider/26.4/standalone/
<workspace>/artifacts/packet004-fileprovider/26.5/metadata/
<workspace>/artifacts/packet004-fileprovider/26.5/analysis/
<workspace>/artifacts/packet004-fileprovider/26.5/standalone/
<workspace>/artifacts/dyld-members-packet004/26.4/metadata/
<workspace>/artifacts/dyld-members-packet004/26.4/selected/
<workspace>/artifacts/dyld-members-packet004/26.5/metadata/
<workspace>/artifacts/dyld-members-packet004/26.5/selected/
```

Do not send Packet 004 dyld:

```text
full-extract/
members/
```

The Packet 004 dyld script removes fallback `full-extract/` by default after
copying the selected members. Set `APPLESAUCE_KEEP_FULL_EXTRACT=1` only if you
explicitly need the complete extraction tree.

## Packet 004 Extend-Sandbox Gate

Run from a normal Terminal, not from inside Codex's sandbox.

First check daemon route visibility:

```zsh
cd /path/to/applesauce
git pull
./tools/run_packet004_extend_sandbox_gate.sh list
```

Helper-only sanity check:

```zsh
./tools/run_packet004_extend_sandbox_gate.sh wrapper /path/to/test-file readonly 1
```

Direct broker gate:

```zsh
./tools/run_packet004_extend_sandbox_gate.sh extend /path/to/fileprovider-domain-item com.apple.CloudDocs.iCloudDriveFileProvider com.apple.finder 1
```

Use a quoted absolute local path when possible. The probe accepts local paths and
local `file://` URLs only; non-file URLs and non-local file URL hosts are
rejected before any daemon call.

Promote to race testing only if `extend` reaches the daemon path and returns a
wrapper or gets past entitlement/provider/domain checks. If it is denied before
wrapper creation, keep Packet 004 as a static primitive and pivot to import/move
wrappers or the deletion/revival lane.

## Packet 004 Import/Move Gate

Run from a normal Terminal.

```zsh
cd /path/to/applesauce
git pull
./tools/run_packet004_import_move_gate.sh all
./tools/run_packet004_import_move_gate.sh finder-all
```

Default target:

```text
~/Library/Mobile Documents/com~apple~CloudDocs/Packet004ImportMoveGate
```

Useful single-mode reruns:

```zsh
./tools/run_packet004_import_move_gate.sh finder-copy
./tools/run_packet004_import_move_gate.sh finder-move
```

Promote only if the run shows operation-attributable
`FPDMoveWriterToProvider`, `_importURL`, `FPSandboxingURLWrapper`,
`wrapperWithURL`, or `fp_issueSandboxExtension` activity. Successful file
copy/move by itself is not enough.

Fast triage files in each run directory:

```text
target-writer-helper-hits.txt
sibling-provider-hits.txt
```

`target-writer-helper-hits.txt` is the promotion signal. The sibling file is
useful context for CloudDocs/Finder scoped URL paths, but it is not enough to
start race testing. These two files are generated from the live log stream for
the current run; use `log-show-fileprovider.txt` only as backfill context.

## Packet 004 ImportDomain Gate

Run from a normal Terminal on Tahoe 26.4 and Tahoe 26.5:

```zsh
cd /path/to/applesauce
git pull
./tools/run_packet004_importdomain_gate.sh normal
./tools/run_packet004_importdomain_gate.sh symlink-leaf
```

If a 26.4 run reports `ProviderNotRegistered`, rerun the two-mode matrix with
the temporary PlugInKit registration kept across both runs:

```zsh
PACKET004_KEEP_PLUGIN=1 PACKET004_IMPORTDOMAIN_PREFLIGHT_SLEEP=3 ./tools/run_packet004_importdomain_gate.sh normal
PACKET004_KEEP_PLUGIN=1 PACKET004_IMPORTDOMAIN_PREFLIGHT_SLEEP=3 ./tools/run_packet004_importdomain_gate.sh symlink-leaf
/usr/bin/pluginkit -r "$(pwd)/harnesses/packet004-importdomain/build/Packet004ImportDomainHarness.app/Contents/PlugIns/Packet004FileProviderExtension.appex"
```

Optional local swap loop, confined to the run directory:

```zsh
./tools/run_packet004_importdomain_gate.sh race
```

The runner builds a minimal app bundle with an embedded
`com.apple.fileprovider-nonui` extension, then invokes
`+[NSFileProviderManager importDomain:fromDirectoryAtURL:completionHandler:]`
from the app executable. Output goes to:

```text
<workspace>/artifacts/runtime/packet004-importdomain/
```

Fast triage files in each run directory:

```text
app.stdout.txt
app.stderr.txt
caller-probe-hits.txt
daemon-log-hits.txt
manual-lldb-breakpoints.txt
environment/registration-summary.txt
```

`caller-probe-hits.txt` is generated from the app process. `probe.hit` lines for
`FPSandboxingURLWrapper` or
`fp_issueSandboxExtensionOfClass:report:error:` are the caller-side reachability
signal. Compare 26.4 and 26.5 path/rejection behavior before promoting anything;
provider registration, UI setup, or daemon rejection alone is not a vulnerability
claim.

The runner removes the temporary `packet004.*` FileProvider domain after the
call by default. Set `PACKET004_KEEP_DOMAIN=1` only when you intentionally want
to inspect the registered domain after the run. It also unregisters the
temporary FileProvider extension from PlugInKit by default; set
`PACKET004_KEEP_PLUGIN=1` only when you need to inspect PlugInKit state after
the run.

## Packet 002 Accounts Privacy

Run from a normal Terminal. This is collection only, not a runtime probe.

On current Tahoe 26.5:

```zsh
cd /path/to/applesauce
git pull
./tools/collect_packet002_accounts_artifacts.sh 26.5 /
./tools/collect_packet002_dyld_members.sh 26.5 /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e
```

On Tahoe 26.4, if booted into it:

```zsh
cd /path/to/applesauce
git pull
./tools/collect_packet002_accounts_artifacts.sh 26.4 /
./tools/collect_packet002_dyld_members.sh 26.4 /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e
```

If 26.4 is only mounted from another boot:

```zsh
./tools/collect_packet002_accounts_artifacts.sh 26.4 /Volumes/Tahoe-26.4-Reacquire
./tools/collect_packet002_dyld_members.sh 26.4 /path/to/26.4/dyld_shared_cache_arm64e
```

The dyld script prefers `ipsw` when installed (`brew install blacktop/tap/ipsw`),
extracting each member with `--objc --stubs` for richer symbol coverage. Fallback
order: `dyld_shared_cache_util` → `dsc_extractor` → `dsc_extract_bundle` (full-cache
expand). `metadata/extractor.txt` records which extractor ran and its version.

Send only:

```text
<workspace>/artifacts/packet002-accounts-privacy/26.4/
<workspace>/artifacts/packet002-accounts-privacy/26.5/
<workspace>/artifacts/dyld-members-packet002/26.4/metadata/
<workspace>/artifacts/dyld-members-packet002/26.4/selected/
<workspace>/artifacts/dyld-members-packet002/26.5/metadata/
<workspace>/artifacts/dyld-members-packet002/26.5/selected/
```

Do not send Packet 002 dyld:

```text
full-extract/
members/
```

After both labels are present:

```zsh
./tools/diff_packet002_binary_truth.sh 26.4 26.5
```

## Authority Maps

`reverse_authority_map.sh` builds a deterministic authority surface map for any
Mach-O binary or bundle: imports, symbols, filtered strings (audit-token, XPC,
entitlements, TCC, sandbox extension, bookmark/security-scoped APIs), ObjC
metadata, and Swift demangled symbols.

Run on a single binary:

```zsh
./tools/reverse_authority_map.sh \
  artifacts/packet002-accounts-privacy/26.5/standalone/System/Library/PrivateFrameworks/AuthKit.framework/Versions/A/Support/akd \
  /tmp/akd-authority
```

Run on all Packet 002 standalone and selected dyld binaries for a label (after
artifact collection):

```zsh
./tools/collect_packet002_authority_maps.sh 26.4
./tools/collect_packet002_authority_maps.sh 26.5
```

Output goes to:

```text
<workspace>/artifacts/packet002-accounts-privacy/<label>/analysis/authority-maps/standalone/<binary-safe-name>/
<workspace>/artifacts/packet002-accounts-privacy/<label>/analysis/authority-maps/dyld-selected/<binary-safe-name>/
```

Key files per binary:

```text
identity.txt            - file type, sha256
imports.txt             - otool -L
symbols-nm.txt          - nm -m
strings-authority.txt   - filtered for audit-token, XPC, sandbox, bookmark APIs
objc-metadata.txt       - otool -ov ObjC section
swift-demangled.txt     - demangled Swift symbols
sandbox-profile-refs.txt
launchd-refs.txt
```

## Packet 006 Sandbox Protected Data

Run from a normal Terminal. This is collection only, not a runtime probe.

The release manifest hashes a broad system slice. It can take several minutes.
The script prints per-root progress. For a fast metadata-only manifest, prefix
the command with `APPLESAUCE_MANIFEST_HASH=0`; use full hash mode for the final
comparison.

On current Tahoe 26.5:

```zsh
cd /path/to/applesauce
git pull
./tools/collect_release_file_manifest.sh 26.5 /
./tools/collect_packet006_sandbox_artifacts.sh 26.5 /
./tools/collect_packet006_dyld_members.sh 26.5 /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e
```

On Tahoe 26.4, if booted into it:

```zsh
cd /path/to/applesauce
git pull
./tools/collect_release_file_manifest.sh 26.4 /
./tools/collect_packet006_sandbox_artifacts.sh 26.4 /
./tools/collect_packet006_dyld_members.sh 26.4 /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e
```

If you already ran the 26.4 collector before the ScopedBookmarkAgent review,
rerun at least this after `git pull`; the focused list now includes the changed
feature flags and helper/XPC surfaces found by the broad manifest:

```zsh
./tools/collect_packet006_sandbox_artifacts.sh 26.4 /
```

If 26.4 is only mounted from another boot:

```zsh
./tools/collect_release_file_manifest.sh 26.4 /Volumes/Tahoe-26.4
./tools/collect_packet006_sandbox_artifacts.sh 26.4 /Volumes/Tahoe-26.4
./tools/collect_packet006_dyld_members.sh 26.4 /path/to/26.4/dyld_shared_cache_arm64e
```

Send only:

```text
<workspace>/artifacts/packet006-sandbox-protected-data/26.4/
<workspace>/artifacts/packet006-sandbox-protected-data/26.5/
<workspace>/artifacts/release-manifests/26.4/
<workspace>/artifacts/release-manifests/26.5/
<workspace>/artifacts/dyld-members-packet006/26.4/metadata/
<workspace>/artifacts/dyld-members-packet006/26.4/selected/
<workspace>/artifacts/dyld-members-packet006/26.5/metadata/
<workspace>/artifacts/dyld-members-packet006/26.5/selected/
```

Do not send Packet 006 dyld:

```text
full-extract/
members/
```

The dyld script removes fallback `full-extract/` by default after selecting the
requested members.

After both labels are present:

```zsh
./tools/diff_release_file_manifests.sh 26.4 26.5
./tools/diff_packet006_binary_truth.sh 26.4 26.5
```

Main output:

```text
<workspace>/artifacts/packet006-sandbox-protected-data/diff-26.4-vs-26.5/summary.md
<workspace>/artifacts/packet006-sandbox-protected-data/diff-26.4-vs-26.5/trees/*.tsv
<workspace>/artifacts/release-manifests/diff-26.4-vs-26.5/summary.md
<workspace>/artifacts/release-manifests/diff-26.4-vs-26.5/changed-added-removed.tsv
```

### Packet 006 ScopedBookmark Runtime Gate

Run only after the `ScopedBookmarkAgent` reverse report says to do the bounded
runtime check. This uses controlled files and the public security-scoped
bookmark API; it is not a protected-folder probe.

On each build, start with controls:

```zsh
./tools/run_packet006_scopedbookmark_gate.sh stable
./tools/run_packet006_scopedbookmark_gate.sh sandbox-no-bookmark
```

Then run one race mode at a time:

```zsh
./tools/run_packet006_scopedbookmark_gate.sh symlink-race
./tools/run_packet006_scopedbookmark_gate.sh dir-race
```

Optional knobs:

```zsh
PACKET006_SCOPEDBOOKMARK_ITERATIONS=2000 ./tools/run_packet006_scopedbookmark_gate.sh symlink-race
PACKET006_SCOPEDBOOKMARK_RACE_SLEEP_US=0 ./tools/run_packet006_scopedbookmark_gate.sh dir-race
```

Send the resulting run directories:

```text
<workspace>/artifacts/runtime/packet006-scopedbookmark/<version-build-timestamp-mode>/
```

Promotion requires a 26.4/26.5 behavior split consistent with the
ScopedBookmarkAgent fd/bookmark validation delta. The
`sample_to_resolved_identity_divergence` counter is only an external race signal;
it is not proof of the agent-internal mismatch by itself. Stable controls must
succeed on both builds, and `sandbox-no-bookmark` controls must fail or deny
consistently. The `unentitled-stable` mode is diagnostic only because a
nonsandboxed process can create ordinary bookmarks.

## Campaign 1 Pack Text Results

```zsh
cd /path/to/applesauce
./tools/pack_campaign1_results.sh
```

Do not commit Apple binaries, dyld caches, extracted Mach-Os, app bundles, or raw
run tarballs.
