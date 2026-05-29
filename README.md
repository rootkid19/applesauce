# applesauce

Small macOS research toolkit for collecting Apple patch-diff artifacts and
emitting deterministic static-analysis manifests. This public repo is for
scripts and harness source only; packet reports, private workflow notes, raw
artifacts, and agent scratch stay outside git.

## Tools

| Script | Purpose |
| --- | --- |
| `tools/build_dsc_extractor_bundle_wrapper.sh` | Builds the local `dsc_extract_bundle` helper from `dsc_extract_bundle.c`. |
| `tools/collect_campaign1_dyld_members.sh` | Collects LaunchServices campaign dyld-cache members. |
| `tools/collect_campaign1_host_state.sh` | Captures basic host state for LaunchServices runtime checks. |
| `tools/collect_packet002_accounts_artifacts.sh` | Collects Packet 002 Accounts/Privacy standalone artifacts. |
| `tools/collect_packet002_authority_maps.sh` | Extracts Packet 002 authority-map metadata. |
| `tools/collect_packet002_dyld_members.sh` | Collects Packet 002 dyld-cache members. |
| `tools/collect_packet004_dyld_members.sh` | Collects Packet 004 FileProvider dyld-cache members. |
| `tools/collect_packet004_fileprovider_artifacts.sh` | Collects Packet 004 FileProvider standalone artifacts. |
| `tools/collect_packet006_dyld_members.sh` | Collects Packet 006 Sandbox dyld-cache members. |
| `tools/collect_packet006_sandbox_artifacts.sh` | Collects Packet 006 ScopedBookmarkAgent/Sandbox artifacts. |
| `tools/collect_packet007_dyld_members.sh` | Collects Packet 007 SyncServices/Contacts dyld-cache members. |
| `tools/collect_packet007_syncservices_artifacts.sh` | Collects Packet 007 SyncServices/Contacts standalone artifacts. |
| `tools/collect_release_file_manifest.sh` | Produces a broad release file manifest for a mounted macOS root. |
| `tools/collect_systemwide_dyld_member_text_manifest.py` | Emits dyld-cache member `__TEXT,__text` hashes and path/symlink signals. |
| `tools/collect_systemwide_macho_text_manifest.py` | Emits standalone Mach-O `__TEXT,__text` hashes and path/symlink signals. |
| `tools/common.sh` | Shared shell helpers for artifact paths, timestamps, and host metadata. |
| `tools/common_reverse.sh` | Shared helpers for static reversing scripts. |
| `tools/diff_packet002_binary_truth.sh` | Produces Packet 002 byte-level artifact diff tables. |
| `tools/diff_packet006_binary_truth.sh` | Produces Packet 006 byte-level artifact diff tables. |
| `tools/diff_packet007_binary_truth.sh` | Produces Packet 007 byte-level artifact diff tables. |
| `tools/diff_release_file_manifests.sh` | Diffs two release file manifests. |
| `tools/diff_systemwide_macho_text_manifests.py` | Ranks changed Mach-O/dyld-member text manifests by path/symlink signals. |
| `tools/dsc_extract_bundle.c` | Minimal wrapper source for Apple's local dyld shared-cache extractor bundle. |
| `tools/pack_campaign1_results.sh` | Packages LaunchServices campaign runtime results. |
| `tools/reverse_authority_map.sh` | Extracts authority-oriented strings, imports, entitlements, and selectors. |
| `tools/reverse_compare_slices.sh` | Compares two static function-slice directories. |
| `tools/reverse_function_slice.sh` | Extracts a focused disassembly/string/import slice around a function address. |
| `tools/reverse_macho_index.sh` | Indexes a Mach-O for strings, imports, symbols, ObjC metadata, and disassembly. |
| `tools/reverse_objc_callsite_search.sh` | Searches ObjC selector and callsite evidence in a Mach-O. |
| `tools/reverse_packet_sync_check.sh` | Checks packet status documents for active/parked drift. |
| `tools/reverse_packet_text_matrix.sh` | Builds a paired-root Mach-O text-hash matrix. |
| `tools/reverse_run_ledger.sh` | Records packet/lane/tool runs in TSV and JSONL ledgers. |
| `tools/reverse_surface_rank.py` | Ranks changed packet surfaces before function-level reversing. |
| `tools/reverse_wrapper_funnel_map.sh` | Maps FileProvider wrapper/helper funnel evidence. |
| `tools/run_campaign1_forcequit_gate.sh` | Runs the LaunchServices force-quit runtime gate. |
| `tools/run_campaign1_pidjob.sh` | Runs LaunchServices PID/job runtime checks. |
| `tools/run_campaign1_stock_gate.sh` | Runs LaunchServices stock-topology runtime checks. |
| `tools/run_packet004_extend_sandbox_gate.sh` | Runs the Packet 004 extend-sandbox runtime gate. |
| `tools/run_packet004_import_move_gate.sh` | Runs the Packet 004 import/move runtime gate. |
| `tools/run_packet004_importdomain_gate.sh` | Runs the Packet 004 importDomain runtime gate. |
| `tools/run_packet006_scopedbookmark_gate.sh` | Runs the Packet 006 ScopedBookmarkAgent runtime gate. |

## Harnesses

| Harness | Purpose |
| --- | --- |
| `harnesses/ls-stale-state` | LaunchServices parent/helper lifecycle probes. |
| `harnesses/packet004-extend-sandbox` | FileProvider extend-sandbox probe. |
| `harnesses/packet004-import-move` | FileProvider Finder import/move probe. |
| `harnesses/packet004-importdomain` | FileProvider importDomain probe. |
| `harnesses/packet006-scopedbookmark` | ScopedBookmarkAgent bookmark-race probe. |

## Repo Hygiene

- Keep packet reports, raw artifacts, Binary Ninja notes, agent memory, and
  private workflow docs out of this repo.
- Prefer adding reusable collectors, diff emitters, and small harness source.
- If a script is packet-specific, keep its name explicit and its output
  deterministic.
