#!/usr/bin/env python3
"""
Diff two system-wide Mach-O __TEXT manifests and rank symlink-hardening leads.

Inputs are manifest.tsv files produced by
collect_systemwide_macho_text_manifest.py. This script is deterministic and
static-only; it ranks changed-code candidates for human/Binja follow-up.
"""

from __future__ import annotations

import argparse
import csv
from datetime import datetime, timezone
from pathlib import Path


AUTHORITY_TERMS = (
    "Contacts",
    "AddressBook",
    "SyncServices",
    "CardDAV",
    "DataAccess",
    "TCC",
    "Privacy",
    "Permission",
)

DAEMON_TERMS = ("daemon", "agent", "helper", "xpc", "service", "sync", "d")


def read_manifest(path: Path) -> dict[str, dict[str, str]]:
    with path.open(newline="") as f:
        reader = csv.DictReader(f, delimiter="\t")
        return {row["rel_path"]: row for row in reader if row.get("macho") == "yes"}


def int_field(row: dict[str, str] | None, key: str) -> int:
    if not row:
        return 0
    value = row.get(key, "0")
    try:
        return int(value)
    except ValueError:
        return 0


def has_signal(row: dict[str, str] | None) -> bool:
    return int_field(row, "symlink_signal_count") > 0


def terms_changed(base: dict[str, str] | None, patch: dict[str, str] | None) -> bool:
    if not base or not patch:
        return False
    return (
        base.get("symlink_strings", "-") != patch.get("symlink_strings", "-")
        or base.get("symlink_imports", "-") != patch.get("symlink_imports", "-")
    )


def score_row(rel: str, base: dict[str, str] | None, patch: dict[str, str] | None) -> tuple[int, str]:
    score = 0
    reasons: list[str] = []
    present_base = base is not None
    present_patch = patch is not None
    text_changed = False
    if present_base and present_patch:
        if base.get("text_sha256") != patch.get("text_sha256"):
            text_changed = True
            score += 50
            reasons.append("text_changed")
        if text_changed and base.get("file_sha256") != patch.get("file_sha256"):
            score += 5
            reasons.append("file_changed")
        if text_changed and (has_signal(base) or has_signal(patch)):
            score += 35
            reasons.append("symlink_signal_present")
        if text_changed and terms_changed(base, patch):
            score += 30
            reasons.append("symlink_signal_terms_changed")
        if text_changed and base.get("text_size_dec") != patch.get("text_size_dec"):
            score += 8
            reasons.append("text_size_changed")
    elif patch is not None:
        score += 20
        reasons.append("added_macho")
        if has_signal(patch):
            score += 35
            reasons.append("added_with_symlink_signal")
    elif base is not None:
        score += 5
        reasons.append("removed_macho")

    if score > 0 and any(term.lower() in rel.lower() for term in AUTHORITY_TERMS):
        score += 15
        reasons.append("privacy_or_contacts_path")

    leaf = Path(rel).name.lower()
    if score > 0 and any(term in leaf for term in DAEMON_TERMS):
        score += 5
        reasons.append("daemon_helper_shape")

    return score, ",".join(reasons) if reasons else "-"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline_manifest")
    parser.add_argument("patched_manifest")
    parser.add_argument("outdir")
    parser.add_argument("--min-score", type=int, default=1)
    args = parser.parse_args()

    base_path = Path(args.baseline_manifest).resolve()
    patch_path = Path(args.patched_manifest).resolve()
    out = Path(args.outdir).resolve()
    out.mkdir(parents=True, exist_ok=True)

    base = read_manifest(base_path)
    patch = read_manifest(patch_path)
    all_paths = sorted(set(base) | set(patch))

    fields = [
        "score",
        "rel_path",
        "baseline_present",
        "patched_present",
        "whole_file_same",
        "text_same",
        "baseline_text_size",
        "patched_text_size",
        "baseline_signals",
        "patched_signals",
        "signal_terms_changed",
        "path_authority_signal",
        "reasons",
        "baseline_symlink_strings",
        "patched_symlink_strings",
        "baseline_symlink_imports",
        "patched_symlink_imports",
        "baseline_copied_path",
        "patched_copied_path",
    ]

    rows: list[dict[str, str]] = []
    for rel in all_paths:
        b = base.get(rel)
        p = patch.get(rel)
        score, reasons = score_row(rel, b, p)
        if score < args.min_score:
            continue
        whole_same = "-"
        text_same = "-"
        if b and p:
            whole_same = "yes" if b.get("file_sha256") == p.get("file_sha256") else "no"
            text_same = "yes" if b.get("text_sha256") == p.get("text_sha256") else "no"
        rows.append(
            {
                "score": str(score),
                "rel_path": rel,
                "baseline_present": "yes" if b else "no",
                "patched_present": "yes" if p else "no",
                "whole_file_same": whole_same,
                "text_same": text_same,
                "baseline_text_size": b.get("text_size_dec", "-") if b else "-",
                "patched_text_size": p.get("text_size_dec", "-") if p else "-",
                "baseline_signals": b.get("symlink_signal_count", "0") if b else "0",
                "patched_signals": p.get("symlink_signal_count", "0") if p else "0",
                "signal_terms_changed": "yes" if terms_changed(b, p) else "no",
                "path_authority_signal": (
                    "yes"
                    if (b and b.get("path_authority_signal") == "yes")
                    or (p and p.get("path_authority_signal") == "yes")
                    else "no"
                ),
                "reasons": reasons,
                "baseline_symlink_strings": b.get("symlink_strings", "-") if b else "-",
                "patched_symlink_strings": p.get("symlink_strings", "-") if p else "-",
                "baseline_symlink_imports": b.get("symlink_imports", "-") if b else "-",
                "patched_symlink_imports": p.get("symlink_imports", "-") if p else "-",
                "baseline_copied_path": b.get("copied_path", "-") if b else "-",
                "patched_copied_path": p.get("copied_path", "-") if p else "-",
            }
        )

    rows.sort(key=lambda r: (-int(r["score"]), r["rel_path"]))

    matrix = out / "ranked-candidates.tsv"
    with matrix.open("w", newline="") as f:
        writer = csv.DictWriter(f, delimiter="\t", fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)

    text_changed = [
        row for row in rows if row["baseline_present"] == "yes" and row["patched_present"] == "yes" and row["text_same"] == "no"
    ]
    text_changed_with_signals = [
        row
        for row in text_changed
        if row["baseline_signals"] != "0" or row["patched_signals"] != "0"
    ]
    signal_term_deltas = [row for row in text_changed if row["signal_terms_changed"] == "yes"]

    with (out / "summary.md").open("w") as f:
        f.write("# System-Wide Symlink Hardening Sweep\n\n")
        f.write(f"Date: {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}\n\n")
        f.write(f"Baseline manifest: `{base_path}`\n\n")
        f.write(f"Patched manifest: `{patch_path}`\n\n")
        f.write("## Counts\n\n")
        f.write(f"- baseline Mach-O rows: {len(base)}\n")
        f.write(f"- patched Mach-O rows: {len(patch)}\n")
        f.write(f"- ranked rows: {len(rows)}\n")
        f.write(f"- common rows with `__TEXT,__text` delta: {len(text_changed)}\n")
        f.write(f"- text-delta rows with symlink/path signals: {len(text_changed_with_signals)}\n")
        f.write(f"- text-delta rows with changed symlink/path signal terms: {len(signal_term_deltas)}\n\n")
        f.write("## Top Candidates\n\n")
        f.write("| score | path | text_same | signals | signal_delta | reasons |\n")
        f.write("| --- | --- | --- | --- | --- | --- |\n")
        for row in rows[:40]:
            signals = f"{row['baseline_signals']}->{row['patched_signals']}"
            f.write(
                f"| {row['score']} | `{row['rel_path']}` | {row['text_same']} | "
                f"{signals} | {row['signal_terms_changed']} | {row['reasons']} |\n"
            )
        f.write("\n## Interpretation Rule\n\n")
        f.write(
            "Promote only rows where a changed function can be tied to symlink/path "
            "handling near Contacts/TCC consent or protected-data authority. This "
            "table is a candidate reducer, not a vulnerability claim.\n"
        )

    print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
