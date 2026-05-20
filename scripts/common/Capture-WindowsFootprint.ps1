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
    [int]$MaxFiles = 80000,

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
    param([string[]]$Roots, [int]$MaxItems, [string[]]$SkipPrefixes)
    # Manual DFS with directory-level skip: EnumerateFiles(AllDirectories)
    # walks INTO skipped trees anyway. By pruning at the directory level we
    # avoid stat'ing 100k+ files inside Visual Studio / Android SDK / dotnet.
    $items = New-Object System.Collections.Generic.List[object]
    $skipPrefixesLower = @()
    foreach ($p in $SkipPrefixes) {
        if ($p) { $skipPrefixesLower += ,($p.TrimEnd('\').ToLowerInvariant()) }
    }
    $shouldSkip = {
        param([string]$dir)
        $lower = $dir.ToLowerInvariant()
        foreach ($prefix in $skipPrefixesLower) {
            if ($lower -eq $prefix -or $lower.StartsWith($prefix + '\')) { return $true }
        }
        return $false
    }
    $stack = New-Object System.Collections.Generic.Stack[string]
    foreach ($root in $Roots) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        $stack.Push($root)
    }
    while ($stack.Count -gt 0 -and $items.Count -lt $MaxItems) {
        $dir = $stack.Pop()
        if (& $shouldSkip $dir) { continue }
        # Files at this level.
        try {
            $files = [System.IO.Directory]::EnumerateFiles($dir, '*', [System.IO.SearchOption]::TopDirectoryOnly)
            foreach ($file in $files) {
                if ($items.Count -ge $MaxItems) { break }
                try {
                    $info = [System.IO.FileInfo]::new($file)
                    $version = $null
                    $ext = $info.Extension.ToLowerInvariant()
                    if ($ext -in @('.exe','.dll','.sys','.ocx')) {
                        try {
                            $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($file)
                            $version = $vi.FileVersion
                        } catch {}
                    }
                    $items.Add([ordered]@{
                        path          = (ConvertTo-PortablePath $file)
                        size          = [int64]$info.Length
                        lastWriteTime = $info.LastWriteTimeUtc.ToString('o')
                        version       = $version
                    }) | Out-Null
                } catch {
                    # File vanished or ACL denied — skip without breaking enum.
                }
            }
        } catch {
            # Read-protected dir — skip.
        }
        # Subdirectories (push only if not in skip list).
        try {
            $subs = [System.IO.Directory]::EnumerateDirectories($dir, '*', [System.IO.SearchOption]::TopDirectoryOnly)
            foreach ($sub in $subs) {
                if (-not (& $shouldSkip $sub)) { $stack.Push($sub) }
            }
        } catch {}
    }
    return ,$items.ToArray()
}

function Get-RegistrySnapshot {
    param(
        [object[]]$Roots,
        [int]$MaxValues,
        [int]$MaxDepth = 4,
        [string[]]$SkipKeyPatterns = @()
    )
    # Iterative BFS using .NET registry API — much faster than Get-ChildItem
    # -Recurse on registry hives, and we can bound depth + skip noisy subtrees
    # (Microsoft, .NET, Visual Studio) that dominate HKLM\SOFTWARE on a runner.
    $items = New-Object System.Collections.Generic.List[object]
    $skipRegex = @()
    foreach ($p in $SkipKeyPatterns) { if ($p) { $skipRegex += [regex]$p } }

    foreach ($root in $Roots) {
        $hiveLabel = $root.Hive
        $rootKeyName = $root.Key
        $hiveRoot = switch ($hiveLabel) {
            'HKLM' { [Microsoft.Win32.Registry]::LocalMachine }
            'HKCU' { [Microsoft.Win32.Registry]::CurrentUser }
            'HKCR' { [Microsoft.Win32.Registry]::ClassesRoot }
            'HKU'  { [Microsoft.Win32.Registry]::Users }
            default { $null }
        }
        if (-not $hiveRoot) { continue }
        $startKey = if ($rootKeyName) {
            try { $hiveRoot.OpenSubKey($rootKeyName, $false) } catch { $null }
        } else { $hiveRoot }
        if (-not $startKey) { continue }

        # Stack of (RegistryKey, portablePath, depth).
        $stack = New-Object System.Collections.Generic.Stack[object]
        $stack.Push(@($startKey, "${hiveLabel}\${rootKeyName}".TrimEnd('\'), 0))

        while ($stack.Count -gt 0) {
            if ($items.Count -ge $MaxValues) { break }
            $entry = $stack.Pop()
            $key = $entry[0]; $portable = $entry[1]; $depth = $entry[2]
            try {
                foreach ($valName in $key.GetValueNames()) {
                    if ($items.Count -ge $MaxValues) { break }
                    try {
                        $valueData = $key.GetValue($valName, '')
                        $kind = $key.GetValueKind($valName).ToString()
                        $items.Add([ordered]@{
                            hive = $hiveLabel
                            key  = $portable
                            name = if ($valName) { $valName } else { '(default)' }
                            type = $kind
                            data = [string]$valueData
                        }) | Out-Null
                    } catch {}
                }
                if ($depth -lt $MaxDepth) {
                    foreach ($subName in $key.GetSubKeyNames()) {
                        $childPath = "$portable\$subName"
                        $skip = $false
                        foreach ($rx in $skipRegex) {
                            if ($rx.IsMatch($childPath)) { $skip = $true; break }
                        }
                        if ($skip) { continue }
                        try {
                            $child = $key.OpenSubKey($subName, $false)
                            if ($child) { $stack.Push(@($child, $childPath, $depth + 1)) }
                        } catch {}
                    }
                }
            } catch {}
            if ($key -ne $startKey) { try { $key.Close() } catch {} }
        }
        try { $startKey.Close() } catch {}
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
# GitHub-hosted Windows runners ship with ~200k pre-installed files (Visual
# Studio, dotnet SDKs, hosted-tool-caches, package-manager caches). Excluding
# these system trees brings baseline snapshot time from ~6 min down to ~30 s
# without losing fidelity: app installs rarely touch them, and any that do
# would show as ARP/registry footprint anyway.
$fileSkipPrefixes = @(
    (Join-Path $env:ProgramFiles 'Microsoft Visual Studio'),
    (Join-Path $env:ProgramFiles 'dotnet'),
    (Join-Path $env:ProgramFiles 'PowerShell'),
    (Join-Path $env:ProgramFiles 'Android'),
    (Join-Path $env:ProgramFiles 'Java'),
    (Join-Path $env:ProgramFiles 'CMake'),
    (Join-Path $env:ProgramFiles 'WindowsApps'),
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio'),
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft SDKs'),
    (Join-Path ${env:ProgramFiles(x86)} 'Windows Kits'),
    (Join-Path ${env:ProgramFiles(x86)} 'Android'),
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft'),
    (Join-Path $env:ProgramData 'Microsoft\Windows Defender'),
    (Join-Path $env:ProgramData 'chocolatey'),
    (Join-Path $env:ProgramData 'Package Cache'),
    (Join-Path $env:LocalAppData 'Microsoft\Edge'),
    (Join-Path $env:LocalAppData 'Microsoft\Windows'),
    (Join-Path $env:LocalAppData 'Programs\Microsoft VS Code'),
    (Join-Path $env:LocalAppData 'Temp'),
    (Join-Path $env:AppData 'Microsoft'),
    'C:\hostedtoolcache',
    'C:\npm',
    'C:\Modules',
    'C:\tools'
)

$registryRoots = @(
    @{ Hive = 'HKLM'; Key = 'SOFTWARE' },
    @{ Hive = 'HKLM'; Key = 'SOFTWARE\WOW6432Node' },
    @{ Hive = 'HKCU'; Key = 'SOFTWARE' }
    # HKCR is intentionally skipped — it's mostly file-extension and CLSID
    # associations that are not meaningful for app-footprint diffing on a
    # GitHub runner with thousands of pre-registered handlers.
)

# Subkey paths that are pure system noise on the GitHub runner; skipping them
# brings the registry snapshot from ~5 min to <30 s. App installs that register
# under Microsoft (e.g. Microsoft\Edge plugins) are still captured under their
# own publisher key elsewhere.
$registrySkipPatterns = @(
    '\\Microsoft\\(Cryptography|Windows NT|EnterpriseCertificates|Active Setup|Internet Explorer|Edge|Office|VisualStudio|\.NETFramework|DotNETFramework)',
    '\\Wow6432Node\\Microsoft\\(Cryptography|Windows NT|VisualStudio|\.NETFramework)',
    '\\Classes\\(CLSID|TypeLib|Interface|AppID)',
    '\\Policies\\Microsoft\\'
)

$snapshot = [ordered]@{
    capturedAt = (Get-Date).ToUniversalTime().ToString('o')
    files      = (Get-FileSnapshot -Roots $fileRoots -MaxItems $MaxFiles -SkipPrefixes $fileSkipPrefixes)
    registry   = (Get-RegistrySnapshot -Roots $registryRoots -MaxValues $MaxRegistryValues -MaxDepth 5 -SkipKeyPatterns $registrySkipPatterns)
    arp        = (Get-ArpSnapshot)
}

$snapshot | ConvertTo-Json -Depth 12 -Compress | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host "Snapshot written to $OutputPath ($($snapshot.files.Count) files, $($snapshot.registry.Count) registry values, $($snapshot.arp.Count) ARP entries)"
