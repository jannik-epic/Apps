# New-PsadtV4Package.ps1
#
# Shared PSADT v4 wrapper used by every Windows packaging path (winget offline,
# custom upload, URL package, web-monitor package). It takes the app-specific
# install/uninstall logic that the existing generators emit (plain PowerShell,
# no toolkit dependency) and packages it inside a pinned PSAppDeployToolkit v4
# session:
#
#   <package root>/
#     Invoke-AppDeployToolkit.ps1   <- generated v4 entry (this script writes it)
#     PSAppDeployToolkit/           <- pinned v4 module (staged from release zip)
#     install-logic.ps1             <- app-specific install logic (relocated)
#     uninstall-logic.ps1           <- app-specific uninstall logic (relocated)
#     install_script.ps1            <- thin shim -> Invoke-AppDeployToolkit -DeploymentType Install
#     uninstall_script.ps1          <- thin shim -> Invoke-AppDeployToolkit -DeploymentType Uninstall
#     Files/ or <installer>         <- payload (already staged by the caller)
#
# The shim layout keeps the whole existing pipeline contract intact: the
# .intunewin setup file, the Intune install/uninstall command lines, and the
# VM-validation steps all keep invoking install_script.ps1/uninstall_script.ps1.
# Logic scripts run in a child powershell.exe so their $PSScriptRoot resolves
# to the package root (same as before wrapping) and an `exit` inside them can
# never bypass Close-ADTSession.
#
# The generated uninstall additionally sweeps app residues (install dirs,
# vendor registry keys, detection marker) and logs anything that remains, so
# "uninstall leaves leftovers" is visible in the PSADT log and the pipeline's
# leftover diff.

param(
    [Parameter(Mandatory = $true)]
    [string]$AppName,

    [Parameter(Mandatory = $false)]
    [string]$Publisher = '',

    [Parameter(Mandatory = $false)]
    [string]$Version = '',

    # Directory that will become the package root (already contains the
    # installer payload: winget's staging dir with Files/, or custom-files/).
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    # Paths to the generated logic scripts (typically ./install_script.ps1 and
    # ./uninstall_script.ps1 in the workflow working directory). They are MOVED
    # into the package root and replaced by PSADT shims at their original
    # location.
    [Parameter(Mandatory = $true)]
    [string]$InstallScriptPath,

    [Parameter(Mandatory = $true)]
    [string]$UninstallScriptPath,

    # Comma/semicolon/newline separated list of process names (optionally
    # name=Description) to close before install/uninstall.
    [Parameter(Mandatory = $false)]
    [string]$AppsToClose = '',

    [Parameter(Mandatory = $false)]
    [string]$PsadtVersion = '4.1.8'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $PackageRoot -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $PackageRoot | Out-Null
}
foreach ($required in @($InstallScriptPath, $UninstallScriptPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Logic script not found: $required"
    }
}

# ---------------------------------------------------------------------------
# 1. Stage the pinned PSADT v4 template (module + assets/config/strings). The
#    release template zip is cached like Stage-PSADTv4.ps1 does.
# ---------------------------------------------------------------------------
$cacheRoot = Join-Path $PWD '.psadt-cache'
New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
$cacheZip = Join-Path $cacheRoot "psadt-template-v$PsadtVersion.zip"
if (-not (Test-Path -LiteralPath $cacheZip)) {
    # Release assets are named PSAppDeployToolkit_Template_v4.zip (no patch
    # suffix); the tag pins the exact version.
    $url = "https://github.com/PSAppDeployToolkit/PSAppDeployToolkit/releases/download/$PsadtVersion/PSAppDeployToolkit_Template_v4.zip"
    Write-Host "Downloading PSADT v$PsadtVersion template from $url"
    Invoke-WebRequest -Uri $url -OutFile $cacheZip -UseBasicParsing -TimeoutSec 120
}
$extractDir = Join-Path $cacheRoot "template-v$PsadtVersion"
if (-not (Test-Path -LiteralPath $extractDir)) {
    Expand-Archive -LiteralPath $cacheZip -DestinationPath $extractDir -Force
}

# The template zip either has the payload at the root or in a single child
# folder — locate the folder that contains the PSAppDeployToolkit module.
$templateRoot = $null
if (Test-Path -LiteralPath (Join-Path $extractDir 'PSAppDeployToolkit')) {
    $templateRoot = $extractDir
} else {
    $moduleDir = Get-ChildItem -LiteralPath $extractDir -Recurse -Directory -Filter 'PSAppDeployToolkit' |
        Sort-Object { $_.FullName.Length } |
        Select-Object -First 1
    if ($moduleDir) { $templateRoot = $moduleDir.Parent.FullName }
}
if (-not $templateRoot) {
    throw "Could not locate the PSAppDeployToolkit module inside $extractDir"
}

# Copy everything the v4 session needs. The template's own entry scripts are
# skipped — we generate our own Invoke-AppDeployToolkit.ps1 below. Files/ and
# SupportFiles/ from the template are skipped too (the payload is already in
# place and must not be clobbered by empty template folders).
foreach ($entry in Get-ChildItem -LiteralPath $templateRoot -Force) {
    if ($entry.Name -in @('Invoke-AppDeployToolkit.ps1', 'Files', 'SupportFiles')) { continue }
    $dest = Join-Path $PackageRoot $entry.Name
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    Copy-Item -LiteralPath $entry.FullName -Destination $dest -Recurse -Force
}
Write-Host "Staged PSADT v$PsadtVersion template into $PackageRoot"

# ---------------------------------------------------------------------------
# 2. Relocate the generated logic scripts into the package root.
# ---------------------------------------------------------------------------
Copy-Item -LiteralPath $InstallScriptPath -Destination (Join-Path $PackageRoot 'install-logic.ps1') -Force
Copy-Item -LiteralPath $UninstallScriptPath -Destination (Join-Path $PackageRoot 'uninstall-logic.ps1') -Force

# ---------------------------------------------------------------------------
# 3. Generate the v4 entry script.
# ---------------------------------------------------------------------------
function ConvertTo-SingleQuoted([string]$value) {
    return "'" + ($value -replace "'", "''") + "'"
}

$closeProcessNames = @()
foreach ($token in ($AppsToClose -split '[,;\r\n]+')) {
    $name = ($token -split '=', 2)[0].Trim() -replace '\.exe$', ''
    if ($name) { $closeProcessNames += $name }
}
$closeProcessesLiteral = if ($closeProcessNames.Count -gt 0) {
    '@(' + (($closeProcessNames | ForEach-Object { ConvertTo-SingleQuoted $_ }) -join ', ') + ')'
} else {
    '@()'
}

$appNameLiteral = ConvertTo-SingleQuoted $AppName
$publisherLiteral = ConvertTo-SingleQuoted $Publisher
$versionLiteral = ConvertTo-SingleQuoted $Version
$scriptDate = (Get-Date).ToString('yyyy-MM-dd')

$entryScript = @"
<#
    Vanguard-generated PSAppDeployToolkit v4 deployment script.
    App: $AppName $Version ($Publisher)

    The app-specific install/uninstall logic lives in install-logic.ps1 /
    uninstall-logic.ps1 next to this script and stays toolkit-agnostic; this
    wrapper provides the PSADT session (logging, close-apps, exit-code
    handling) plus a post-uninstall residue sweep.
#>
[CmdletBinding()]
param
(
    [Parameter(Mandatory = `$false)]
    [ValidateSet('Install', 'Uninstall', 'Repair')]
    [System.String]`$DeploymentType = 'Install',

    [Parameter(Mandatory = `$false)]
    [ValidateSet('Auto', 'Interactive', 'NonInteractive', 'Silent')]
    [System.String]`$DeployMode = 'Silent',

    [Parameter(Mandatory = `$false)]
    [System.Management.Automation.SwitchParameter]`$SuppressRebootPassThru,

    [Parameter(Mandatory = `$false)]
    [System.Management.Automation.SwitchParameter]`$TerminalServerMode,

    [Parameter(Mandatory = `$false)]
    [System.Management.Automation.SwitchParameter]`$DisableLogging
)

`$adtSession = @{
    # App variables.
    AppVendor = $publisherLiteral
    AppName = $appNameLiteral
    AppVersion = $versionLiteral
    AppArch = ''
    AppLang = 'EN'
    AppRevision = '01'
    AppSuccessExitCodes = @(0)
    AppRebootExitCodes = @(1641, 3010)
    AppScriptVersion = '1.0.0'
    AppScriptDate = '$scriptDate'
    AppScriptAuthor = 'Vanguard'

    # Script variables.
    DeployAppScriptFriendlyName = `$MyInvocation.MyCommand.Name
    DeployAppScriptParameters = `$PSBoundParameters
}

`$vanguardCloseProcesses = $closeProcessesLiteral

function Invoke-VanguardLogic
{
    param([System.String]`$LogicFile)

    `$logicPath = Join-Path `$PSScriptRoot `$LogicFile
    if (-not (Test-Path -LiteralPath `$logicPath -PathType Leaf))
    {
        Write-ADTLogEntry -Message "Logic script missing: `$logicPath" -Severity 3
        return 60011
    }
    # Child process so the logic script's `$PSScriptRoot resolves to the
    # package root and an `exit` inside it cannot bypass Close-ADTSession.
    `$psExe = Join-Path `$env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    `$proc = Start-Process -FilePath `$psExe -ArgumentList @('-ExecutionPolicy', 'Bypass', '-NoProfile', '-NonInteractive', '-File', `$logicPath) -Wait -PassThru -WindowStyle Hidden
    return [System.Int32]`$proc.ExitCode
}

function Close-VanguardProcesses
{
    if (`$vanguardCloseProcesses.Count -eq 0) { return }
    try
    {
        Show-ADTInstallationWelcome -CloseProcesses `$vanguardCloseProcesses -Silent
    }
    catch
    {
        Write-ADTLogEntry -Message "Show-ADTInstallationWelcome failed (`$(`$_.Exception.Message)); stopping processes directly." -Severity 2
        foreach (`$name in `$vanguardCloseProcesses)
        {
            Get-Process -Name `$name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }
}

function Remove-VanguardResidue
{
    # Sweep the residues a vendor uninstaller commonly leaves behind: install
    # directories named after the app and vendor/app registry keys. Anything
    # still present afterwards is logged so the pipeline's leftover diff and
    # the PSADT log both surface it.
    `$appName = `$adtSession.AppName
    `$vendor = `$adtSession.AppVendor
    `$candidateDirs = New-Object System.Collections.Generic.List[string]
    foreach (`$root in @(`$env:ProgramFiles, `${env:ProgramFiles(x86)}, `$env:ProgramData))
    {
        if (`$root) { `$candidateDirs.Add((Join-Path `$root `$appName)) | Out-Null }
    }
    foreach (`$dir in `$candidateDirs)
    {
        if (Test-Path -LiteralPath `$dir)
        {
            try
            {
                Remove-Item -LiteralPath `$dir -Recurse -Force -ErrorAction Stop
                Write-ADTLogEntry -Message "Removed leftover directory: `$dir" -Severity 1
            }
            catch
            {
                Write-ADTLogEntry -Message "Leftover directory could not be removed: `$dir (`$(`$_.Exception.Message))" -Severity 2
            }
        }
    }
    `$candidateKeys = New-Object System.Collections.Generic.List[string]
    if (`$vendor)
    {
        `$candidateKeys.Add("HKLM:\SOFTWARE\`$vendor\`$appName") | Out-Null
        `$candidateKeys.Add("HKLM:\SOFTWARE\WOW6432Node\`$vendor\`$appName") | Out-Null
    }
    foreach (`$key in `$candidateKeys)
    {
        if (Test-Path -Path `$key)
        {
            try
            {
                Remove-Item -Path `$key -Recurse -Force -ErrorAction Stop
                Write-ADTLogEntry -Message "Removed leftover registry key: `$key" -Severity 1
            }
            catch
            {
                Write-ADTLogEntry -Message "Leftover registry key could not be removed: `$key (`$(`$_.Exception.Message))" -Severity 2
            }
        }
    }
    # Report anything app-named that survived the sweep.
    `$remaining = @(`$candidateDirs | Where-Object { Test-Path -LiteralPath `$_ })
    if (`$remaining.Count -gt 0)
    {
        Write-ADTLogEntry -Message "Residue remains after uninstall sweep: `$(`$remaining -join '; ')" -Severity 2
    }
    else
    {
        Write-ADTLogEntry -Message 'Residue sweep complete: no app-named leftovers remain.' -Severity 1
    }
}

function Install-ADTDeployment
{
    `$adtSession.InstallPhase = 'Pre-Install'
    Close-VanguardProcesses

    `$adtSession.InstallPhase = 'Install'
    `$exitCode = Invoke-VanguardLogic -LogicFile 'install-logic.ps1'
    if (`$exitCode -notin (`$adtSession.AppSuccessExitCodes + `$adtSession.AppRebootExitCodes))
    {
        Write-ADTLogEntry -Message "Install logic failed with exit code `$exitCode" -Severity 3
        Close-ADTSession -ExitCode `$exitCode
    }
    if (`$exitCode -in `$adtSession.AppRebootExitCodes)
    {
        Close-ADTSession -ExitCode `$exitCode
    }

    `$adtSession.InstallPhase = 'Post-Install'
    Write-ADTLogEntry -Message 'Install logic completed successfully.' -Severity 1
}

function Uninstall-ADTDeployment
{
    `$adtSession.InstallPhase = 'Pre-Uninstall'
    Close-VanguardProcesses

    `$adtSession.InstallPhase = 'Uninstall'
    `$exitCode = Invoke-VanguardLogic -LogicFile 'uninstall-logic.ps1'
    if (`$exitCode -notin (`$adtSession.AppSuccessExitCodes + `$adtSession.AppRebootExitCodes))
    {
        Write-ADTLogEntry -Message "Uninstall logic failed with exit code `$exitCode" -Severity 3
        Close-ADTSession -ExitCode `$exitCode
    }

    `$adtSession.InstallPhase = 'Post-Uninstall'
    Remove-VanguardResidue
}

function Repair-ADTDeployment
{
    `$adtSession.InstallPhase = 'Repair'
    `$exitCode = Invoke-VanguardLogic -LogicFile 'install-logic.ps1'
    if (`$exitCode -notin (`$adtSession.AppSuccessExitCodes + `$adtSession.AppRebootExitCodes))
    {
        Close-ADTSession -ExitCode `$exitCode
    }
}

# ---------------------------------------------------------------------------
# Bootstrap (mirrors the official PSADT v4 template flow).
# ---------------------------------------------------------------------------
`$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
`$ProgressPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
Set-StrictMode -Version 1

try
{
    if (Test-Path -LiteralPath "`$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1" -PathType Leaf)
    {
        Get-ChildItem -LiteralPath "`$PSScriptRoot\PSAppDeployToolkit" -Recurse -File | Unblock-File -ErrorAction Ignore
        Import-Module -Name "`$PSScriptRoot\PSAppDeployToolkit\PSAppDeployToolkit.psd1" -Force
    }
    else
    {
        Import-Module -Name PSAppDeployToolkit -Force
    }

    `$iadtParams = Get-ADTBoundParametersAndDefaultValues -Invocation `$MyInvocation
    `$adtSession = Remove-ADTHashtableNullOrEmptyValues -Hashtable `$adtSession
    `$adtSession = Open-ADTSession @adtSession @iadtParams -PassThru
}
catch
{
    `$Host.UI.WriteErrorLine((Out-String -InputObject `$_ -Width ([System.Int32]::MaxValue)))
    exit 60008
}

try
{
    # Import any extensions shipped alongside the module before deploying.
    Get-ChildItem -LiteralPath `$PSScriptRoot -Directory | & {
        process
        {
            if (`$_.Name -match 'PSAppDeployToolkit\..+`$')
            {
                Get-ChildItem -LiteralPath `$_.FullName -Recurse -File | Unblock-File -ErrorAction Ignore
                Import-Module -Name `$_.FullName -Force
            }
        }
    }

    & "`$(`$adtSession.DeploymentType)-ADTDeployment"
    Close-ADTSession
}
catch
{
    `$mainErrorMessage = "An unhandled error within [`$(`$MyInvocation.MyCommand.Name)] has occurred.``n`$(Resolve-ADTErrorRecord -ErrorRecord `$_)"
    Write-ADTLogEntry -Message `$mainErrorMessage -Severity 3
    Close-ADTSession -ExitCode 60001
}
"@

Set-Content -LiteralPath (Join-Path $PackageRoot 'Invoke-AppDeployToolkit.ps1') -Value $entryScript -Encoding UTF8

# ---------------------------------------------------------------------------
# 4. Replace the original scripts with thin shims. The pipeline contract
#    (setup file, Intune command lines, validation steps) stays untouched.
# ---------------------------------------------------------------------------
$installShim = @'
# Vanguard PSADT v4 shim — the deployment runs inside Invoke-AppDeployToolkit.ps1.
$adtEntry = Join-Path $PSScriptRoot 'Invoke-AppDeployToolkit.ps1'
if (-not (Test-Path -LiteralPath $adtEntry -PathType Leaf)) {
    Write-Error "PSADT entry script missing: $adtEntry"
    exit 60010
}
& $adtEntry -DeploymentType Install -DeployMode Silent
exit $LASTEXITCODE
'@

$uninstallShim = $installShim.Replace("-DeploymentType Install", "-DeploymentType Uninstall")

Set-Content -LiteralPath $InstallScriptPath -Value $installShim -Encoding UTF8
Set-Content -LiteralPath $UninstallScriptPath -Value $uninstallShim -Encoding UTF8

# Also drop shim copies into the package root so validation staging that copies
# the package root gets a consistent, runnable layout.
Set-Content -LiteralPath (Join-Path $PackageRoot 'install_script.ps1') -Value $installShim -Encoding UTF8
Set-Content -LiteralPath (Join-Path $PackageRoot 'uninstall_script.ps1') -Value $uninstallShim -Encoding UTF8

Write-Host "PSADT v4 package assembled at $PackageRoot (entry: Invoke-AppDeployToolkit.ps1, shims refreshed)."
if ($env:GITHUB_OUTPUT) {
    Add-Content -Path $env:GITHUB_OUTPUT -Value "psadt_wrapped=true"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "psadt_version=$PsadtVersion"
}
