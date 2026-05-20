# Capture-WindowsFootprint.ps1
#
# Lightweight snapshot for the deploy pipeline's footprint diff. Earlier
# versions walked the entire ProgramFiles/AppData tree which took 5+ minutes
# on GitHub-hosted Windows runners (Visual Studio, Android SDK, dotnet etc.
# = 200k+ files). Robopack's approach is smarter: use the ARP (Add/Remove
# Programs) registry as the authoritative "what's installed" source. After
# install, the NEW ARP entry tells us the InstallLocation, and we enumerate
# only THAT directory for the per-file footprint.
#
# Modes:
#   -Mode arp        : ARP entries + key registry blocks. ~5 seconds total.
#                       The "before" snapshot uses this; very fast.
#   -Mode full       : ARP + ALL files under the install-location of every
#                       ARP entry (post-install snapshot uses this — only one
#                       directory, since we know which ARP entry was added).
#
# Snapshot shape (matches before-/after-/leftovers schema):
#   {
#     "capturedAt": "...",
#     "files":    [ { path, size, lastWriteTime, version }, ... ],
#     "registry": [ { hive, key, name, type, data }, ... ],
#     "arp":      [ { key, displayName, publisher, displayVersion,
#                     installLocation, uninstallString,
#                     quietUninstallString, estimatedSize }, ... ]
#   }

param(
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [ValidateSet('arp','full')]
    [string]$Mode = 'arp',

    [Parameter(Mandatory = $false)]
    [int]$MaxFilesPerInstall = 5000,

    # When set, in 'full' mode we only enumerate files for ARP entries that
    # don't exist in the baseline snapshot — i.e. only the newly-installed
    # app's footprint, not the entire pre-existing inventory of every
    # tool already on the runner.
    [Parameter(Mandatory = $false)]
    [string]$BaselinePath
)

$ErrorActionPreference = 'Continue'

function ConvertTo-PortablePath {
    param([string]$Path)
    if (-not $Path) { return $Path }
    # Order matters: ProgramFilesX86 must be checked before ProgramFiles
    # because the x86 path is a string-prefix of itself on English Windows.
    $candidates = @(
        @{ Pattern = ([Environment]::GetFolderPath('ProgramFilesX86'));   Token = '[{ProgramFilesX86}]' }
        @{ Pattern = ([Environment]::GetFolderPath('ProgramFiles'));      Token = '[{ProgramFilesX64}]' }
        @{ Pattern = ([Environment]::GetFolderPath('CommonProgramFiles'));Token = '[{CommonProgramFiles}]' }
        @{ Pattern = "$env:ProgramData";                                  Token = '[{CommonAppData}]' }
        @{ Pattern = "$env:LocalAppData";                                 Token = '[{LocalAppData}]' }
        @{ Pattern = "$env:AppData";                                      Token = '[{AppData}]' }
        @{ Pattern = "$env:SystemRoot";                                   Token = '[{WindowsDir}]' }
        @{ Pattern = "$env:Public";                                       Token = '[{Public}]' }
    )
    foreach ($candidate in $candidates) {
        if ($candidate.Pattern -and $Path.StartsWith($candidate.Pattern, [StringComparison]::OrdinalIgnoreCase)) {
            return ($candidate.Token + $Path.Substring($candidate.Pattern.Length))
        }
    }
    return $Path
}

function Get-ArpSnapshot {
    $arp = New-Object System.Collections.Generic.List[object]
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    foreach ($k in $keys) {
        if (-not (Test-Path -LiteralPath $k)) { continue }
        Get-ChildItem -LiteralPath $k -ErrorAction SilentlyContinue | ForEach-Object {
            $props = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
            if (-not $props) { return }
            # Filter out empty/system entries that pollute the diff.
            if (-not $props.DisplayName -and -not $props.UninstallString) { return }
            $sizeText = [string]$props.EstimatedSize
            $size = 0
            if ($sizeText -match '^\d+$') { $size = [int64]$sizeText }
            $arp.Add([ordered]@{
                key                  = $_.PSChildName
                displayName          = [string]$props.DisplayName
                publisher            = [string]$props.Publisher
                displayVersion       = [string]$props.DisplayVersion
                installLocation      = [string]$props.InstallLocation
                uninstallString      = [string]$props.UninstallString
                quietUninstallString = [string]$props.QuietUninstallString
                estimatedSize        = $size
            }) | Out-Null
        }
    }
    return ,$arp.ToArray()
}

function Get-InstallLocationFiles {
    param([string]$InstallLocation, [int]$MaxItems)
    if (-not $InstallLocation -or -not (Test-Path -LiteralPath $InstallLocation)) { return @() }
    $items = New-Object System.Collections.Generic.List[object]
    try {
        $files = [System.IO.Directory]::EnumerateFiles($InstallLocation, '*', [System.IO.SearchOption]::AllDirectories)
        foreach ($f in $files) {
            if ($items.Count -ge $MaxItems) { break }
            try {
                $info = [System.IO.FileInfo]::new($f)
                $version = $null
                $ext = $info.Extension.ToLowerInvariant()
                if ($ext -in @('.exe','.dll','.sys','.ocx')) {
                    try {
                        $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($f)
                        $version = $vi.FileVersion
                    } catch {}
                }
                $items.Add([ordered]@{
                    path          = (ConvertTo-PortablePath $f)
                    size          = [int64]$info.Length
                    lastWriteTime = $info.LastWriteTimeUtc.ToString('o')
                    version       = $version
                }) | Out-Null
            } catch {}
        }
    } catch {}
    return ,$items.ToArray()
}

# Get the Run / RunOnce + Services entries — small but high-signal for the
# footprint (apps that auto-start or register a service).
function Get-AutoRunRegistrySnapshot {
    $items = New-Object System.Collections.Generic.List[object]
    $autorunKeys = @(
        @{ Hive = 'HKLM'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' },
        @{ Hive = 'HKLM'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' },
        @{ Hive = 'HKCU'; Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' },
        @{ Hive = 'HKLM'; Path = 'HKLM:\SYSTEM\CurrentControlSet\Services' }
    )
    foreach ($k in $autorunKeys) {
        if (-not (Test-Path -LiteralPath $k.Path)) { continue }
        try {
            $key = Get-Item -LiteralPath $k.Path -ErrorAction Stop
            foreach ($valName in $key.GetValueNames()) {
                try {
                    $val = $key.GetValue($valName, '')
                    $kind = $key.GetValueKind($valName).ToString()
                    $portable = $key.Name -replace '^HKEY_LOCAL_MACHINE\\', 'HKLM\' -replace '^HKEY_CURRENT_USER\\', 'HKCU\'
                    $items.Add([ordered]@{
                        hive = $k.Hive
                        key  = $portable
                        name = if ($valName) { $valName } else { '(default)' }
                        type = $kind
                        data = [string]$val
                    }) | Out-Null
                } catch {}
            }
        } catch {}
    }
    return ,$items.ToArray()
}

$result = [ordered]@{
    capturedAt = (Get-Date).ToUniversalTime().ToString('o')
    mode       = $Mode
    arp        = (Get-ArpSnapshot)
    registry   = (Get-AutoRunRegistrySnapshot)
    files      = @()
}

if ($Mode -eq 'full') {
    # Build the set of ARP keys that existed in the baseline so we only walk
    # NEW installs (huge speedup vs. walking every pre-installed tool's dir).
    $baselineArpKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($BaselinePath -and (Test-Path -LiteralPath $BaselinePath)) {
        try {
            $baseline = Get-Content -LiteralPath $BaselinePath -Raw | ConvertFrom-Json
            foreach ($e in @($baseline.arp)) {
                if ($e.key) { [void]$baselineArpKeys.Add([string]$e.key) }
            }
        } catch {
            Write-Warning "Could not parse baseline at $BaselinePath -- enumerating files for ALL ARP entries: $($_.Exception.Message)"
        }
    }

    $files = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $result.arp) {
        if (-not $entry.installLocation) { continue }
        if ($baselineArpKeys.Count -gt 0 -and $baselineArpKeys.Contains([string]$entry.key)) { continue }
        foreach ($f in Get-InstallLocationFiles -InstallLocation $entry.installLocation -MaxItems $MaxFilesPerInstall) {
            $files.Add($f) | Out-Null
        }
    }
    $result.files = ,$files.ToArray()
}

$result | ConvertTo-Json -Depth 12 -Compress | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host "Snapshot ($Mode) written to $OutputPath ($($result.arp.Count) ARP, $($result.files.Count) files, $($result.registry.Count) autorun reg values)"
