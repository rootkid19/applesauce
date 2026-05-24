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
./tools/collect_campaign1_host_state.sh
```

## LaunchServices Stock Gate

On Tahoe 26.3:

```zsh
cd /path/to/applesauce
./tools/run_campaign1_stock_gate.sh background
```

## Dyld Member Extraction

On Tahoe 26.3:

```zsh
cd /path/to/applesauce
./tools/collect_campaign1_dyld_members.sh 26.3 /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e
```

On Tahoe 26.4:

```zsh
cd /path/to/applesauce
./tools/collect_campaign1_dyld_members.sh 26.4 /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e
```

Main output:

```text
<workspace>/artifacts/dyld-members/<label>/selected/usr/lib/libLaunchServicesSupport.dylib
```

The dyld fallback extracts the full cache first, so expect time and disk use.

## Pack Text Results

```zsh
cd /path/to/applesauce
./tools/pack_campaign1_results.sh
```

Do not commit Apple binaries, dyld caches, extracted Mach-Os, app bundles, or raw
run tarballs.
