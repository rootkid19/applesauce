# Quickstart

Clone anywhere. The default workspace is the parent directory of the cloned
`applesauce` repo:

```text
<workspace>/
  applesauce/
  artifacts/
```

Override paths only if needed:

```zsh
export APPLESAUCE_WORKSPACE=/path/to/workspace
export APPLESAUCE_ARTIFACTS=/path/to/artifacts
export LS_STALE_HARNESS_ROOT=/path/to/harnesses/ls-stale-state
```

The LS stale-state harness source is included under:

```text
applesauce/harnesses/ls-stale-state/
```

## 26.3 Runtime

Boot into Tahoe 26.3, then run:

```zsh
cd /path/to/applesauce
tools/collect_campaign1_host_state.sh
tools/run_campaign1_stock_gate.sh
```

If the stock gate reports that this exists, stop:

```text
/Library/Preferences/FeatureFlags/Domain/LaunchServices.plist
```

That run is not clean-stock until the plist is moved aside and LaunchServices
state is refreshed by rebooting or restarting `launchservicesd`.

If the stock gate shows stock `enableQuitReally: YES`, run:

```zsh
tools/run_campaign1_pidjob.sh
```

## Dyld Members

Extract target dyld members from a complete split cache:

```zsh
tools/collect_campaign1_dyld_members.sh 26.3 /System/Volumes/Preboot/Cryptexes/OS/System/Library/dyld/dyld_shared_cache_arm64e
```

For 26.4, use the mounted 26.4 cache path and label:

```zsh
tools/collect_campaign1_dyld_members.sh 26.4 /path/to/26.4/dyld_shared_cache_arm64e
```

## Package Text Results

```zsh
tools/pack_campaign1_results.sh
```

Full runtime output stays local under:

```text
<artifacts>/runtime/
```

Do not commit Apple binaries, dyld caches, extracted Mach-Os, app bundles, or raw
run tarballs.
