# applesauce

Small macOS patch-diff toolkit for collecting artifacts and emitting
deterministic static-analysis manifests. No Apple binaries or research reports
are included.

Most scripts write outputs to a sibling `artifacts/` directory next to this
repo. Script names are intentionally explicit; packet-numbered scripts are
target-specific collectors or gates.

## Scripts

| Script | Description |
| --- | --- |
| `tools/build_dsc_extractor_bundle_wrapper.sh` | Build the local dyld shared-cache extractor wrapper. |
| `tools/collect_campaign1_dyld_members.sh` | Collect LaunchServices dyld-cache members. |
| `tools/collect_campaign1_host_state.sh` | Capture basic host state for runtime comparisons. |
| `tools/collect_f022_iomfb_kc_artifacts.sh` | Collect read-only F022 IOMobileFramebuffer/IOSurface kernelcollection artifacts. |
| `tools/collect_packet002_accounts_artifacts.sh` | Collect Accounts/Privacy standalone artifacts. |
| `tools/collect_packet002_authority_maps.sh` | Collect authority-map metadata for Accounts/Privacy artifacts. |
| `tools/collect_packet002_dyld_members.sh` | Collect Accounts/Privacy dyld-cache members. |
| `tools/collect_packet004_dyld_members.sh` | Collect FileProvider dyld-cache members. |
| `tools/collect_packet004_fileprovider_artifacts.sh` | Collect FileProvider standalone artifacts. |
| `tools/collect_packet006_dyld_members.sh` | Collect Sandbox/ScopedBookmark dyld-cache members. |
| `tools/collect_packet006_sandbox_artifacts.sh` | Collect Sandbox/ScopedBookmark standalone artifacts. |
| `tools/collect_packet007_dyld_members.sh` | Collect SyncServices/Contacts dyld-cache members. |
| `tools/collect_packet007_syncservices_artifacts.sh` | Collect SyncServices/Contacts standalone artifacts. |
| `tools/collect_release_file_manifest.sh` | Build a broad file manifest for a mounted macOS root. |
| `tools/collect_systemwide_dyld_member_text_manifest.py` | Hash dyld-cache member `__TEXT,__text` sections and collect path/symlink signals. |
| `tools/collect_systemwide_macho_text_manifest.py` | Hash standalone Mach-O `__TEXT,__text` sections and collect path/symlink signals. |
| `tools/common.sh` | Shared shell helpers. |
| `tools/common_reverse.sh` | Shared static-reversing helpers. |
| `tools/diff_packet002_binary_truth.sh` | Diff Accounts/Privacy collected artifacts. |
| `tools/diff_packet006_binary_truth.sh` | Diff Sandbox/ScopedBookmark collected artifacts. |
| `tools/diff_packet007_binary_truth.sh` | Diff SyncServices/Contacts collected artifacts. |
| `tools/diff_release_file_manifests.sh` | Diff two release file manifests. |
| `tools/diff_systemwide_macho_text_manifests.py` | Rank changed Mach-O or dyld-member text manifests. |
| `tools/dsc_extract_bundle.c` | Source for the local dyld extractor wrapper. |
| `tools/pack_campaign1_results.sh` | Package LaunchServices campaign outputs. |
| `tools/reverse_authority_map.sh` | Extract authority-oriented static metadata from a Mach-O. |
| `tools/reverse_compare_slices.sh` | Compare two function-slice directories. |
| `tools/reverse_function_slice.sh` | Extract a focused static slice around a function. |
| `tools/reverse_macho_index.sh` | Index a Mach-O for symbols, imports, strings, ObjC metadata, and disassembly. |
| `tools/reverse_objc_callsite_search.sh` | Search ObjC selector/callsite evidence. |
| `tools/reverse_packet_sync_check.sh` | Check packet status files for state drift. |
| `tools/reverse_packet_text_matrix.sh` | Build paired-root Mach-O text-hash matrices. |
| `tools/reverse_run_ledger.sh` | Append deterministic run metadata to TSV/JSONL ledgers. |
| `tools/reverse_surface_rank.py` | Rank changed surfaces before function-level reversing. |
| `tools/reverse_wrapper_funnel_map.sh` | Map FileProvider wrapper/helper funnel evidence. |
| `tools/run_campaign1_forcequit_gate.sh` | Run the LaunchServices force-quit gate. |
| `tools/run_campaign1_pidjob.sh` | Run the LaunchServices PID/job gate. |
| `tools/run_campaign1_stock_gate.sh` | Run the LaunchServices stock-topology gate. |
| `tools/run_packet004_extend_sandbox_gate.sh` | Run the FileProvider extend-sandbox gate. |
| `tools/run_packet004_import_move_gate.sh` | Run the FileProvider import/move gate. |
| `tools/run_packet004_importdomain_gate.sh` | Run the FileProvider importDomain gate. |
| `tools/run_packet006_scopedbookmark_gate.sh` | Run the ScopedBookmark runtime gate. |
| `tools/run_packet009_ditto_supplied_zip_probe.sh` | Probe a supplied ZIP through direct `ditto` extraction and record quarantine on the extracted app. |
| `tools/run_packet009_supplied_zip_probe.sh` | Probe a supplied ZIP through Archive Utility and record quarantine on the extracted app. |
| `tools/run_packet009_zip_gatekeeper_explore.sh` | Explore Packet 009 ZIP/Gatekeeper extraction cases. |
