# Quickstart

Clone anywhere. By default output goes next to the repo:

```text
<workspace>/applesauce
<workspace>/artifacts
```

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

## Campaign 1 Pack Text Results

```zsh
cd /path/to/applesauce
./tools/pack_campaign1_results.sh
```

Do not commit Apple binaries, dyld caches, extracted Mach-Os, app bundles, or raw
run tarballs.
