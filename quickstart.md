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

## Pack Text Results

```zsh
cd /path/to/applesauce
./tools/pack_campaign1_results.sh
```

Do not commit Apple binaries, dyld caches, extracted Mach-Os, app bundles, or raw
run tarballs.
