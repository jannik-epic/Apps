# Download-WingetInstaller.ps1
#
# Downloads the real installer binary referenced by a winget package manifest
# and stages it (with manifest-derived metadata) so the deployment pipeline can
# build an OFFLINE .intunewin: the target device never needs the winget client.
#
# Outputs (all written into -OutputDirectory):
#   - <stagingDir>/Files/<installerFileName>      the actual MSI/EXE/MSIX
#   - <stagingDir>/installer-metadata.json        the parsed manifest fields
#
# The metadata json is the contract consumed by Generate-InstallationScripts.ps1
# (offline mode) and Create-IntuneApplication.ps1 (detection rule). Schema:
#
#   {
#     "fileName": "NotionCalendarSetup-1.133.0.exe",
#     "sha256":   "ABCDEF...",
#     "installerType": "nullsoft" | "inno" | "wix" | "burn" | "msi" | "msix"
#                      | "appx" | "exe" | "zip",
#     "installerLocale": "en-US",
#     "architecture": "x86" | "x64" | "arm64" | "neutral",
#     "scope": "machine" | "user" | "",
#     "silentArgs":   "/S"  (or "/qn /norestart" for msi)
#     "silentUninstallArgs": "/S",
#     "productCode": "{GUID}"  (msi only),
#     "packageFamilyName": "...",  (msix only)
#     "successExitCodes": [0, 1641, 3010],
#     "version": "1.133.0"
#   }

param(
    [Parameter(Mandatory = $true)]
    [string]$PackageId,

    [Parameter(Mandatory = $false)]
    [string]$Version,

    [Parameter(Mandatory = $false)]
    [ValidateSet("winget", "msstore")]
    [string]$PackageSource = "winget",

    [Parameter(Mandatory = $false)]
    [ValidateSet("x86", "x64", "arm64")]
    [string]$Architecture = "x64",

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
    throw "winget.exe is not available on this runner. The pipeline requires a runner image with winget installed (windows-latest / windows-2022 satisfy this)."
}

# Ensure a clean staging tree.
if (Test-Path -LiteralPath $OutputDirectory) {
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}
$filesDir = Join-Path $OutputDirectory "Files"
New-Item -ItemType Directory -Force -Path $filesDir | Out-Null

$downloadDir = Join-Path $OutputDirectory "winget-download"
New-Item -ItemType Directory -Force -Path $downloadDir | Out-Null

# msstore packages can be downloaded with `winget download --source msstore`
# for free MSIX/AppX bundles. Licensed/paid Store apps will fail at download
# time — the caller should detect the failure and fall back to the legacy
# winget-install wrapper (or the native Intune Microsoft Store app type).
$downloadArgs = @(
    "download",
    "--id", $PackageId,
    "--source", $PackageSource,
    "--exact",
    "--download-directory", $downloadDir,
    "--accept-package-agreements",
    "--accept-source-agreements",
    "--architecture", $Architecture
)
if ($Version -and $Version -notin @('latest','Latest','LATEST','')) {
    # 'latest' is not a real winget version selector — passing it as
    # --version causes winget to literally search for a version called
    # "latest" and fail (exit -1978335209). Omit instead.
    $downloadArgs += @("--version", $Version)
}

Write-Host "Running: winget $($downloadArgs -join ' ')"
$wingetOutput = & winget.exe @downloadArgs 2>&1 | Out-String
Write-Host $wingetOutput
if ($LASTEXITCODE -ne 0) {
    throw "winget download failed (exit $LASTEXITCODE) for $PackageId. Output: $wingetOutput"
}

# winget download writes: <PackageId>.<ext> (installer) + <PackageId>.yaml (merged manifest).
$installerFile = Get-ChildItem -LiteralPath $downloadDir -File |
    Where-Object { $_.Extension -inotin @('.yaml','.yml') } |
    Sort-Object Length -Descending |
    Select-Object -First 1
if (-not $installerFile) {
    throw "winget download completed but no installer binary was found in $downloadDir."
}

$manifestFile = Get-ChildItem -LiteralPath $downloadDir -File -Filter "*.yaml" |
    Select-Object -First 1
if (-not $manifestFile) {
    $manifestFile = Get-ChildItem -LiteralPath $downloadDir -File -Filter "*.yml" |
        Select-Object -First 1
}
if (-not $manifestFile) {
    Write-Warning "No manifest YAML found next to installer; falling back to heuristic detection."
}

# Move the installer into the staging Files/ folder.
$stagedInstallerPath = Join-Path $filesDir $installerFile.Name
Move-Item -LiteralPath $installerFile.FullName -Destination $stagedInstallerPath -Force
Write-Host "Staged installer: $stagedInstallerPath"

# SHA256 for integrity surfacing in metadata + UI.
$sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $stagedInstallerPath).Hash.ToLowerInvariant()

# --- Parse the manifest (no powershell-yaml dependency: simple line-based parser).
# winget merged manifest has these relevant top-level keys: PackageIdentifier,
# PackageVersion, InstallerType, Scope, InstallerSuccessCodes, ProductCode,
# PackageFamilyName, plus a per-installer "Installers:" array with the same
# fields scoped to architecture. We only need the entry that matches our
# requested Architecture; if absent, take the first one.
$manifestText = if ($manifestFile) { Get-Content -LiteralPath $manifestFile.FullName -Raw } else { "" }

function Read-YamlScalar {
    param([string]$Text, [string]$Key)
    if (-not $Text) { return $null }
    $pattern = "(?m)^\s*${Key}:\s*['""]?([^'""\r\n#]+?)['""]?\s*(#.*)?$"
    $m = [regex]::Match($Text, $pattern)
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return $null
}

# Find the per-installer block whose Architecture matches; fall back to whole doc.
function Read-InstallerBlock {
    param([string]$Text, [string]$Arch)
    if (-not $Text) { return "" }
    $marker = "(?ms)^\s*-\s*(Architecture:\s*${Arch}\b.*?)(?=^\s*-\s*Architecture:|\Z)"
    $m = [regex]::Match($Text, $marker)
    if ($m.Success) { return $m.Groups[1].Value }
    # Any installer.
    $m = [regex]::Match($Text, "(?ms)^\s*-\s*(Architecture:.*?)(?=^\s*-\s*Architecture:|\Z)")
    if ($m.Success) { return $m.Groups[1].Value }
    return $Text
}

$installerBlock = Read-InstallerBlock -Text $manifestText -Arch $Architecture

function Choose {
    param([string]$First, [string]$Second)
    if (-not [string]::IsNullOrWhiteSpace($First)) { return $First }
    return $Second
}

$installerType  = Choose (Read-YamlScalar $installerBlock 'InstallerType') (Read-YamlScalar $manifestText 'InstallerType')
$nestedType     = Choose (Read-YamlScalar $installerBlock 'NestedInstallerType') (Read-YamlScalar $manifestText 'NestedInstallerType')
$installerLocale= Choose (Read-YamlScalar $installerBlock 'InstallerLocale') (Read-YamlScalar $manifestText 'InstallerLocale')
$scope          = Choose (Read-YamlScalar $installerBlock 'Scope') (Read-YamlScalar $manifestText 'Scope')
$productCode    = Choose (Read-YamlScalar $installerBlock 'ProductCode') (Read-YamlScalar $manifestText 'ProductCode')
$pfn            = Choose (Read-YamlScalar $installerBlock 'PackageFamilyName') (Read-YamlScalar $manifestText 'PackageFamilyName')
$manifestVer    = Read-YamlScalar $manifestText 'PackageVersion'

# Resolve InstallerType from extension when manifest is silent.
if (-not $installerType) {
    switch -Regex ($installerFile.Extension.ToLowerInvariant()) {
        '\.msi$'             { $installerType = 'msi' }
        '\.msix$|\.msixbundle$' { $installerType = 'msix' }
        '\.appx$|\.appxbundle$' { $installerType = 'appx' }
        '\.exe$'             { $installerType = 'exe' }
        '\.zip$'             { $installerType = 'zip' }
        default              { $installerType = 'exe' }
    }
}
$installerTypeLc = $installerType.ToLowerInvariant()
$nestedTypeLc    = if ($nestedType) { $nestedType.ToLowerInvariant() } else { $null }

# Look for an InstallerSwitches.Silent block inside the installer or root.
function Read-Switch {
    param([string]$Text, [string]$SwitchName)
    if (-not $Text) { return $null }
    # Matches:  InstallerSwitches:\n  Silent: '/qn'
    $pat = "(?ms)InstallerSwitches:.*?\b${SwitchName}:\s*['""]?([^'""\r\n#]+?)['""]?\s*(\r?\n|\#|$)"
    $m = [regex]::Match($Text, $pat)
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return $null
}

$silentArg   = Choose (Read-Switch $installerBlock 'Silent') (Read-Switch $manifestText 'Silent')
$silentWithProgress = Choose (Read-Switch $installerBlock 'SilentWithProgress') (Read-Switch $manifestText 'SilentWithProgress')

# Compute final silent args by installer type, preferring manifest hints.
$defaultSilent = switch ($installerTypeLc) {
    'msi'      { '/qn /norestart' }
    'wix'      { '/quiet /norestart' }
    'burn'     { '/quiet /norestart' }
    'inno'     { '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-' }
    'nullsoft' { '/S' }
    'msix'     { '' }
    'appx'     { '' }
    default    {
        # Heuristic by file extension when type really is "exe"/unknown.
        if ($installerFile.Extension -ieq '.msi') { '/qn /norestart' } else { '/S' }
    }
}
$silentArgs = if ($silentArg) { $silentArg } elseif ($silentWithProgress) { $silentWithProgress } else { $defaultSilent }

# Uninstall switches mirror install switches in winget manifests; fall back to type defaults.
function Read-Block-Switch {
    param([string]$Text, [string]$Block, [string]$Key)
    if (-not $Text) { return $null }
    $pat = "(?ms)${Block}:.*?\b${Key}:\s*['""]?([^'""\r\n#]+?)['""]?\s*(\r?\n|\#|$)"
    $m = [regex]::Match($Text, $pat)
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return $null
}
$silentUninstallArg = Choose `
    (Read-Block-Switch $installerBlock 'UninstallSwitches' 'Silent') `
    (Read-Block-Switch $manifestText 'UninstallSwitches' 'Silent')
$silentUninstallArgs = if ($silentUninstallArg) { $silentUninstallArg } else { $silentArgs }

# Success codes: manifest lists numeric exit codes that should be treated as success.
$successCodes = New-Object System.Collections.Generic.List[int]
$successCodes.Add(0) | Out-Null
$successCodes.Add(1641) | Out-Null
$successCodes.Add(3010) | Out-Null
if ($installerBlock) {
    foreach ($line in $installerBlock -split "`n") {
        if ($line -match '^\s*-\s*(\d+)\s*$') {
            $code = [int]$Matches[1]
            if ($successCodes -notcontains $code) { $successCodes.Add($code) | Out-Null }
        }
    }
}

$metadata = [ordered]@{
    fileName             = $installerFile.Name
    sha256               = $sha
    installerType        = $installerTypeLc
    nestedInstallerType  = $nestedTypeLc
    installerLocale      = $installerLocale
    architecture         = $Architecture
    scope                = $scope
    silentArgs           = $silentArgs
    silentUninstallArgs  = $silentUninstallArgs
    productCode          = $productCode
    packageFamilyName    = $pfn
    successExitCodes     = @($successCodes)
    version              = if ($manifestVer) { $manifestVer } else { $Version }
    sourceManifestName   = if ($manifestFile) { $manifestFile.Name } else { $null }
}

$metadataPath = Join-Path $OutputDirectory "installer-metadata.json"
$metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $metadataPath -Encoding UTF8
Write-Host "Wrote installer metadata: $metadataPath"
Write-Host "  fileName       = $($metadata.fileName)"
Write-Host "  installerType  = $($metadata.installerType)"
Write-Host "  silentArgs     = $($metadata.silentArgs)"
Write-Host "  productCode    = $($metadata.productCode)"
Write-Host "  sha256         = $($metadata.sha256)"

if ($env:GITHUB_OUTPUT) {
    Add-Content -Path $env:GITHUB_OUTPUT -Value "installer_file_name=$($metadata.fileName)"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "installer_type=$($metadata.installerType)"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "installer_sha256=$($metadata.sha256)"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "product_code=$($metadata.productCode)"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "package_files_dir=$OutputDirectory"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "metadata_path=$metadataPath"
}

# Clean up the empty download directory (installer was moved already).
Remove-Item -LiteralPath $downloadDir -Recurse -Force -ErrorAction SilentlyContinue
