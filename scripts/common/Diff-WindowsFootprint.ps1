# Diff-WindowsFootprint.ps1
#
# Compares two Capture-WindowsFootprint.ps1 snapshots and emits a diff JSON.
# Used by the deploy pipeline to compute:
#   footprint_diff = (after_install)  -  (before_install)   (= what the app added)
#   leftover_diff  = (after_uninstall) - (before_install)   (= what survived uninstall)
#
# Output JSON shape:
#   {
#     "files":    [ { path, size, lastWriteTime, version }, ... ],
#     "registry": [ { hive, key, name, type, data }, ... ],
#     "arp":      [ { key, displayName, publisher, displayVersion, ... }, ... ],
#     "summary":  {
#       "fileCount": 99, "totalFileSize": 9591816,
#       "registryValueCount": 38, "arpEntries": 1
#     }
#   }

param(
    [Parameter(Mandatory = $true)]
    [string]$BeforePath,

    [Parameter(Mandatory = $true)]
    [string]$AfterPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $BeforePath)) { throw "Before snapshot missing: $BeforePath" }
if (-not (Test-Path -LiteralPath $AfterPath)) { throw "After snapshot missing: $AfterPath" }

$before = Get-Content -LiteralPath $BeforePath -Raw | ConvertFrom-Json
$after  = Get-Content -LiteralPath $AfterPath  -Raw | ConvertFrom-Json

function Diff-ById {
    param([object[]]$Before, [object[]]$After, [string[]]$KeyFields)
    $set = New-Object System.Collections.Generic.HashSet[string]
    foreach ($b in $Before) {
        $id = ($KeyFields | ForEach-Object { [string]$b.$_ }) -join '|'
        [void]$set.Add($id)
    }
    $delta = New-Object System.Collections.Generic.List[object]
    foreach ($a in $After) {
        $id = ($KeyFields | ForEach-Object { [string]$a.$_ }) -join '|'
        if (-not $set.Contains($id)) { $delta.Add($a) | Out-Null }
    }
    # Use the typed array cast to keep ConvertTo-Json output stable: with
    # comma-prefix on a 0-element List the JSON serialiser emitted [[]] instead
    # of []. Casting the result to [object[]] yields a real JSON array for
    # both empty and populated cases.
    return [object[]]$delta.ToArray()
}

$fileDelta     = Diff-ById -Before $before.files    -After $after.files    -KeyFields @('path')
$registryDelta = Diff-ById -Before $before.registry -After $after.registry -KeyFields @('hive','key','name')
$arpDelta      = Diff-ById -Before $before.arp      -After $after.arp      -KeyFields @('key')

$totalSize = 0
foreach ($f in $fileDelta) { if ($f.size) { $totalSize += [int64]$f.size } }

$result = [ordered]@{
    files    = $fileDelta
    registry = $registryDelta
    arp      = $arpDelta
    summary  = [ordered]@{
        fileCount          = $fileDelta.Count
        totalFileSize      = [int64]$totalSize
        registryValueCount = $registryDelta.Count
        arpEntries         = $arpDelta.Count
    }
    beforeCapturedAt = $before.capturedAt
    afterCapturedAt  = $after.capturedAt
}

$result | ConvertTo-Json -Depth 12 -Compress | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host "Diff written to $OutputPath"
Write-Host "  Files added:           $($fileDelta.Count) ($($totalSize) bytes)"
Write-Host "  Registry values added: $($registryDelta.Count)"
Write-Host "  ARP entries added:     $($arpDelta.Count)"
