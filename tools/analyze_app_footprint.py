#!/usr/bin/env python3
"""Analyze macOS app footprint by comparing system state before/after installation.

This script:
1. Takes a snapshot before installation
2. Installs the cask
3. Analyzes installed files and system changes
4. Uninstalls the app
5. Checks what files remain
6. Generates a detailed deployment footprint report
"""

from __future__ import annotations

import json
import logging
import os
import plistlib
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

LOGGER = logging.getLogger("footprint-analyzer")


@dataclass
class FileEntry:
    """Represents a file with its metadata."""
    path: str
    size: int
    exists_after_uninstall: bool = False


@dataclass
class AppFootprint:
    """Complete app footprint analysis."""
    app_name: str
    version: str
    publisher: str
    bundle_id: str
    installed_size: int
    total_files: int
    files_left_after_uninstall: int
    size_left_after_uninstall: int
    files: list[FileEntry]
    launch_agents: list[str]
    launch_daemons: list[str]
    preferences: list[str]
    application_support: list[str]


def run_command(cmd: list[str], check: bool = True) -> subprocess.CompletedProcess:
    """Run a shell command and return the result."""
    result = subprocess.run(
        cmd,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and result.returncode != 0:
        raise RuntimeError(f"Command {' '.join(cmd)} failed: {result.stderr}")
    return result


def find_files_recursively(directory: Path) -> dict[str, int]:
    """Recursively find all files in a directory and their sizes."""
    files = {}
    if not directory.exists():
        return files

    try:
        for item in directory.rglob("*"):
            if item.is_file() and not item.is_symlink():
                try:
                    files[str(item)] = item.stat().st_size
                except (OSError, PermissionError):
                    LOGGER.warning("Cannot access file: %s", item)
    except (OSError, PermissionError) as exc:
        LOGGER.warning("Cannot access directory %s: %s", directory, exc)

    return files


def get_system_snapshot() -> dict[str, int]:
    """Take a snapshot of relevant system directories."""
    snapshot = {}

    # Directories to monitor
    directories = [
        Path("/Applications"),
        Path.home() / "Library" / "Application Support",
        Path.home() / "Library" / "Preferences",
        Path.home() / "Library" / "Caches",
        Path.home() / "Library" / "LaunchAgents",
        Path("/Library/Application Support"),
        Path("/Library/Preferences"),
        Path("/Library/LaunchAgents"),
        Path("/Library/LaunchDaemons"),
    ]

    for directory in directories:
        snapshot.update(find_files_recursively(directory))

    return snapshot


def analyze_cask_footprint(cask_id: str) -> AppFootprint:
    """Analyze the complete footprint of a Homebrew cask."""
    LOGGER.info("Starting footprint analysis for %s", cask_id)

    # Get cask metadata
    LOGGER.info("Fetching cask metadata...")
    result = run_command(["brew", "info", "--cask", "--json=v2", cask_id])
    cask_data = json.loads(result.stdout)["casks"][0]

    app_name = cask_data.get("name", [cask_id])[0] if cask_data.get("name") else cask_id
    version = cask_data.get("version", "Unknown")
    homepage = cask_data.get("homepage", "")

    # Take snapshot before installation
    LOGGER.info("Taking pre-installation snapshot...")
    before_snapshot = get_system_snapshot()

    # Install the cask
    LOGGER.info("Installing cask %s...", cask_id)
    run_command(["brew", "install", "--cask", cask_id])

    # Take snapshot after installation
    LOGGER.info("Taking post-installation snapshot...")
    after_snapshot = get_system_snapshot()

    # Find new files
    new_files = {
        path: size
        for path, size in after_snapshot.items()
        if path not in before_snapshot
    }

    LOGGER.info("Found %d new files", len(new_files))

    # Find the app bundle and get its info
    bundle_id = "Unknown"
    app_path = None

    for path in new_files:
        if path.endswith(".app/Contents/Info.plist"):
            app_path = Path(path).parent.parent
            try:
                with open(path, "rb") as f:
                    plist = plistlib.load(f)
                    bundle_id = plist.get("CFBundleIdentifier", "Unknown")
                    if "CFBundleShortVersionString" in plist:
                        version = plist["CFBundleShortVersionString"]
                    break
            except Exception as exc:
                LOGGER.warning("Could not read Info.plist: %s", exc)

    # Categorize files
    launch_agents = [p for p in new_files if "/LaunchAgents/" in p]
    launch_daemons = [p for p in new_files if "/LaunchDaemons/" in p]
    preferences = [p for p in new_files if "/Preferences/" in p]
    app_support = [p for p in new_files if "/Application Support/" in p]

    # Uninstall the app
    LOGGER.info("Uninstalling cask %s...", cask_id)
    run_command(["brew", "uninstall", "--cask", cask_id], check=False)

    # Take snapshot after uninstall
    LOGGER.info("Taking post-uninstall snapshot...")
    after_uninstall_snapshot = get_system_snapshot()

    # Find files that remain
    file_entries = []
    files_left = 0
    size_left = 0

    for path, size in new_files.items():
        exists_after = path in after_uninstall_snapshot
        file_entries.append(FileEntry(
            path=path,
            size=size,
            exists_after_uninstall=exists_after,
        ))
        if exists_after:
            files_left += 1
            size_left += size

    # Sort files by path
    file_entries.sort(key=lambda f: f.path)

    total_size = sum(f.size for f in file_entries)

    publisher = cask_data.get("tap", "Homebrew")
    if "/" in publisher:
        publisher = publisher.split("/")[0]

    footprint = AppFootprint(
        app_name=app_name,
        version=version,
        publisher=publisher,
        bundle_id=bundle_id,
        installed_size=total_size,
        total_files=len(file_entries),
        files_left_after_uninstall=files_left,
        size_left_after_uninstall=size_left,
        files=file_entries,
        launch_agents=launch_agents,
        launch_daemons=launch_daemons,
        preferences=preferences,
        application_support=app_support,
    )

    LOGGER.info("Footprint analysis complete")
    return footprint


def format_size(size_bytes: int) -> str:
    """Format size in bytes to human-readable format."""
    for unit in ["B", "KB", "MB", "GB"]:
        if size_bytes < 1024:
            return f"{size_bytes:.2f} {unit}"
        size_bytes /= 1024
    return f"{size_bytes:.2f} TB"


def generate_report(footprint: AppFootprint, output_path: Path) -> None:
    """Generate a detailed text report for packaging and deployment review."""
    lines = []

    # Header
    lines.append(f"{footprint.app_name} {footprint.version} - macOS App Footprint Report")
    lines.append("=" * 80)
    lines.append("")

    # App metadata
    lines.append("App Information")
    lines.append("-" * 80)
    lines.append(f"App name:              {footprint.app_name}")
    lines.append(f"App version:           {footprint.version}")
    lines.append(f"Publisher:             {footprint.publisher}")
    lines.append(f"Bundle ID:             {footprint.bundle_id}")
    lines.append(f"Installer:             Homebrew Cask")
    lines.append(f"Installer scope:       User/System")
    lines.append("")

    # Commands
    lines.append("Install/Uninstall Commands")
    lines.append("-" * 80)
    lines.append(f"Install command:       brew install --cask {footprint.bundle_id.split('.')[-1].lower()}")
    lines.append(f"Uninstall command:     brew uninstall --cask {footprint.bundle_id.split('.')[-1].lower()}")
    lines.append("")

    # Size statistics
    lines.append("Installation Statistics")
    lines.append("-" * 80)
    lines.append(f"Installed size:        {format_size(footprint.installed_size)} ({footprint.installed_size:,} bytes)")
    lines.append(f"Total files:           {footprint.total_files} files")

    if footprint.files_left_after_uninstall > 0:
        percentage = (footprint.files_left_after_uninstall / footprint.total_files) * 100
        lines.append(f"Left after uninstall:  {footprint.files_left_after_uninstall} files, {format_size(footprint.size_left_after_uninstall)} - {percentage:.1f}%")
    else:
        lines.append(f"Left after uninstall:  0 files - Clean uninstall")

    lines.append("")

    # Detection methods
    lines.append("Detection Methods (for Intune)")
    lines.append("-" * 80)
    lines.append(f"Bundle ID:             {footprint.bundle_id}")
    lines.append(f"Version:               {footprint.version}")
    lines.append(f"App Path:              /Applications/{footprint.app_name}.app")
    lines.append("")

    # System modifications
    if footprint.launch_agents:
        lines.append("Launch Agents")
        lines.append("-" * 80)
        for agent in footprint.launch_agents:
            lines.append(f"  {Path(agent).name}")
        lines.append("")

    if footprint.launch_daemons:
        lines.append("Launch Daemons")
        lines.append("-" * 80)
        for daemon in footprint.launch_daemons:
            lines.append(f"  {Path(daemon).name}")
        lines.append("")

    if footprint.preferences:
        lines.append(f"Preferences ({len(footprint.preferences)} files)")
        lines.append("-" * 80)
        for pref in footprint.preferences[:10]:  # Show first 10
            lines.append(f"  {Path(pref).name}")
        if len(footprint.preferences) > 10:
            lines.append(f"  ... and {len(footprint.preferences) - 10} more")
        lines.append("")

    # Files listing
    lines.append("Files")
    lines.append("-" * 80)
    lines.append(f"{'Path':<80} {'Size':<15} {'Status'}")
    lines.append("-" * 80)

    for file_entry in footprint.files:
        status = "Left" if file_entry.exists_after_uninstall else "OK"
        path_display = file_entry.path

        # Shorten paths for readability
        if file_entry.path.startswith("/Applications/"):
            path_display = file_entry.path.replace("/Applications/", "[Applications]/")
        elif "/Library/Application Support/" in file_entry.path:
            path_display = file_entry.path.replace(str(Path.home()), "~")
        elif "/Library/" in file_entry.path:
            path_display = file_entry.path.replace(str(Path.home()), "~")

        # Truncate very long paths
        if len(path_display) > 75:
            path_display = "..." + path_display[-72:]

        lines.append(f"{path_display:<80} {format_size(file_entry.size):<15} {status}")

    lines.append("")
    lines.append("=" * 80)
    lines.append(f"Report generated for {footprint.app_name} {footprint.version}")
    lines.append("=" * 80)

    # Write report
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(lines), encoding="utf-8")
    LOGGER.info("Report written to %s", output_path)


if __name__ == "__main__":
    import argparse
    import sys

    logging.basicConfig(
        level=logging.INFO,
        format="[%(levelname)s] %(message)s",
    )

    parser = argparse.ArgumentParser(description="Analyze macOS app footprint")
    parser.add_argument("--cask", required=True, help="Homebrew cask ID")
    parser.add_argument("--output", default="footprint-report.txt", help="Output report path")

    args = parser.parse_args()

    try:
        footprint = analyze_cask_footprint(args.cask)
        generate_report(footprint, Path(args.output))
        print(f"\n✅ Footprint analysis complete!")
        print(f"📊 Report: {args.output}")
        print(f"📦 Size: {format_size(footprint.installed_size)}")
        print(f"📁 Files: {footprint.total_files}")
        if footprint.files_left_after_uninstall > 0:
            print(f"⚠️  Files remaining after uninstall: {footprint.files_left_after_uninstall}")
        else:
            print(f"✨ Clean uninstall - no files left behind")
    except Exception as exc:
        LOGGER.error("Footprint analysis failed: %s", exc)
        sys.exit(1)
