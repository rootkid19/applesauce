#!/usr/bin/env python3
"""
Collect a broad Mach-O __TEXT,__text manifest for Apple patch-diff sweeps.

This is intentionally metadata-first: it walks either a supplied release diff
candidate list or broad system roots, records exact text-section hashes for
Mach-O files, and captures symlink/path-hardening signal terms. It does not try
to prove reachability or vulnerability impact.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


DEFAULT_ROOTS = [
    "/System/Library/LaunchDaemons",
    "/System/Library/LaunchAgents",
    "/System/Library/Sandbox",
    "/System/Library/FeatureFlags",
    "/System/Library/Preferences",
    "/System/Library/CoreServices",
    "/System/Library/Frameworks",
    "/System/Library/PrivateFrameworks",
    "/System/Library/ExtensionKit/Extensions",
    "/System/Applications",
    "/usr/bin",
    "/usr/sbin",
    "/usr/lib",
    "/usr/libexec",
]

SIGNAL_RE = re.compile(
    r"symlink|symbolic.?link|readlink|realpath|lstat|fstatat|openat|"
    r"O_NOFOLLOW|nofollow|ELOOP|getattrlist|faccessat|renameat|unlinkat|"
    r"URLByResolvingSymlinksInPath|resolvingSymlinks|standardizedURL|"
    r"destinationOfSymbolicLink|NSURLIsSymbolicLinkKey|isSymbolicLink",
    re.IGNORECASE,
)

PATH_AUTHORITY_RE = re.compile(
    r"Contacts|AddressBook|SyncServices|CardDAV|DataAccess|TCC|Privacy|"
    r"consent|permission|container|sandbox|bookmark|extension",
    re.IGNORECASE,
)


def run(cmd: list[str], timeout: int = 30) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sanitize_term(value: str) -> str:
    value = value.replace("\t", " ").replace("\r", " ").replace("\n", " ")
    value = re.sub(r"\s+", " ", value).strip()
    if len(value) > 180:
        value = value[:177] + "..."
    return value


def join_terms(values: Iterable[str], limit: int = 40) -> str:
    seen: list[str] = []
    for value in values:
        value = sanitize_term(value)
        if not value or value in seen:
            continue
        seen.append(value)
        if len(seen) >= limit:
            break
    return "|".join(seen) if seen else "-"


def is_macho(path: Path) -> bool:
    cp = run(["file", str(path)], timeout=10)
    return cp.returncode == 0 and "Mach-O" in cp.stdout


def archs_for(path: Path) -> list[str]:
    cp = run(["lipo", "-archs", str(path)], timeout=15)
    if cp.returncode == 0 and cp.stdout.strip():
        return cp.stdout.strip().split()
    cp = run(["file", str(path)], timeout=10)
    found = re.findall(r"\b(arm64e|arm64|x86_64)\b", cp.stdout)
    return found


def select_arch(path: Path) -> str:
    archs = archs_for(path)
    for wanted in ("arm64e", "arm64"):
        if wanted in archs:
            return wanted
    return archs[0] if archs else "-"


def thin_for(path: Path, arch: str, tmpdir: Path) -> Path | None:
    if arch == "-":
        return None
    archs = archs_for(path)
    if len(archs) <= 1:
        return path
    out = tmpdir / (hashlib.sha256(str(path).encode()).hexdigest() + f".{arch}.thin")
    cp = run(["lipo", "-thin", arch, "-output", str(out), str(path)], timeout=60)
    if cp.returncode != 0 or not out.exists():
        return None
    return out


def text_section(thin: Path) -> tuple[int, int] | None:
    cp = run(["otool", "-l", str(thin)], timeout=60)
    if cp.returncode != 0:
        return None
    in_section = False
    sect = seg = offset = size = None
    for line in cp.stdout.splitlines():
        stripped = line.strip()
        if stripped == "Section":
            in_section = True
            sect = seg = offset = size = None
            continue
        if not in_section:
            continue
        parts = stripped.split()
        if len(parts) < 2:
            continue
        key, value = parts[0], parts[1]
        if key == "sectname":
            sect = value
        elif key == "segname":
            seg = value
        elif key == "offset":
            offset = int(value, 0)
        elif key == "size":
            size = int(value, 0)
        if sect == "__text" and seg == "__TEXT" and offset is not None and size is not None:
            return offset, size
    return None


def import_lines(thin: Path) -> list[str]:
    cp = run(["otool", "-Iv", str(thin)], timeout=90)
    if cp.returncode != 0:
        return []
    return cp.stdout.splitlines()


def string_lines(thin: Path) -> list[str]:
    cp = run(["strings", str(thin)], timeout=90)
    if cp.returncode != 0:
        return []
    return cp.stdout.splitlines()


def candidate_paths_from_diff(path: Path, include_added_removed: bool) -> list[str]:
    out: list[str] = []
    with path.open(newline="") as f:
        rows = list(csv.reader(f, delimiter="\t"))
        if not rows:
            return []
        if rows[0] and rows[0][0] in {"path", "rel_path"}:
            header = rows[0]
            iterable = [dict(zip(header, row)) for row in rows[1:]]
        else:
            # changed-added-removed.tsv from diff_release_file_manifests.sh is
            # intentionally headerless.
            header = [
                "path",
                "result",
                "baseline_type",
                "patched_type",
                "baseline_size",
                "patched_size",
                "baseline_sha256",
                "patched_sha256",
            ]
            iterable = [dict(zip(header, row)) for row in rows]
        for row in iterable:
            rel = row.get("path") or row.get("rel_path")
            result = row.get("result", "")
            baseline_type = row.get("baseline_type", "")
            patched_type = row.get("patched_type", "")
            if not rel:
                continue
            if result == "changed" and (baseline_type == "file" or patched_type == "file"):
                out.append(rel)
            elif include_added_removed and result in {"added", "removed"}:
                if baseline_type == "file" or patched_type == "file":
                    out.append(rel)
    return sorted(set(out))


def broad_walk(root: Path, roots: list[str]) -> list[str]:
    out: list[str] = []
    for rel_root in roots:
        abs_root = root / rel_root.lstrip("/")
        if not abs_root.is_dir():
            continue
        for current, _dirs, files in os.walk(abs_root):
            for name in files:
                full = Path(current) / name
                try:
                    out.append(str(full.relative_to(root)))
                except ValueError:
                    continue
    return sorted(set(out))


def maybe_copy(path: Path, rel: str, out_dir: Path) -> str:
    dst = out_dir / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, dst)
    return str(dst)


def collect_one(root: Path, rel: str, tmpdir: Path, copy_dir: Path | None) -> dict[str, str]:
    full = root / rel
    row: dict[str, str] = {
        "rel_path": rel,
        "present": "yes" if full.is_file() else "no",
        "macho": "no",
        "file_size": "-",
        "file_sha256": "-",
        "arch": "-",
        "text_offset": "-",
        "text_size_hex": "-",
        "text_size_dec": "-",
        "text_sha256": "-",
        "imports_count": "-",
        "strings_count": "-",
        "symlink_string_count": "0",
        "symlink_import_count": "0",
        "symlink_signal_count": "0",
        "path_authority_signal": "no",
        "symlink_strings": "-",
        "symlink_imports": "-",
        "copied_path": "-",
        "error": "-",
    }
    if not full.is_file():
        return row
    try:
        row["file_size"] = str(full.stat().st_size)
        if not is_macho(full):
            return row
        row["macho"] = "yes"
        row["file_sha256"] = sha256_file(full)
        arch = select_arch(full)
        row["arch"] = arch
        thin = thin_for(full, arch, tmpdir)
        if thin is None:
            row["error"] = "thin_failed"
            return row
        sec = text_section(thin)
        if sec is not None:
            offset, size = sec
            row["text_offset"] = hex(offset)
            row["text_size_hex"] = hex(size)
            row["text_size_dec"] = str(size)
            with thin.open("rb") as f:
                f.seek(offset)
                row["text_sha256"] = sha256_bytes(f.read(size))
        imports = import_lines(thin)
        strings = string_lines(thin)
        import_hits = [line for line in imports if SIGNAL_RE.search(line)]
        string_hits = [line for line in strings if SIGNAL_RE.search(line)]
        row["imports_count"] = str(len(imports))
        row["strings_count"] = str(len(strings))
        row["symlink_import_count"] = str(len(import_hits))
        row["symlink_string_count"] = str(len(string_hits))
        row["symlink_signal_count"] = str(len(import_hits) + len(string_hits))
        row["path_authority_signal"] = "yes" if PATH_AUTHORITY_RE.search(rel) else "no"
        row["symlink_imports"] = join_terms(import_hits)
        row["symlink_strings"] = join_terms(string_hits)
        if copy_dir is not None and (import_hits or string_hits):
            row["copied_path"] = maybe_copy(full, rel, copy_dir)
    except Exception as exc:  # noqa: BLE001 - keep collection best-effort.
        row["error"] = sanitize_term(type(exc).__name__ + ": " + str(exc))
    return row


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("label")
    parser.add_argument("root", nargs="?", default="/")
    parser.add_argument("--out", help="output directory")
    parser.add_argument("--candidate-list", help="release manifest diff TSV")
    parser.add_argument("--include-added-removed", action="store_true")
    parser.add_argument("--roots", help="colon-separated roots for broad walk")
    parser.add_argument("--copy-signal-binaries", action="store_true")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    if not root.is_dir():
        print(f"root not found: {root}", file=sys.stderr)
        return 2

    if args.out:
        out = Path(args.out).resolve()
    else:
        workspace = Path(__file__).resolve().parents[2]
        out = workspace / "artifacts" / "systemwide-symlink-sweep" / args.label
    out.mkdir(parents=True, exist_ok=True)
    metadata = out / "metadata"
    metadata.mkdir(exist_ok=True)
    copy_dir = out / "signal-binaries" if args.copy_signal_binaries else None
    if copy_dir is not None:
        copy_dir.mkdir(exist_ok=True)

    if args.candidate_list:
        rels = candidate_paths_from_diff(Path(args.candidate_list), args.include_added_removed)
        source = f"candidate-list={args.candidate_list}"
    else:
        roots = args.roots.split(":") if args.roots else DEFAULT_ROOTS
        rels = broad_walk(root, roots)
        source = "broad-walk"

    fields = [
        "rel_path",
        "present",
        "macho",
        "file_size",
        "file_sha256",
        "arch",
        "text_offset",
        "text_size_hex",
        "text_size_dec",
        "text_sha256",
        "imports_count",
        "strings_count",
        "symlink_string_count",
        "symlink_import_count",
        "symlink_signal_count",
        "path_authority_signal",
        "symlink_strings",
        "symlink_imports",
        "copied_path",
        "error",
    ]

    context = metadata / "manifest-context.txt"
    with context.open("w") as f:
        f.write(f"label={args.label}\n")
        f.write(f"root={root}\n")
        f.write(f"source={source}\n")
        f.write(f"date_utc={datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}\n")
        f.write(f"candidate_count={len(rels)}\n")
        sw = run(["sw_vers"], timeout=5) if str(root) == "/" else None
        if sw is not None:
            f.write(sw.stdout)

    manifest = out / "manifest.tsv"
    with tempfile.TemporaryDirectory() as td, manifest.open("w", newline="") as f:
        writer = csv.DictWriter(f, delimiter="\t", fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        tmpdir = Path(td)
        macho_count = 0
        signal_count = 0
        for idx, rel in enumerate(rels, start=1):
            row = collect_one(root, rel, tmpdir, copy_dir)
            if row["macho"] == "yes":
                macho_count += 1
            if row["symlink_signal_count"] not in {"0", "-"}:
                signal_count += 1
            writer.writerow(row)
            if idx % 250 == 0:
                print(f"processed {idx}/{len(rels)} candidates", file=sys.stderr)

    with (metadata / "summary.tsv").open("w") as f:
        f.write(f"candidates\t{len(rels)}\n")
        f.write(f"macho\t{macho_count}\n")
        f.write(f"symlink_signal_machos\t{signal_count}\n")

    print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
