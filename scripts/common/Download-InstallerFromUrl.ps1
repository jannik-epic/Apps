# Download-InstallerFromUrl.ps1
#
# Downloads an installer binary from a direct URL (vendor website, S3, etc.)
# and produces the same installer-metadata.json shape as Download-WingetInstaller
# so the rest of the offline-intunewin pipeline (Generate-InstallationScripts,
# Create-IntuneApplication) works unchanged.
#
# Use cases:
#   - Apps not in winget / homebrew (e.g. internal LOB tools, vendor portals)
#   - URL-based catalog entries from web-version-watchers
#   - Direct deploy via the web app's "Deploy from URL" flow
#
# Output (under -OutputDirectory):
#   - Files/<inferred-filename>
#   - installer-metadata.json with installerType + silentArgs heuristics

param(
    [Parameter(Mandatory = $true)]
    [string]$InstallerUrl,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [Parameter(Mandatory = $false)]
    [string]$Filename,

    [Parameter(Mandatory = $false)]
    [string]$Sha256Expected,

    [Parameter(Mandatory = $false)]
    [string]$SilentArgsOverride,

    [Parameter(Mandatory = $false)]
    [string]$Version
)

$ErrorActionPreference = 'Stop'

if (-not $InstallerUrl) {
    throw "InstallerUrl is required."
}

if (Test-Path -LiteralPath $OutputDirectory) {
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}
$filesDir = Join-Path $OutputDirectory 'Files'
New-Item -ItemType Directory -Force -Path $filesDir | Out-Null

# Resolve target filename. Prefer the explicit -Filename; otherwise derive from
# the URL path (last segment after stripping query string).
if (-not $Filename) {
    try {
        $uri = [Uri]$InstallerUrl
        $path = $uri.AbsolutePath
        $Filename = Split-Path -Leaf $path
    } catch {
        $Filename = "installer.bin"
    }
}
if (-not $Filename -or $Filename -eq '/') { $Filename = 'installer.bin' }
$destination = Join-Path $filesDir $Filename

Write-Host "Downloading $InstallerUrl → $destination"
try {
    Invoke-WebRequest -Uri $InstallerUrl -OutFile $destination -UseBasicParsing -TimeoutSec 600
} catch {
    throw "Failed to download $InstallerUrl: $($_.Exception.Message)"
}

if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
    throw "Download completed but $destination was not produced"
}

$sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash.ToLowerInvariant()
if ($Sha256Expected -and ($Sha256Expected.ToLowerInvariant() -ne $sha)) {
    throw "SHA256 mismatch: expected $Sha256Expected, got $sha"
}

# Infer installer type from extension.
$ext = ([IO.Path]::GetExtension($Filename)).ToLowerInvariant()
$installerType = switch ($ext) {
    '.msi'                  { 'msi' }
    '.msix'                 { 'msix' }
    '.msixbundle'           { 'msix' }
    '.appx'                 { 'appx' }
    '.appxbundle'           { 'appx' }
    '.exe'                  { 'exe' }
    '.zip'                  { 'zip' }
    default                 { 'exe' }
}
# Default silent args by inferred type. Many EXE installers respect /S
# (NSIS) or /VERYSILENT (Inno) — admins can override via -SilentArgsOverride.
$defaultSilent = switch ($installerType) {
    'msi'      { '/qn /norestart' }
    'wix'      { '/quiet /norestart' }
    'burn'     { '/quiet /norestart' }
    'msix'     { '' }
    'appx'     { '' }
    default    { '/S' }
}
$silentArgs = if ($SilentArgsOverride) { $SilentArgsOverride } else { $defaultSilent }

$metadata = [ordered]@{
    fileName             = $Filename
    sha256               = $sha
    installerType        = $installerType
    nestedInstallerType  = $null
    installerLocale      = $null
    architecture         = 'x64'
    scope                = $null
    silentArgs           = $silentArgs
    silentUninstallArgs  = $silentArgs
    productCode          = $null
    packageFamilyName    = $null
    successExitCodes     = @(0, 1641, 3010)
    version              = $Version
    sourceUrl            = $InstallerUrl
}
$metadataPath = Join-Path $OutputDirectory 'installer-metadata.json'
$metadata | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $metadataPath -Encoding UTF8
Write-Host "Installer metadata written to $metadataPath"
Write-Host "  fileName      = $($metadata.fileName)"
Write-Host "  installerType = $($metadata.installerType)"
Write-Host "  silentArgs    = $($metadata.silentArgs)"
Write-Host "  sha256        = $($metadata.sha256)"

if ($env:GITHUB_OUTPUT) {
    Add-Content -Path $env:GITHUB_OUTPUT -Value "installer_file_name=$($metadata.fileName)"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "installer_type=$($metadata.installerType)"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "installer_sha256=$($metadata.sha256)"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "package_files_dir=$OutputDirectory"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "metadata_path=$metadataPath"
}
