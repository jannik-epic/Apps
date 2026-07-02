# Stage-PSADTv4.ps1
#
# When use_psadt=true, download the PSADT v4 module zip from GitHub at
# pipeline time and extract it into the .intunewin staging directory.
# Generate-InstallationScripts emits a Deploy-Application.ps1 that imports
# the toolkit (Import-Module .\PSAppDeployToolkit\PSAppDeployToolkit.psd1)
# so install/uninstall run through Start-ADTProcess / Show-ADTInstallationWelcome.
#
# Why download at workflow time vs vendor: PSADT is ~5 MB + frequently
# updated. Vendoring inflates this repo and creates a version-lock that
# slips. Cached download is fast (~3 s on GitHub Actions).

param(
    [Parameter(Mandatory = $true)]
    [string]$StagingDir,

    [Parameter(Mandatory = $false)]
    [string]$Version = '4.1.8',

    [Parameter(Mandatory = $false)]
    [string]$ReleaseAssetName = 'PSAppDeployToolkit_Template_v4.1.8.zip'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $StagingDir -PathType Container)) {
    throw "StagingDir does not exist: $StagingDir"
}

$cacheRoot = Join-Path $PWD '.psadt-cache'
New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
$cacheZip = Join-Path $cacheRoot "psadt-v$Version.zip"

if (-not (Test-Path -LiteralPath $cacheZip)) {
    $url = "https://github.com/PSAppDeployToolkit/PSAppDeployToolkit/releases/download/$Version/$ReleaseAssetName"
    Write-Host "Downloading PSADT v$Version from $url"
    try {
        Invoke-WebRequest -Uri $url -OutFile $cacheZip -UseBasicParsing -TimeoutSec 60
    } catch {
        # Fall back to a tag URL that exists at install time. Some PSADT
        # releases publish multiple assets — try the canonical zip name.
        $altUrl = "https://github.com/PSAppDeployToolkit/PSAppDeployToolkit/archive/refs/tags/$Version.zip"
        Write-Warning "Primary PSADT asset not available ($($_.Exception.Message)); trying $altUrl"
        Invoke-WebRequest -Uri $altUrl -OutFile $cacheZip -UseBasicParsing -TimeoutSec 60
    }
}

$extractDir = Join-Path $cacheRoot "extracted-v$Version"
if (Test-Path -LiteralPath $extractDir) { Remove-Item -LiteralPath $extractDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
Expand-Archive -LiteralPath $cacheZip -DestinationPath $extractDir -Force

# Locate the toolkit folder regardless of zip layout. PSADT v4's official
# template puts the toolkit at <root>/Toolkit/AppDeployToolkit/ (legacy
# layout) OR <root>/PSAppDeployToolkit/ (module-only layout). Use a sequential
# fallback instead of ?? so the script also parses under Windows PowerShell 5.1.
$toolkitSrc = Get-ChildItem -LiteralPath $extractDir -Recurse -Directory -Filter 'PSAppDeployToolkit' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $toolkitSrc) {
    $toolkitSrc = Get-ChildItem -LiteralPath $extractDir -Recurse -Directory -Filter 'AppDeployToolkit' -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $toolkitSrc) {
    throw "Could not find a PSAppDeployToolkit folder inside $extractDir"
}

$toolkitDest = Join-Path $StagingDir 'PSAppDeployToolkit'
if (Test-Path -LiteralPath $toolkitDest) { Remove-Item -LiteralPath $toolkitDest -Recurse -Force }
Copy-Item -LiteralPath $toolkitSrc.FullName -Destination $toolkitDest -Recurse -Force

Write-Host "Staged PSADT v$Version at $toolkitDest"
if ($env:GITHUB_OUTPUT) {
    Add-Content -Path $env:GITHUB_OUTPUT -Value "psadt_version=$Version"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "psadt_dir=$toolkitDest"
}
