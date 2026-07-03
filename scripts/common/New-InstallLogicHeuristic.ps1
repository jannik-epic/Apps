# New-InstallLogicHeuristic.ps1
#
# Hardens default-generated install/uninstall logic for custom EXE installers
# (IntuneForge heuristic, ported). Only touches scripts that still carry the
# generator's default marker — operator-supplied overrides and AI-generated
# scripts are never modified.
#
#  - EXE installers are sniffed for their engine (Inno Setup / NSIS) and get
#    the correct silent switches when no install args were provided.
#  - The default EXE uninstall ("run the installer again with uninstall args")
#    is replaced with a registry-driven uninstall via QuietUninstallString /
#    UninstallString and engine-appropriate silent flags — the reliable way to
#    remove EXE-based installs.

param(
    [Parameter(Mandatory = $true)]
    [string]$InstallerPath,

    [Parameter(Mandatory = $true)]
    [string]$AppName,

    [Parameter(Mandatory = $false)]
    [string]$Publisher = '',

    [Parameter(Mandatory = $false)]
    [string]$InstallScriptPath = 'install_script.ps1',

    [Parameter(Mandatory = $false)]
    [string]$UninstallScriptPath = 'uninstall_script.ps1',

    [Parameter(Mandatory = $false)]
    [string]$InstallArgs = '',

    [Parameter(Mandatory = $false)]
    [string]$Engine = 'exe'
)

$ErrorActionPreference = 'Stop'
$marker = '# vanguard:default-logic'

if ($Engine -eq 'msi') {
    Write-Host 'MSI engine: default msiexec logic is already deterministic; heuristic not needed.'
    return
}
if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
    Write-Warning "Installer not found at $InstallerPath; skipping heuristic."
    return
}

# ---------------------------------------------------------------------------
# Sniff the installer engine from the binary header (first 512 KB).
# ---------------------------------------------------------------------------
$engineKind = 'generic'
try {
    $stream = [IO.File]::OpenRead($InstallerPath)
    try {
        $len = [Math]::Min(524288, $stream.Length)
        $bytes = New-Object byte[] $len
        [void]$stream.Read($bytes, 0, $len)
    } finally {
        $stream.Dispose()
    }
    $ascii = [Text.Encoding]::ASCII.GetString($bytes)
    if ($ascii -match 'Inno Setup') { $engineKind = 'inno' }
    elseif ($ascii -match 'Nullsoft') { $engineKind = 'nsis' }
} catch {
    Write-Warning "Could not sniff installer header: $($_.Exception.Message)"
}
Write-Host "Installer engine heuristic: $engineKind"

$defaultSilentArgs = switch ($engineKind) {
    'inno'  { '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /NOCANCEL /ALLUSERS' }
    'nsis'  { '/S' }
    default { '/S' }
}
$uninstallSilentArgs = switch ($engineKind) {
    'inno'  { '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' }
    'nsis'  { '/S' }
    default { '/S' }
}

function Escape-Single([string]$value) {
    return $value.Replace("'", "''")
}

# ---------------------------------------------------------------------------
# Install: only fill in silent args when the operator provided none and the
# script is still the generator default.
# ---------------------------------------------------------------------------
if ((Test-Path -LiteralPath $InstallScriptPath -PathType Leaf) -and -not $InstallArgs) {
    $current = Get-Content -LiteralPath $InstallScriptPath -Raw
    if ($current.Contains($marker)) {
        $updated = $current.Replace("-ArgumentList ''", "-ArgumentList '$defaultSilentArgs'")
        if ($updated -ne $current) {
            Set-Content -LiteralPath $InstallScriptPath -Value $updated -Encoding UTF8
            Write-Host "Applied $engineKind silent install args: $defaultSilentArgs"
        }
    }
}

# ---------------------------------------------------------------------------
# Uninstall: replace the default "re-run the installer" logic with a
# registry-driven uninstall.
# ---------------------------------------------------------------------------
if (Test-Path -LiteralPath $UninstallScriptPath -PathType Leaf) {
    $current = Get-Content -LiteralPath $UninstallScriptPath -Raw
    if ($current.Contains($marker)) {
        $escapedApp = Escape-Single $AppName
        $escapedPublisher = Escape-Single $Publisher
        $escapedArgs = Escape-Single $uninstallSilentArgs
        $registryUninstall = @"
$marker (heuristic: registry-driven EXE uninstall, engine=$engineKind)
`$ErrorActionPreference = 'Stop'
`$uninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)
foreach (`$root in `$uninstallKeys) {
    foreach (`$entry in Get-ChildItem -Path `$root -ErrorAction SilentlyContinue) {
        `$props = Get-ItemProperty -Path `$entry.PSPath -ErrorAction SilentlyContinue
        if (-not `$props -or -not `$props.DisplayName) { continue }
        if (`$props.DisplayName -notlike "*$escapedApp*") { continue }
        if ('$escapedPublisher' -and `$props.Publisher -and `$props.Publisher -notlike "*$escapedPublisher*") { continue }
        `$command = if (`$props.QuietUninstallString) { `$props.QuietUninstallString } else { `$props.UninstallString }
        if (-not `$command) { continue }
        if (-not `$props.QuietUninstallString -and `$command -notmatch '(?i)/S|/VERYSILENT|/quiet|/qn') {
            `$command = `$command.Trim() + ' $escapedArgs'
        }
        Write-Output "Uninstalling via: `$command"
        `$proc = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', `$command) -Wait -PassThru -WindowStyle Hidden
        exit `$proc.ExitCode
    }
}
Write-Output "No uninstall entry found for $escapedApp - treating as already removed."
exit 0
"@
        Set-Content -LiteralPath $UninstallScriptPath -Value $registryUninstall -Encoding UTF8
        Write-Host "Replaced default uninstall with registry-driven $engineKind uninstall."
    }
}
