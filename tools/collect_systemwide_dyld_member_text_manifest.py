#!/usr/bin/env python3
"""
Collect a broad dyld-cache member __TEXT,__text manifest for Apple patch-diff sweeps.

Mirrors collect_systemwide_macho_text_manifest.py for dyld-shared-cache members.
Extracts each member to a temporary file, records exact text-section hashes, and
captures symlink/path-hardening signal terms. Does not try to prove reachability
or vulnerability impact.

Two-stage usage:
  1) List members only:
     collect_systemwide_dyld_member_text_manifest.py <cache> --list-only

  2) Full sweep with optional filtering:
     collect_systemwide_dyld_member_text_manifest.py <cache> \
       --filter-regex 'Contacts|SyncServices|AddressBook|TCC'
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

# Same non-alphanumeric boundary rule as the standalone collector.
TERM_BOUNDARY = r"(?<![A-Za-z0-9]){term}(?![A-Za-z0-9])"


def term_pattern(term: str) -> str:
    return TERM_BOUNDARY.format(term=re.escape(term))


SIGNAL_RE = re.compile(
    r"symlink|symbolic.?link|"
    + "|".join(
        term_pattern(term)
        for term in (
            "readlink",
            "realpath",
            "lstat",
            "fstatat",
            "openat",
            "O_NOFOLLOW_ANY",
            "O_NOFOLLOW",
            "ELOOP",
            "getattrlist",
            "faccessat",
            "renameat",
            "renameatx_np",
            "unlinkat",
            "AT_SYMLINK_NOFOLLOW",
            "F_GETPATH",
            "fcntl",
            "clonefile",
            "renamex_np",
            "RENAME_SWAP",
            "RENAME_EXCL",
        )
    )
    + r"|nofollow|canonical|canonicaliz|stringByStandardizingPath|"
    r"URLByResolvingSymlinksInPath|resolvingSymlinks|standardizedURL|"
    r"destinationOfSymbolicLink|NSURLIsSymbolicLinkKey|isSymbolicLink",
    re.IGNORECASE,
)

PATH_AUTHORITY_RE = re.compile(
    r"Contacts|AddressBook|SyncServices|CardDAV|DataAccess|TCC|Privacy|"
    r"consent|permission|container|sandbox|bookmark",
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


def normalize_import_hit(line: str) -> str:
    """Reduce otool -Iv rows to symbol names so address churn is not a signal."""
    parts = line.split()
    if not parts:
        return line
    return parts[-1]


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


def list_members(cache: Path) -> list[str]:
    """Return sorted member install paths from the dyld cache."""
    cp = run(
        ["ipsw", "dyld", "info", "--dylibs", "--json", "--no-color", str(cache)],
        timeout=120,
    )
    if cp.returncode != 0:
        raise RuntimeError(f"ipsw dyld info failed: {cp.stderr}")
    data = json.loads(cp.stdout)
    members = [d["name"] for d in data.get("dylibs", []) if d.get("name")]
    return sorted(set(members))


def extract_member(cache: Path, member: str, outdir: Path) -> Path | None:
    """Extract a single member. Return path to extracted file or None."""
    cp = run(
        [
            "ipsw",
            "dyld",
            "extract",
            "--force",
            "--no-color",
            "-o",
            str(outdir),
            str(cache),
            member,
        ],
        timeout=120,
    )
    if cp.returncode != 0:
        return None
    # ipsw writes to outdir/basename(member)
    basename = os.path.basename(member)
    candidate = outdir / basename
    if candidate.exists():
        return candidate
    # Fallback: any file in outdir (should not happen)
    files = [p for p in outdir.iterdir() if p.is_file()]
    return files[0] if files else None


def collect_one(cache: Path, member: str, tmpdir: Path) -> dict[str, str]:
    row: dict[str, str] = {
        "rel_path": member,
        "present": "yes",
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

    extracted = extract_member(cache, member, tmpdir)
    if extracted is None:
        row["error"] = "extract_failed"
        return row

    try:
        if not is_macho(extracted):
            row["error"] = "not_macho"
            return row

        row["macho"] = "yes"
        row["file_size"] = str(extracted.stat().st_size)
        row["file_sha256"] = sha256_file(extracted)

        arch = select_arch(extracted)
        row["arch"] = arch

        sec = text_section(extracted)
        if sec is not None:
            offset, size = sec
            row["text_offset"] = hex(offset)
            row["text_size_hex"] = hex(size)
            row["text_size_dec"] = str(size)
            with extracted.open("rb") as f:
                f.seek(offset)
                row["text_sha256"] = sha256_bytes(f.read(size))

        imports = import_lines(extracted)
        strings = string_lines(extracted)
        import_hits = [normalize_import_hit(line) for line in imports if SIGNAL_RE.search(line)]
        string_hits = [line for line in strings if SIGNAL_RE.search(line)]

        row["imports_count"] = str(len(imports))
        row["strings_count"] = str(len(strings))
        row["symlink_import_count"] = str(len(import_hits))
        row["symlink_string_count"] = str(len(string_hits))
        row["symlink_signal_count"] = str(len(import_hits) + len(string_hits))
        row["path_authority_signal"] = "yes" if PATH_AUTHORITY_RE.search(member) else "no"
        row["symlink_imports"] = join_terms(import_hits)
        row["symlink_strings"] = join_terms(string_hits)
    except Exception as exc:  # noqa: BLE001
        row["error"] = sanitize_term(type(exc).__name__ + ": " + str(exc))
    finally:
        # Clean up extracted file to avoid filling temp
        try:
            if extracted.exists():
                extracted.unlink()
        except OSError:
            pass

    return row


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cache", help="path to dyld_shared_cache_arm64e")
    parser.add_argument("--label", help="build label for metadata")
    parser.add_argument("--out", help="output directory")
    parser.add_argument("--filter-regex", help="regex to filter member names")
    parser.add_argument("--candidate-list", help="file with one member path per line")
    parser.add_argument("--list-only", action="store_true", help="list members and exit")
    parser.add_argument("--copy-signal-binaries", action="store_true")
    args = parser.parse_args()

    cache = Path(args.cache).resolve()
    if not cache.is_file():
        print(f"cache not found: {cache}", file=sys.stderr)
        return 2

    if args.out:
        out = Path(args.out).resolve()
    else:
        workspace = Path(__file__).resolve().parents[2]
        label = args.label or cache.stem
        out = workspace / "artifacts" / "systemwide-symlink-sweep" / f"{label}-dyld"
    out.mkdir(parents=True, exist_ok=True)
    metadata = out / "metadata"
    metadata.mkdir(exist_ok=True)

    copy_dir = out / "signal-binaries" if args.copy_signal_binaries else None
    if copy_dir is not None:
        copy_dir.mkdir(exist_ok=True)

    # List members
    try:
        members = list_members(cache)
    except RuntimeError as exc:
        print(exc, file=sys.stderr)
        return 2

    # Apply filters
    if args.candidate_list:
        with open(args.candidate_list) as f:
            wanted = {line.strip() for line in f if line.strip()}
        members = [m for m in members if m in wanted]
        source = f"candidate-list={args.candidate_list}"
    elif args.filter_regex:
        pattern = re.compile(args.filter_regex, re.IGNORECASE)
        members = [m for m in members if pattern.search(m)]
        source = f"filter-regex={args.filter_regex}"
    else:
        source = "full-cache"

    if args.list_only:
        list_path = out / "member-list.txt"
        with list_path.open("w") as f:
            for m in members:
                f.write(m + "\n")
        print(f"Listed {len(members)} members: {list_path}")
        return 0

    # Record context
    context = metadata / "manifest-context.txt"
    with context.open("w") as f:
        f.write(f"label={args.label or cache.stem}\n")
        f.write(f"cache={cache}\n")
        f.write(f"source={source}\n")
        f.write(f"date_utc={datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}\n")
        f.write(f"member_count={len(members)}\n")
        f.write(f"cache_sha256={sha256_file(cache)}\n")
        cp = run(["ipsw", "version"], timeout=5)
        if cp.returncode == 0:
            f.write(f"ipsw_version={cp.stdout.strip()}\n")

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

    manifest = out / "manifest.tsv"
    with tempfile.TemporaryDirectory() as td, manifest.open("w", newline="") as f:
        writer = csv.DictWriter(f, delimiter="\t", fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        tmpdir = Path(td)
        macho_count = 0
        signal_count = 0
        error_count = 0
        for idx, member in enumerate(members, start=1):
            row = collect_one(cache, member, tmpdir)
            if row["macho"] == "yes":
                macho_count += 1
            if row["symlink_signal_count"] not in {"0", "-"}:
                signal_count += 1
            if row["error"] != "-":
                error_count += 1
            if copy_dir is not None and row["symlink_signal_count"] not in {"0", "-"}:
                # Copy the signal-bearing extracted file for later inspection
                try:
                    extracted = extract_member(cache, member, tmpdir)
                    if extracted:
                        dst = copy_dir / extracted.name
                        dst.write_bytes(extracted.read_bytes())
                        row["copied_path"] = str(dst)
                        extracted.unlink()
                except Exception:
                    pass
            writer.writerow(row)
            if idx % 100 == 0:
                print(f"processed {idx}/{len(members)} members", file=sys.stderr)

    with (metadata / "summary.tsv").open("w") as f:
        f.write(f"members\t{len(members)}\n")
        f.write(f"macho\t{macho_count}\n")
        f.write(f"symlink_signal_machos\t{signal_count}\n")
        f.write(f"errors\t{error_count}\n")

    print(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
