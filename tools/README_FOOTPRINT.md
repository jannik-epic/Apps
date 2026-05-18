# macOS App Footprint Analyzer

This tool analyzes the complete system footprint of Homebrew cask applications and generates deployment-ready documentation.

## Features

- **Pre/Post Install Analysis**: Takes system snapshots before and after installation
- **Uninstall Detection**: Identifies files that remain after uninstallation
- **Comprehensive Reporting**: Generates detailed reports with:
  - App metadata (name, version, bundle ID)
  - Installation size and file counts
  - File listings with sizes
  - System modifications (Launch Agents/Daemons, preferences)
  - Detection methods for Intune
  - Files remaining after uninstall

## Usage

### Standalone

```bash
python3 tools/analyze_app_footprint.py --cask google-chrome --output report.txt
```

### Integrated with Packaging

```bash
python3 tools/intune_packager.py \
  --cask google-chrome \
  --output-dir output \
  --generate-footprint-report
```

### GitHub Actions Workflow

The footprint report is automatically generated when you run the "Deploy Homebrew App to Intune" workflow. The report will be:
1. Displayed in the workflow step output (first 50 lines)
2. Shown in the GitHub Actions summary
3. Uploaded as a downloadable artifact

## Report Format

The report includes deployment, detection, and cleanup sections:

```
Google Chrome 141.0.7390.77 - macOS App Footprint Report
================================================================================

App Information
--------------------------------------------------------------------------------
App name:              Google Chrome
App version:           141.0.7390.77
Publisher:             Google
Bundle ID:             com.google.Chrome
Installer:             Homebrew Cask
Installer scope:       User/System

Install/Uninstall Commands
--------------------------------------------------------------------------------
Install command:       brew install --cask google-chrome
Uninstall command:     brew uninstall --cask google-chrome

Installation Statistics
--------------------------------------------------------------------------------
Installed size:        295.45 MB (309,479,749 bytes)
Total files:           99 files
Left after uninstall:  8 files, 1.37 MB - 14.9%

Detection Methods (for Intune)
--------------------------------------------------------------------------------
Bundle ID:             com.google.Chrome
Version:               141.0.7390.77
App Path:              /Applications/Google Chrome.app

Files
--------------------------------------------------------------------------------
Path                                                              Size            Status
[Applications]/Google Chrome.app/...                              256.3 KB        OK
...
```

## How It Works

1. **System Snapshot**: Scans key directories before installation
   - /Applications
   - ~/Library (Application Support, Preferences, Caches, LaunchAgents)
   - /Library (Application Support, Preferences, LaunchAgents, LaunchDaemons)

2. **Installation**: Installs the cask using Homebrew

3. **Analysis**: Compares snapshots to identify new files

4. **Metadata Extraction**: Reads app bundle Info.plist for version and bundle ID

5. **Uninstall Test**: Removes the app and checks for remaining files

6. **Report Generation**: Creates a comprehensive text report

## Notes

- The analysis requires temporary installation/uninstallation of the app
- Requires Homebrew to be installed
- Some files (preferences, caches) may remain by design
- Run on a clean system for most accurate results
