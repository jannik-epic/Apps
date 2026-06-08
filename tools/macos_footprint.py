#!/usr/bin/env python3
"""macOS footprint capture + diff for Vanguard VM validation.

This is the macOS analogue of Capture-WindowsFootprint.ps1 / Diff-WindowsFootprint.ps1.
It runs directly on the GitHub-hosted macos-latest runner (an ephemeral clean VM),
so no tart template or self-hosted Apple-silicon runner is required.

Two subcommands:

  snapshot --output before.json
      Record the set of files under the macOS install locations plus the
      installed pkgutil receipts. Cheap, path+size+mtime only.

  diff --before before.json --after after.json --output footprint.json [--leftovers]
      Compare two snapshots and emit a footprint document in the SAME shape the
      App Documentation payload expects (files[] / registry[] / arp[] / summary),
      so the renderer needs no macOS-specific code. Newly-added files become
      files[]; new pkgutil receipts + .app bundles become arp[]; new .plist
      files (preferences / LaunchAgents / LaunchDaemons) become registry[]
      (the macOS equivalent of registry values). With --leftovers the same
      "present-after-but-not-in-baseline" set is emitted, i.e. what survived
      uninstall.
"""

import argparse
import json
import os
import plistlib
import subprocess
import sys
import time

# Install locations an app package typically writes into. Kept deliberately
# bounded so the snapshot stays fast on the shared runner.
SCAN_ROOTS = [
    "/Applications",
    "/Library/LaunchAgents",
    "/Library/LaunchDaemons",
    "/Library/Application Support",
    "/Library/PrivilegedHelperTools",
    os.path.expanduser("~/Applications"),
    os.path.expanduser("~/Library/LaunchAgents"),
    os.path.expanduser("~/Library/Application Support"),
    os.path.expanduser("~/Library/Preferences"),
]

# Hard cap on enumerated paths so a pathological tree cannot blow up the runner
# or the published JSON. Truncation is surfaced in the summary.
MAX_FILES = 20000
# Cap on how many file rows we publish in the diff (the long tail is noise).
MAX_DIFF_FILES = 5000


def enumerate_files(root):
    out = {}
    if not os.path.isdir(root):
        return out
    count = 0
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for name in filenames:
            path = os.path.join(dirpath, name)
            try:
                st = os.lstat(path)
            except OSError:
                continue
            out[path] = {"size": int(st.st_size), "mtime": float(st.st_mtime)}
            count += 1
            if count >= MAX_FILES:
                return out
    return out


def list_receipts():
    try:
        proc = subprocess.run(
            ["pkgutil", "--pkgs"], capture_output=True, text=True, timeout=120
        )
        if proc.returncode == 0:
            return sorted(p.strip() for p in proc.stdout.splitlines() if p.strip())
    except Exception:
        pass
    return []


def take_snapshot(output_path):
    files = {}
    for root in SCAN_ROOTS:
        files.update(enumerate_files(root))
    snapshot = {
        "capturedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "files": files,
        "receipts": list_receipts(),
    }
    with open(output_path, "w", encoding="utf-8") as fh:
        json.dump(snapshot, fh)
    print("snapshot wrote {} files, {} receipts -> {}".format(
        len(files), len(snapshot["receipts"]), output_path))


def load_snapshot(path):
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    return data.get("files", {}) or {}, data.get("receipts", []) or []


def iso(mtime):
    try:
        return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(mtime))
    except Exception:
        return None


def bundle_version(app_path):
    """Read CFBundleShortVersionString from an .app bundle's Info.plist."""
    info = os.path.join(app_path, "Contents", "Info.plist")
    try:
        with open(info, "rb") as fh:
            plist = plistlib.load(fh)
        return str(
            plist.get("CFBundleShortVersionString")
            or plist.get("CFBundleVersion")
            or ""
        ) or None
    except Exception:
        return None


def bundle_identifier(app_path):
    info = os.path.join(app_path, "Contents", "Info.plist")
    try:
        with open(info, "rb") as fh:
            plist = plistlib.load(fh)
        return str(plist.get("CFBundleIdentifier") or "") or None
    except Exception:
        return None


def receipt_info(pkgid):
    """pkgutil --pkg-info -> (version, install-location)."""
    version = None
    location = None
    try:
        proc = subprocess.run(
            ["pkgutil", "--pkg-info", pkgid],
            capture_output=True, text=True, timeout=60,
        )
        if proc.returncode == 0:
            for line in proc.stdout.splitlines():
                if line.startswith("version:"):
                    version = line.split(":", 1)[1].strip() or None
                elif line.startswith("location:"):
                    location = line.split(":", 1)[1].strip() or None
    except Exception:
        pass
    return version, location


def top_app_bundle(path):
    """Return the '<...>.app' prefix of a path if it lives inside an app bundle."""
    marker = ".app/"
    idx = path.find(marker)
    if idx == -1:
        return path if path.endswith(".app") else None
    return path[: idx + len(".app")]


def build_diff(before_files, after_files, before_receipts, after_receipts):
    added_paths = sorted(p for p in after_files.keys() if p not in before_files)
    new_receipts = sorted(set(after_receipts) - set(before_receipts))

    files = []
    registry = []
    arp = []
    seen_app_bundles = set()
    total_size = 0

    for path in added_paths:
        meta = after_files.get(path, {})
        size = int(meta.get("size") or 0)
        total_size += size
        if len(files) < MAX_DIFF_FILES:
            row = {
                "path": path,
                "size": size,
                "lastWriteTime": iso(meta.get("mtime")),
            }
            # Surface a version for the app bundle's primary executable plist.
            if path.endswith("Contents/Info.plist"):
                bundle = path[: -len("/Contents/Info.plist")]
                if bundle.endswith(".app"):
                    row["version"] = bundle_version(bundle)
            files.append(row)

        # macOS "registry" equivalent: preference/launch plists.
        lower = path.lower()
        if lower.endswith(".plist") and (
            "/preferences/" in lower
            or "/launchagents/" in lower
            or "/launchdaemons/" in lower
        ):
            registry.append({
                "hive": "LaunchDaemons" if "/launchdaemons/" in lower
                else "LaunchAgents" if "/launchagents/" in lower
                else "Preferences",
                "key": os.path.dirname(path),
                "name": os.path.basename(path),
                "type": "plist",
                "data": path,
            })

        # New .app bundles become ARP-style installed-application rows.
        bundle = top_app_bundle(path)
        if bundle and bundle.endswith(".app") and bundle not in seen_app_bundles:
            seen_app_bundles.add(bundle)
            arp.append({
                "key": bundle_identifier(bundle) or bundle,
                "displayName": os.path.basename(bundle)[: -len(".app")],
                "publisher": None,
                "displayVersion": bundle_version(bundle),
            })

    for pkgid in new_receipts:
        version, location = receipt_info(pkgid)
        arp.append({
            "key": pkgid,
            "displayName": pkgid,
            "publisher": None,
            "displayVersion": version,
            "installLocation": location,
        })

    return {
        "files": files,
        "registry": registry,
        "arp": arp,
        "summary": {
            "fileCount": len(added_paths),
            "totalFileSize": total_size,
            "registryValueCount": len(registry),
            "arpEntries": len(arp),
            "filesTruncated": len(added_paths) > MAX_DIFF_FILES,
        },
    }


def run_diff(before_path, after_path, output_path):
    before_files, before_receipts = load_snapshot(before_path)
    after_files, after_receipts = load_snapshot(after_path)
    doc = build_diff(before_files, after_files, before_receipts, after_receipts)
    with open(output_path, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2)
    print("diff wrote {} files, {} registry, {} arp -> {}".format(
        len(doc["files"]), len(doc["registry"]), len(doc["arp"]), output_path))


def main():
    parser = argparse.ArgumentParser(description="macOS footprint capture + diff")
    sub = parser.add_subparsers(dest="command", required=True)

    snap = sub.add_parser("snapshot", help="capture a filesystem + receipt snapshot")
    snap.add_argument("--output", required=True)

    diff = sub.add_parser("diff", help="diff two snapshots into a footprint document")
    diff.add_argument("--before", required=True)
    diff.add_argument("--after", required=True)
    diff.add_argument("--output", required=True)
    diff.add_argument("--leftovers", action="store_true",
                      help="label semantics only; the computed set is identical")

    args = parser.parse_args()
    try:
        if args.command == "snapshot":
            take_snapshot(args.output)
        elif args.command == "diff":
            run_diff(args.before, args.after, args.output)
    except Exception as exc:  # never hard-fail the validation step on footprint issues
        print("macos_footprint {} failed: {}".format(args.command, exc), file=sys.stderr)
        # Emit an empty-but-valid document so downstream copy/parse still works.
        if args.command == "diff":
            try:
                with open(args.output, "w", encoding="utf-8") as fh:
                    json.dump({"files": [], "registry": [], "arp": [],
                               "summary": {"fileCount": 0, "totalFileSize": 0,
                                           "registryValueCount": 0, "arpEntries": 0}}, fh)
            except Exception:
                pass
        sys.exit(0)


if __name__ == "__main__":
    main()
