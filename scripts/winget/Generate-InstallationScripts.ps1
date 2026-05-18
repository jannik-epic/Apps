# Generate-InstallationScripts.ps1
# Generates installation, uninstallation, and detection scripts for Winget packages

param(
    [Parameter(Mandatory = $true)]
    [string]$PackageId,

    [Parameter(Mandatory = $false)]
    [ValidateSet("winget", "msstore")]
    [string]$PackageSource = "winget",

    [Parameter(Mandatory = $false)]
    [bool]$UsePSADT = $true,

    [Parameter(Mandatory = $false)]
    [string]$InstallContext = "system",

    [Parameter(Mandatory = $false)]
    [string]$AppName,

    [Parameter(Mandatory = $false)]
    [string]$Publisher,

    [Parameter(Mandatory = $false)]
    [string]$Version,

    [Parameter(Mandatory = $false)]
    [string]$CustomDetectionScript,

    [Parameter(Mandatory = $false)]
    [string]$CustomDetectionScriptBase64,

    [Parameter(Mandatory = $false)]
    [string]$InstallScriptBase64,

    [Parameter(Mandatory = $false)]
    [string]$UninstallScriptBase64,

    [Parameter(Mandatory = $false)]
    [string]$PreInstallScriptBase64,

    [Parameter(Mandatory = $false)]
    [string]$PostInstallScriptBase64
)

function Decode-Base64Utf8 {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }
    $raw = $Value.Trim()
    if ($raw.Contains(',')) {
        $raw = $raw.Split(',', 2)[1]
    }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($raw))
}

if (-not $AppName) {
    $AppName = $PackageId.Split('.')[-1]
}

$PackageSourceArg = "--source $PackageSource"

$installScriptOverride = Decode-Base64Utf8 $InstallScriptBase64
$uninstallScriptOverride = Decode-Base64Utf8 $UninstallScriptBase64
$preInstallBlock = Decode-Base64Utf8 $PreInstallScriptBase64
$postInstallBlock = Decode-Base64Utf8 $PostInstallScriptBase64
$customDetectionFromBase64 = Decode-Base64Utf8 $CustomDetectionScriptBase64

if ($UsePSADT) {
    # Generate a self-contained PowerShell deployment script with PSADT-style
    # phases. The customer workflow packages this script into a .intunewin
    # directly, so it must not depend on a toolkit folder that is not present
    # in the generated package.
    $installScript = @"
## Modern Dev Mgmt Winget deployment script
## App Name - $AppName
## Publisher - $Publisher
## Version - $Version

[CmdletBinding()]
Param (
    [Parameter(Mandatory = `$false)]
    [ValidateSet('Install','Uninstall','Repair')]
    [String]`$DeploymentType = 'Install',
    [Parameter(Mandatory = `$false)]
    [ValidateSet('Interactive','Silent','NonInteractive')]
    [String]`$DeployMode = 'Silent'
)

Try {
    Set-ExecutionPolicy -ExecutionPolicy 'ByPass' -Scope 'Process' -Force -ErrorAction 'Stop'

    function Invoke-Winget {
        param([string[]]`$Arguments)
        `$winget = Get-Command winget.exe -ErrorAction SilentlyContinue
        if (-not `$winget) {
            `$candidate = Join-Path `$env:LOCALAPPDATA "Microsoft\WindowsApps\winget.exe"
            if (Test-Path -LiteralPath `$candidate) {
                `$winget = Get-Item -LiteralPath `$candidate
            }
        }
        if (-not `$winget) {
            throw "winget.exe was not found on this device."
        }
        `$process = Start-Process -FilePath `$winget.Source -ArgumentList `$Arguments -Wait -PassThru -WindowStyle Hidden
        if (`$process.ExitCode -ne 0) {
            throw "winget exited with code `$(`$process.ExitCode)"
        }
    }

    If (`$deploymentType -ine 'Uninstall' -and `$deploymentType -ine 'Repair') {
        [String]`$installPhase = 'Pre-Installation'
        # __MODERNDEVMGMT_PRE_INSTALL__

        [String]`$installPhase = 'Installation'
        Invoke-Winget -Arguments @("install", "--id", "$PackageId", "--exact", "--source", "$PackageSource", "--silent", "--accept-package-agreements", "--accept-source-agreements")

        [String]`$installPhase = 'Post-Installation'
        # __MODERNDEVMGMT_POST_INSTALL__
    }
    ElseIf (`$deploymentType -ieq 'Uninstall') {
        [String]`$installPhase = 'Pre-Uninstallation'

        [String]`$installPhase = 'Uninstallation'
        Invoke-Winget -Arguments @("uninstall", "--id", "$PackageId", "--exact", "--silent")

        [String]`$installPhase = 'Post-Uninstallation'
    }

    exit 0
}
Catch {
    Write-Error "Deployment failed in phase [`$installPhase]: `$(`$_.Exception.Message)"
    exit 1
}
"@

    $uninstallScript = @"
try {
    `$winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not `$winget) {
        `$candidate = Join-Path `$env:LOCALAPPDATA "Microsoft\WindowsApps\winget.exe"
        if (Test-Path -LiteralPath `$candidate) {
            `$winget = Get-Item -LiteralPath `$candidate
        }
    }
    if (-not `$winget) {
        throw "winget.exe was not found on this device."
    }
    `$process = Start-Process -FilePath `$winget.Source -ArgumentList @("uninstall", "--id", "$PackageId", "--exact", "--silent") -Wait -PassThru -WindowStyle Hidden
    exit `$process.ExitCode
}
catch {
    Write-Error `$_.Exception.Message
    exit 1
}
"@
} else {
    # Standard Winget scripts
    $installParts = @()
    if ($preInstallBlock) {
        $installParts += "# Pre-install script"
        $installParts += $preInstallBlock
    }
    $installParts += "winget install --id $PackageId --exact $PackageSourceArg --silent --accept-package-agreements --accept-source-agreements"
    if ($postInstallBlock) {
        $installParts += "# Post-install script"
        $installParts += $postInstallBlock
    }
    $installScript = $installParts -join [Environment]::NewLine
    $uninstallScript = "winget uninstall --id $PackageId --silent"
}

if ($installScriptOverride) {
    $installScript = $installScriptOverride
} else {
    $installScript = $installScript.Replace('# __MODERNDEVMGMT_PRE_INSTALL__', $(if ($preInstallBlock) { $preInstallBlock } else { '' }))
    $installScript = $installScript.Replace('# __MODERNDEVMGMT_POST_INSTALL__', $(if ($postInstallBlock) { $postInstallBlock } else { '' }))
}

if ($uninstallScriptOverride) {
    $uninstallScript = $uninstallScriptOverride
}

# Detection script
$detectionScript = if ($customDetectionFromBase64) { $customDetectionFromBase64 } else { $CustomDetectionScript }
if (-not $detectionScript) {
    $detectionScript = @"
# Detection script for $AppName
try {
    `$wingetList = winget list --id $PackageId --exact --accept-source-agreements 2>`$null

    if (`$wingetList -match `"$PackageId`") {
        Write-Output `"$AppName is installed`"
        exit 0
    }

    # Alternative registry detection
    `$uninstallKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    )

    foreach (`$key in `$uninstallKeys) {
        `$apps = Get-ChildItem -Path `$key -ErrorAction SilentlyContinue
        foreach (`$app in `$apps) {
            `$properties = Get-ItemProperty -Path `$app.PSPath -ErrorAction SilentlyContinue
            if (`$properties.DisplayName -like "*$AppName*" -and `$properties.Publisher -like "*$Publisher*") {
                Write-Output "$AppName is installed (Registry)"
                exit 0
            }
        }
    }

    Write-Output "$AppName is not installed"
    exit 1
}
catch {
    Write-Error "Detection script failed: `$_"
    exit 1
}
"@
}

# Save scripts to output
$installScript | Out-File -FilePath "install_script.ps1" -Encoding UTF8
$uninstallScript | Out-File -FilePath "uninstall_script.ps1" -Encoding UTF8
$detectionScript | Out-File -FilePath "detection_script.ps1" -Encoding UTF8

# Set output
if ($env:GITHUB_OUTPUT) {
    Add-Content -Path $env:GITHUB_OUTPUT -Value "scripts_generated=true"
}

Write-Host "Scripts generated successfully"
Write-Host "- install_script.ps1"
Write-Host "- uninstall_script.ps1"
Write-Host "- detection_script.ps1"
