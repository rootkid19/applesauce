#!/usr/bin/env python3
"""
Rank changed Apple patch-diff surfaces from applesauce diff trees.

This is a deterministic triage layer. It ranks binaries, plists, profiles, and
dyld selected members by path and string evidence so humans/agents know where
to look first. It does not infer root cause or claim vulnerability impact.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


SIGNALS = {
    "privacy": (
        16,
        re.compile(
            r"Privacy|privacy|TCC|kTCCService|FullDiskAccess|AllFiles|"
            r"consent|prompt|authorizationStatus|authorized|denied",
            re.IGNORECASE,
        ),
    ),
    "tcc": (
        16,
        re.compile(r"\btccd?\b|TCCAccess|TCCService|TCCAuth|TCCIdentity|tccutil", re.IGNORECASE),
    ),
    "entitlement": (
        13,
        re.compile(
            r"entitlement|SecTaskCopyValueForEntitlement|com\.apple\.private|"
            r"com\.apple\.security|hasInternalAccess|fullaccess|allaccounts",
            re.IGNORECASE,
        ),
    ),
    "audit_token": (
        12,
        re.compile(r"audit[_ ]?token|auditToken|xpc_connection_get_audit_token|SecTask", re.IGNORECASE),
    ),
    "code_signing": (
        10,
        re.compile(r"SecCode|SecStaticCode|signingIdentifier|teamIdentifier|csops|codesign", re.IGNORECASE),
    ),
    "xpc_mach": (
        9,
        re.compile(r"XPC|xpc_|NSXPCConnection|MachService|mach-lookup|bootstrap_look_up", re.IGNORECASE),
    ),
    "accounts": (
        12,
        re.compile(r"Accounts?|accountsd|AppleAccount|AOSAccounts|InternetAccounts|accountmanager", re.IGNORECASE),
    ),
    "authkit": (
        9,
        re.compile(r"AuthKit|AKAppleID|AKAuthorization|akd|anisette|AppleID|altDSID", re.IGNORECASE),
    ),
    "sandbox": (
        8,
        re.compile(r"sandbox|SandboxProfile|sandbox_extension|com\.apple\.security\.app-sandbox", re.IGNORECASE),
    ),
    "path_state": (
        6,
        re.compile(r"realpath|symlink|bookmark|container|persona|bundleIdentifier|clientIdentity", re.IGNORECASE),
    ),
}

RESULT_WEIGHTS = {
    "added": 12,
    "changed": 6,
    "removed": 1,
}

CATEGORY_WEIGHTS = {
    "dyld-selected": 12,
    "standalone": 9,
    "profiles": 7,
    "feature-flags": 5,
}

PATH_BOOSTS = [
    (re.compile(r"/Support/[^/]+$|/MacOS/[^/]+$|usr/libexec/|usr/bin/", re.IGNORECASE), 8, "executable surface"),
    (re.compile(r"\.xpc/Contents/MacOS/", re.IGNORECASE), 8, "xpc service executable"),
    (re.compile(r"LaunchAgents?/|LaunchDaemons?/", re.IGNORECASE), 5, "launchd surface"),
    (re.compile(r"Sandbox/Profiles/|\.sb$", re.IGNORECASE), 6, "sandbox profile"),
    (re.compile(r"TCC|Privacy|Permission", re.IGNORECASE), 8, "privacy/TCC path"),
    (re.compile(r"AccountsDaemon|accountsd|accounts\.dom|AppleAccount|InternetAccounts", re.IGNORECASE), 8, "accounts path"),
    (re.compile(r"appleaccounttransparencyd|AppleAccountTransparency", re.IGNORECASE), 8, "new transparency surface"),
]

PATH_PENALTIES = [
    (re.compile(r"/Info\.plist$|/version\.plist$", re.IGNORECASE), -8, "version/info plist"),
    (re.compile(r"/Resources/Metadata\.appintents/", re.IGNORECASE), -7, "app intents metadata"),
    (re.compile(r"\.momd/VersionInfo\.plist$", re.IGNORECASE), -6, "model version metadata"),
]


@dataclass
class Surface:
    category: str
    path: str
    result: str
    baseline_sha256: str
    patched_sha256: str
    score: int = 0
    classification: str = ""
    reasons: list[str] = field(default_factory=list)
    penalties: list[str] = field(default_factory=list)
    signal_counts: dict[str, int] = field(default_factory=dict)
    added_signal_strings: list[str] = field(default_factory=list)
    inspected_file: str = ""


def workspace_root() -> Path:
    env = os.environ.get("APPLESAUCE_WORKSPACE")
    if env:
        return Path(env).resolve()
    return Path(__file__).resolve().parents[2]


def artifact_root() -> Path:
    env = os.environ.get("APPLESAUCE_ARTIFACTS")
    if env:
        return Path(env).resolve()
    return workspace_root() / "artifacts"


def parse_context(diff_dir: Path) -> dict[str, str]:
    context = {}
    path = diff_dir / "metadata" / "diff-context.txt"
    if not path.exists():
        return context
    for line in path.read_text(errors="replace").splitlines():
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        context[key.strip()] = value.strip()
    return context


def load_surfaces(diff_dir: Path) -> list[Surface]:
    surfaces = []
    trees = diff_dir / "trees"
    if not trees.exists():
        raise SystemExit(f"missing diff tree directory: {trees}")
    for tsv in sorted(trees.glob("*.tsv")):
        with tsv.open(newline="", errors="replace") as f:
            reader = csv.DictReader(f, delimiter="\t")
            for row in reader:
                result = row.get("result", "")
                if result == "identical":
                    continue
                surfaces.append(
                    Surface(
                        category=row.get("category", tsv.stem),
                        path=row.get("path", ""),
                        result=result,
                        baseline_sha256=row.get("baseline_sha256", "-"),
                        patched_sha256=row.get("patched_sha256", "-"),
                    )
                )
    return surfaces


def category_roots(context: dict[str, str], args) -> dict[str, tuple[Path | None, Path | None]]:
    baseline_root = Path(args.baseline_root).resolve() if args.baseline_root else path_or_none(context.get("baseline_root"))
    patched_root = Path(args.patched_root).resolve() if args.patched_root else path_or_none(context.get("patched_root"))
    baseline_dyld = Path(args.baseline_dyld).resolve() if args.baseline_dyld else path_or_none(context.get("baseline_dyld"))
    patched_dyld = Path(args.patched_dyld).resolve() if args.patched_dyld else path_or_none(context.get("patched_dyld"))
    return {
        "standalone": (baseline_root / "standalone" if baseline_root else None, patched_root / "standalone" if patched_root else None),
        "profiles": (baseline_root / "profiles" if baseline_root else None, patched_root / "profiles" if patched_root else None),
        "feature-flags": (
            baseline_root / "feature-flags" if baseline_root else None,
            patched_root / "feature-flags" if patched_root else None,
        ),
        "dyld-selected": (baseline_dyld, patched_dyld),
    }


def path_or_none(value: str | None) -> Path | None:
    if not value:
        return None
    return Path(value).resolve()


def strings_for(path: Path | None, max_bytes: int, timeout: int) -> list[str]:
    if not path or not path.exists() or not path.is_file():
        return []
    if path.stat().st_size > max_bytes:
        return []
    try:
        proc = subprocess.run(
            ["/usr/bin/strings", "-a", str(path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    return [line.strip() for line in proc.stdout.splitlines() if line.strip()]


def matching_signal_names(text: str) -> list[str]:
    names = []
    for name, (_, pattern) in SIGNALS.items():
        if pattern.search(text):
            names.append(name)
    return names


def score_surface(surface: Surface, roots: dict[str, tuple[Path | None, Path | None]], args) -> Surface:
    score = 0
    text_chunks = [surface.path, surface.category, surface.result]

    result_bonus = RESULT_WEIGHTS.get(surface.result, 0)
    score += result_bonus
    surface.reasons.append(f"result:{surface.result} (+{result_bonus})")

    category_bonus = CATEGORY_WEIGHTS.get(surface.category, 0)
    score += category_bonus
    surface.reasons.append(f"category:{surface.category} (+{category_bonus})")

    for pattern, boost, label in PATH_BOOSTS:
        if pattern.search(surface.path):
            score += boost
            surface.reasons.append(f"path:{label} (+{boost})")

    for pattern, penalty, label in PATH_PENALTIES:
        if pattern.search(surface.path):
            score += penalty
            surface.penalties.append(f"path:{label} ({penalty})")

    if args.focus_regex:
        if path_matches_any(surface.path, args.focus_regex):
            score += args.focus_boost
            surface.reasons.append(f"path:focus match (+{args.focus_boost})")
        else:
            score -= args.non_focus_penalty
            surface.penalties.append(f"path:non-focus (-{args.non_focus_penalty})")

    baseline_root, patched_root = roots.get(surface.category, (None, None))
    baseline_file = baseline_root / surface.path if baseline_root else None
    patched_file = patched_root / surface.path if patched_root else None
    inspected = patched_file if patched_file and patched_file.exists() else baseline_file
    surface.inspected_file = str(inspected) if inspected else ""

    patched_strings = strings_for(patched_file, args.max_file_bytes, args.string_timeout)
    baseline_strings = strings_for(baseline_file, args.max_file_bytes, args.string_timeout)
    added_strings = sorted(set(patched_strings) - set(baseline_strings)) if patched_strings else []
    corpus = "\n".join(text_chunks + patched_strings[: args.max_strings])

    for name, (weight, pattern) in SIGNALS.items():
        count = len(pattern.findall(corpus))
        if count <= 0:
            continue
        capped = min(count, 8)
        signal_score = weight + capped - 1
        score += signal_score
        surface.signal_counts[name] = count
        surface.reasons.append(f"signal:{name}={count} (+{signal_score})")

    for s in added_strings:
        if len(surface.added_signal_strings) >= args.max_added_string_samples:
            break
        if is_noisy_string_sample(s):
            continue
        if matching_signal_names(s):
            surface.added_signal_strings.append(s)

    if surface.added_signal_strings:
        added_bonus = min(len(surface.added_signal_strings) * 3, 18)
        score += added_bonus
        surface.reasons.append(f"added_signal_strings={len(surface.added_signal_strings)} (+{added_bonus})")

    if not patched_strings and inspected and inspected.exists() and inspected.stat().st_size > args.max_file_bytes:
        surface.penalties.append(f"strings skipped: file larger than {args.max_file_bytes} bytes")

    surface.score = max(score, 0)
    surface.classification = classify(surface)
    return surface


def path_matches_any(path: str, patterns: Iterable[str]) -> bool:
    for pattern in patterns:
        if re.search(pattern, path, re.IGNORECASE):
            return True
    return False


def is_noisy_string_sample(value: str) -> bool:
    return (
        value.startswith("/AppleInternal/")
        or "/BuildRoots/" in value
        or "/TemporaryDirectory." in value
        or "/Library/Caches/com.apple.xbs/" in value
    )


def classify(surface: Surface) -> str:
    signals = set(surface.signal_counts)
    if surface.score >= 75 and {"privacy", "accounts"} & signals:
        return "High-priority semantic triage"
    if surface.score >= 55 and signals:
        return "Worth bounded reversing"
    if surface.score >= 35:
        return "Context/watchlist"
    return "Low priority"


def as_dict(surface: Surface) -> dict:
    return {
        "category": surface.category,
        "path": surface.path,
        "result": surface.result,
        "score": surface.score,
        "classification": surface.classification,
        "signals": surface.signal_counts,
        "reasons": surface.reasons,
        "penalties": surface.penalties,
        "added_signal_strings": surface.added_signal_strings,
        "baseline_sha256": surface.baseline_sha256,
        "patched_sha256": surface.patched_sha256,
        "inspected_file": surface.inspected_file,
    }


def render_markdown(surfaces: list[Surface], args, out: Path) -> None:
    lines = [
        "# Changed Surface Ranking",
        "",
        f"Date: {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}",
        "",
        "This is deterministic surface triage only. It does not claim root cause, reachability, or vulnerability impact.",
        "",
        "## Top Surfaces",
        "",
        "| Rank | Score | Classification | Result | Category | Path | Top Signals |",
        "| ---: | ---: | --- | --- | --- | --- | --- |",
    ]
    for idx, surface in enumerate(surfaces[: args.top], start=1):
        signals = ", ".join(f"{k}:{v}" for k, v in sorted(surface.signal_counts.items())) or "-"
        lines.append(
            f"| {idx} | {surface.score} | {surface.classification} | {surface.result} | "
            f"{surface.category} | `{surface.path}` | {signals} |"
        )

    lines.extend(["", "## Details", ""])
    for idx, surface in enumerate(surfaces[: args.details], start=1):
        lines.extend(
            [
                f"### {idx}. `{surface.path}`",
                "",
                f"- score: `{surface.score}`",
                f"- classification: `{surface.classification}`",
                f"- category/result: `{surface.category}` / `{surface.result}`",
                f"- inspected file: `{surface.inspected_file or 'not available'}`",
                f"- baseline sha256: `{surface.baseline_sha256}`",
                f"- patched sha256: `{surface.patched_sha256}`",
                "",
                "Reasons:",
            ]
        )
        lines.extend(f"- {reason}" for reason in surface.reasons[:20])
        if surface.penalties:
            lines.append("")
            lines.append("Penalties / caveats:")
            lines.extend(f"- {penalty}" for penalty in surface.penalties[:10])
        if surface.added_signal_strings:
            lines.append("")
            lines.append("Added signal string samples:")
            for sample in surface.added_signal_strings[: args.max_added_string_samples]:
                sample = sample.replace("`", "'")
                lines.append(f"- `{sample[:180]}`")
        lines.append("")

    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines) + "\n")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Rank changed surfaces from applesauce diff trees.")
    parser.add_argument("diff_dir", help="Diff directory containing trees/*.tsv")
    parser.add_argument("-o", "--out", help="Markdown output path")
    parser.add_argument("--json-out", help="JSON output path")
    parser.add_argument("--baseline-root", help="Baseline packet artifact root, e.g. artifacts/packet002.../26.4")
    parser.add_argument("--patched-root", help="Patched packet artifact root, e.g. artifacts/packet002.../26.5")
    parser.add_argument("--baseline-dyld", help="Baseline dyld selected root")
    parser.add_argument("--patched-dyld", help="Patched dyld selected root")
    parser.add_argument("--top", type=int, default=30, help="Rows in top table")
    parser.add_argument("--details", type=int, default=15, help="Detailed entries in Markdown")
    parser.add_argument("--max-file-bytes", type=int, default=8 * 1024 * 1024, help="Skip strings above this file size")
    parser.add_argument("--max-strings", type=int, default=20000, help="Maximum strings per file to score")
    parser.add_argument("--max-added-string-samples", type=int, default=8)
    parser.add_argument("--string-timeout", type=int, default=8)
    parser.add_argument(
        "--focus-regex",
        action="append",
        default=[],
        help="Regex matched against surface path. Repeated values are ORed.",
    )
    parser.add_argument(
        "--require-focus",
        action="store_true",
        help="Drop surfaces whose path does not match any --focus-regex.",
    )
    parser.add_argument("--focus-boost", type=int, default=20)
    parser.add_argument("--non-focus-penalty", type=int, default=25)
    args = parser.parse_args(argv)

    diff_dir = Path(args.diff_dir).resolve()
    context = parse_context(diff_dir)
    roots = category_roots(context, args)
    surfaces = load_surfaces(diff_dir)
    if args.require_focus and args.focus_regex:
        surfaces = [surface for surface in surfaces if path_matches_any(surface.path, args.focus_regex)]
    ranked = sorted((score_surface(surface, roots, args) for surface in surfaces), key=lambda s: (-s.score, s.path))

    out = Path(args.out).resolve() if args.out else diff_dir / "surface-rank.md"
    json_out = Path(args.json_out).resolve() if args.json_out else diff_dir / "surface-rank.json"
    render_markdown(ranked, args, out)
    json_out.write_text(json.dumps([as_dict(s) for s in ranked], indent=2) + "\n")
    print(out)
    print(json_out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
