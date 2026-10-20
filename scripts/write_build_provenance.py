#!/usr/bin/env python3
"""Write a privacy-safe source/build fingerprint beside a packaged Mac app."""

from __future__ import annotations

import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def run(*args: str) -> str:
    result = subprocess.run(args, cwd=ROOT, text=True, capture_output=True, check=True)
    return (result.stdout + result.stderr).strip()


def required_int(path: str, pattern: str) -> int:
    contents = (ROOT / path).read_text(encoding="utf-8")
    match = re.search(pattern, contents)
    if not match:
        raise RuntimeError(f"Unable to identify version in {path}")
    return int(match.group(1))


def source_files() -> list[Path]:
    candidates: set[Path] = set()
    for source_root in (
        ROOT / "Packages/RiverDiaryCore/Sources",
        ROOT / "ios/RiverDiary/RiverDiary",
        ROOT / "macos/RiverDiaryMac/Sources/RiverDiaryMac",
    ):
        if source_root.exists():
            candidates.update(
                path for path in source_root.rglob("*")
                if path.is_file() and path.suffix == ".swift"
            )

    direct_files = (
        "Packages/RiverDiaryCore/Package.swift",
        "macos/RiverDiaryMac/Package.swift",
        "macos/RiverDiaryMac/Package.resolved",
        "macos/RiverDiaryMac/make_app.sh",
        "macos/RiverDiaryMac/Sources/RiverDiaryMac/Resources/AppIcon.icns",
        "macos/RiverDiaryMac/Sources/RiverDiaryMac/Resources/ThirdPartyNotices.md",
        "ios/RiverDiary/RiverDiary.xcodeproj/project.pbxproj",
        "ios/RiverDiary/Info.plist",
        "scripts/select_xcode.sh",
        "scripts/write_build_provenance.py",
    )
    candidates.update(ROOT / item for item in direct_files if (ROOT / item).is_file())
    # The private snapshot is intentionally excluded from the fingerprint manifest.
    return sorted((path for path in candidates if path.name != "data.json"), key=lambda path: path.as_posix())


def fingerprint(paths: list[Path]) -> tuple[str, list[dict[str, str]]]:
    digest = hashlib.sha256()
    manifest: list[dict[str, str]] = []
    for path in paths:
        relative = path.relative_to(ROOT).as_posix()
        content_hash = hashlib.sha256(path.read_bytes()).hexdigest()
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(bytes.fromhex(content_hash))
        digest.update(b"\0")
        manifest.append({"path": relative, "sha256": content_hash})
    return digest.hexdigest(), manifest


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: write_build_provenance.py <app-bundle> <output-json>", file=sys.stderr)
        return 64

    app_bundle = Path(sys.argv[1]).resolve()
    output = Path(sys.argv[2]).resolve()
    info_path = app_bundle / "Contents/Info.plist"
    with info_path.open("rb") as handle:
        info = plistlib.load(handle)

    sources = source_files()
    source_hash, manifest = fingerprint(sources)
    status = run("git", "status", "--porcelain=v1", "--untracked-files=all")
    swift_executable = os.environ.get("RIVER_SWIFT_EXECUTABLE", "/usr/bin/swift")
    swift_version = run(swift_executable, "--version").splitlines()[0]
    signature = run("codesign", "--display", "--verbose=4", str(app_bundle))
    cd_hash = re.search(r"^CDHash=(\w+)$", signature, re.MULTILINE)
    if not cd_hash:
        raise RuntimeError("codesign did not report a CodeDirectory hash")

    identity = os.environ.get("CODESIGN_IDENTITY", "-")
    provenance = {
        "provenanceSchema": 1,
        "generatedAtUTC": datetime.now(timezone.utc).isoformat(),
        "app": {
            "name": info.get("CFBundleName"),
            "bundleIdentifier": info.get("CFBundleIdentifier"),
            "version": info.get("CFBundleShortVersionString"),
            "build": info.get("CFBundleVersion"),
            "minimumOS": info.get("LSMinimumSystemVersion"),
        },
        "build": {
            "configuration": os.environ.get("RIVER_BUILD_CONFIG", "release"),
            "swiftVersion": swift_version,
            "sdk": Path(os.environ.get("SDKROOT", "unknown")).name,
            "signingMode": "ad-hoc" if identity == "-" else "configured-identity",
            "codeDirectoryHash": cd_hash.group(1),
            "bundledDiarySnapshot": False,
        },
        "source": {
            "revision": run("git", "rev-parse", "HEAD"),
            "workingTreeDirty": bool(status),
            "workingTreeStatusEntryCount": len(status.splitlines()),
            "fileCount": len(manifest),
            "fingerprintSHA256": source_hash,
            "files": manifest,
            "packageLockSHA256": hashlib.sha256(
                (ROOT / "macos/RiverDiaryMac/Package.resolved").read_bytes()
            ).hexdigest(),
        },
        "schemas": {
            "macDatabase": required_int(
                "macos/RiverDiaryMac/Sources/RiverDiaryMac/Infrastructure/Database/V2Store.swift",
                r"supportedSchemaVersion:\s*Int32\s*=\s*(\d+)",
            ),
            "iosDatabase": required_int(
                "ios/RiverDiary/RiverDiary/Infrastructure/Database/RiverLocalDatabase.swift",
                r"currentSchemaVersion:\s*Int32\s*=\s*(\d+)",
            ),
            "replicationProtocolMinimum": required_int(
                "Packages/RiverDiaryCore/Sources/RiverDiaryCore/ReplicationCrypto.swift",
                r"minimumCompatibleProtocolVersion\s*=\s*(\d+)",
            ),
            "replicationProtocolCurrent": required_int(
                "Packages/RiverDiaryCore/Sources/RiverDiaryCore/ReplicationCrypto.swift",
                r"currentProtocolVersion\s*=\s*(\d+)",
            ),
            "backupProtocol": required_int(
                "Packages/RiverDiaryCore/Sources/RiverDiaryCore/LocalBackup.swift",
                r"currentProtocolVersion\s*=\s*(\d+)",
            ),
            "backupSchema": required_int(
                "Packages/RiverDiaryCore/Sources/RiverDiaryCore/LocalBackup.swift",
                r"currentSchemaVersion\s*=\s*(\d+)",
            ),
        },
        "privacy": {
            "diarySnapshotPolicy": "excluded from packaged resources; connect/import explicitly after install",
            "excludedSnapshotPaths": ["data/data.json", "macos/RiverDiaryMac/Sources/RiverDiaryMac/Resources/data.json"],
        },
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(provenance, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
