# Static Reverse-Engineering Tools

These tools are lightweight Mach-O triage helpers for Packet 004-style patch
diffing. They do not replace a decompiler and they do not make vulnerability
claims; they preserve command output and normalize enough metadata to make
future static passes reproducible.

Outputs default to:

```text
<workspace>/artifacts/static-re/<tool>/<timestamp>-<target>/
```

Set `APPLESAUCE_REVERSE_TIMESTAMP=<stable-id>` for deterministic reruns, or pass
`-o <outdir>`.

## Index One Mach-O

```zsh
./tools/reverse_macho_index.sh \
  ../04/dyld/selected/System/Library/Frameworks/FileProvider.framework/Versions/A/FileProvider
```

The index records the chosen arch, file metadata, UUIDs, install name, imports,
exports, Objective-C metadata, strings with offsets, entitlements when
extractable, linked dylibs, load commands, and dyld_info summaries.

## Slice And Compare The Packet 004 Helper

```zsh
./tools/reverse_function_slice.sh \
  ../04/dyld/selected/System/Library/Frameworks/FileProvider.framework/Versions/A/FileProvider \
  'fp_issueSandboxExtensionOfClass:report:error:'

./tools/reverse_compare_slices.sh \
  ../04/dyld/selected/System/Library/Frameworks/FileProvider.framework/Versions/A/FileProvider \
  ../artifacts/dyld-members-packet004/26.5/selected/System/Library/Frameworks/FileProvider.framework/Versions/A/FileProvider \
  'fp_issueSandboxExtensionOfClass:report:error:' \
  'fp_issueSandboxExtensionOfClass:report:error:'
```

The compare output keeps both raw slices and writes a normalized Markdown diff.

## Find Wrapper Callsites

```zsh
./tools/reverse_objc_callsite_search.sh \
  ../04/file/standalone/System/Library/PrivateFrameworks/CloudDocs.framework/PlugIns/com.apple.CloudDocs.iCloudDriveFileProvider.appex/Contents/MacOS/com.apple.CloudDocs.iCloudDriveFileProvider \
  'wrapperWithURL:readonly:error:'

./tools/reverse_objc_callsite_search.sh \
  ../artifacts/packet004-fileprovider/26.5/standalone/System/Library/PrivateFrameworks/CloudDocs.framework/PlugIns/com.apple.CloudDocs.iCloudDriveFileProvider.appex/Contents/MacOS/com.apple.CloudDocs.iCloudDriveFileProvider \
  'modifyItem:baseVersion:changedFields:contents:options:request:completionHandler:'
```

Selector searches use ObjC selector references and `__objc_stubs` when ipsw can
parse the Mach-O. C/import searches use indirect symbol stubs. Class-name
searches report class/GOT reference contexts where available.

## Packet 004 Funnel Map

```zsh
./tools/reverse_wrapper_funnel_map.sh ../04 ../artifacts
```

The map enumerates:

```text
FPSandboxingURLWrapper
wrapperWithURL:readonly:error:
wrapperWithURL:extensionClass:error:
fp_issueSandboxExtensionOfClass:report:error:
sandbox_extension_issue_file
_fpfs_fast_realpath
```

It emits `normalized/wrapper-funnel-map.csv` and `summary.md` with build, binary,
address/offset, likely callsite, confidence, and notes.
