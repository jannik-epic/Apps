# sandbox-footprint.ps1
#
# Captures a snapshot of Windows system state for app-footprint comparisons.
# Designed to be invoked by the sandbox runner before install, after install,
# and after uninstall. The runner then diffs the three snapshots to produce
# `footprint_diff` (files+registry added by install) and `leftover_diff` (items
# still present after uninstall).
#
# A snapshot is a single JSON file with this shape:
#   {
#     "capturedAt": "2026-05-20T13:45:00Z",
#     "files":    [ { "path": "[{ProgramFilesX64}]\\Greenshot\\Greenshot.exe",
#                     "size": 262144, "lastWriteTime": "2026-03-20T13:45:00Z",
#                     "version": "1.3.315.16907" }, ... ],
#     "registry": [ { "hive": "HKLM",
#                     "key": "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Greenshot_is1",
#                     "name": "DisplayVersion", "type": "String", "data": "1.3.315" }, ... ],
#     "arp":      [ { "key": "Greenshot_is1", "displayName": "Greenshot 1.3.315",
#                     "publisher": "Greenshot", "displayVersion": "1.3.315" } ]
#   }
#
# All filesystem paths are normalized to portable templates so two devices with
# different drive layouts produce comparable footprints:
#   C:\Program Files\...       → [{ProgramFilesX64}]\...
#   C:\Program Files (x86)\... → [{ProgramFilesX86}]\...
#   C:\ProgramData\...         → [{CommonAppData}]\...
#   C:\Users\<u>\AppData\Local → [{LocalAppData}]\...
#   C:\Users\<u>\AppData\Roaming → [{AppData}]\...
#
# Defaults to a bounded depth + maximum entries to avoid blowing up CI minutes
# on enormous installs (e.g. SAP, Visual Studio).

param(
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [Parameter(Mandatory = $false)]
    [int]$MaxFiles = 20000,

    [Parameter(Mandatory = $false)]
    [int]$MaxRegistryValues = 20000
)

$ErrorActionPreference = 'Continue'

function ConvertTo-PortablePath {
    param([string]$Path)
    if (-not $Path) { return $Path }
    $candidates = @(
        @{ Pattern = ([Environment]::GetFolderPath('ProgramFiles'));      Token = '[{ProgramFilesX64}]' }
        @{ Pattern = ([Environment]::GetFolderPath('ProgramFilesX86'));   Token = '[{ProgramFilesX86}]' }
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

function Get-FileSnapshot {
    param([string[]]$Roots, [int]$MaxItems)
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($root in $Roots) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        try {
            Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue |
                ForEach-Object {
                    if ($items.Count -ge $MaxItems) { return }
                    $version = $null
                    if ($_.Extension -in @('.exe','.dll','.sys','.ocx')) {
                        try { $version = $_.VersionInfo.FileVersion } catch { $version = $null }
                    }
                    $items.Add([ordered]@{
                        path          = (ConvertTo-PortablePath $_.FullName)
                        size          = [int64]$_.Length
                        lastWriteTime = $_.LastWriteTimeUtc.ToString('o')
                        version       = $version
                    }) | Out-Null
                }
        } catch {
            # Swallow — partial snapshots are still useful for diff.
        }
    }
    return ,$items.ToArray()
}

function Get-RegistrySnapshot {
    param([object[]]$Roots, [int]$MaxValues)
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($root in $Roots) {
        $hiveLabel = $root.Hive
        $relativeKey = $root.Key
        $providerPath = $root.Path
        if (-not (Test-Path -LiteralPath $providerPath)) { continue }
        try {
            Get-ChildItem -LiteralPath $providerPath -Recurse -ErrorAction SilentlyContinue |
                ForEach-Object {
                    if ($items.Count -ge $MaxValues) { return }
                    $key = $_
                    $subKey = $key.PSPath
                    try {
                        $props = Get-ItemProperty -LiteralPath $subKey -ErrorAction SilentlyContinue
                        if ($null -eq $props) { return }
                        # Compute the relative key path under the hive label.
                        $keyName = $key.Name
                        $hivePrefix = ($key.PSDrive.Name + ':')
                        $portable = $keyName -replace ('^' + [regex]::Escape($key.PSDrive.Root)), $hivePrefix
                        $portable = $portable -replace ('^' + [regex]::Escape($hivePrefix)), ($hiveLabel + '\')
                        $props.PSObject.Properties |
                            Where-Object { $_.Name -notlike 'PS*' } |
                            ForEach-Object {
                                if ($items.Count -ge $MaxValues) { return }
                                $valueName = if ($_.Name -eq '(default)') { '(default)' } else { $_.Name }
                                $valueData = try { [string]$_.Value } catch { '' }
                                $valueType = try {
                                    (Get-ItemPropertyValue -LiteralPath $subKey -Name $_.Name -ErrorAction Stop |
                                        ForEach-Object { $_.GetType().Name })
                                } catch { 'String' }
                                $items.Add([ordered]@{
                                    hive = $hiveLabel
                                    key  = $portable
                                    name = $valueName
                                    type = $valueType
                                    data = $valueData
                                }) | Out-Null
                            }
                    } catch {}
                }
        } catch {}
    }
    return ,$items.ToArray()
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
            $arp.Add([ordered]@{
                key            = $_.PSChildName
                displayName    = [string]$props.DisplayName
                publisher      = [string]$props.Publisher
                displayVersion = [string]$props.DisplayVersion
                installLocation = [string]$props.InstallLocation
                uninstallString = [string]$props.UninstallString
                quietUninstallString = [string]$props.QuietUninstallString
                estimatedSize  = [int64]([double]([string]$props.EstimatedSize))
            }) | Out-Null
        }
    }
    return ,$arp.ToArray()
}

$fileRoots = @(
    [Environment]::GetFolderPath('ProgramFiles'),
    [Environment]::GetFolderPath('ProgramFilesX86'),
    "$env:ProgramData",
    "$env:LocalAppData",
    "$env:AppData"
)

$registryRoots = @(
    @{ Hive = 'HKLM'; Key = 'SOFTWARE'; Path = 'HKLM:\SOFTWARE' },
    @{ Hive = 'HKLM'; Key = 'SOFTWARE\WOW6432Node'; Path = 'HKLM:\SOFTWARE\WOW6432Node' },
    @{ Hive = 'HKCU'; Key = 'SOFTWARE'; Path = 'HKCU:\SOFTWARE' },
    @{ Hive = 'HKCR'; Key = ''; Path = 'HKCR:\' }
)

if (-not (Get-PSDrive -Name HKCR -ErrorAction SilentlyContinue)) {
    New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT | Out-Null
}

$snapshot = [ordered]@{
    capturedAt = (Get-Date).ToUniversalTime().ToString('o')
    files      = (Get-FileSnapshot -Roots $fileRoots -MaxItems $MaxFiles)
    registry   = (Get-RegistrySnapshot -Roots $registryRoots -MaxValues $MaxRegistryValues)
    arp        = (Get-ArpSnapshot)
}

$snapshot | ConvertTo-Json -Depth 12 -Compress | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host "Snapshot written to $OutputPath ($($snapshot.files.Count) files, $($snapshot.registry.Count) registry values, $($snapshot.arp.Count) ARP entries)"
