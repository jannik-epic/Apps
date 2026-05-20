# Fetch-WingetPackageInfo.ps1
# Fetches package information from the Winget repository

param(
    [Parameter(Mandatory = $true)]
    [string]$PackageId,

    [Parameter(Mandatory = $false)]
    [ValidateSet("winget", "msstore")]
    [string]$PackageSource = "winget"
)

Write-Host "Fetching information for package: $PackageId from source: $PackageSource"

# `winget search` treats the id as a regex on some runner builds, which
# crashes on legitimate package ids that contain regex metacharacters such
# as `Notepad++.Notepad++` ("Nested quantifier '+'") or anything with `.`
# or `(`. Skip the pre-check and go straight to `winget show`, which uses
# an exact lookup. If the package id is invalid winget will exit non-zero
# and we fall through to the "not found" branch with a clean error.
$showResult = winget show --id $PackageId --source $PackageSource --accept-source-agreements 2>&1 | Out-String
$showExit = $LASTEXITCODE

if ($showExit -eq 0 -and $showResult -match "Publisher:|Version:") {
    Write-Host "Package found in source: $PackageSource"

    # Extract information
    $publisher = ""
    $version = ""
    $description = ""

    if ($showResult -match "Publisher:\s*(.+)") {
        $publisher = $matches[1].Trim()
    }
    if ($showResult -match "Version:\s*(.+)") {
        $version = $matches[1].Trim()
    }
    if ($showResult -match "Description:\s*(.+)") {
        $description = $matches[1].Trim()
    }

    # Set outputs
    if ($env:GITHUB_OUTPUT) {
        Add-Content -Path $env:GITHUB_OUTPUT -Value "publisher=$publisher"
        Add-Content -Path $env:GITHUB_OUTPUT -Value "version=$version"
        Add-Content -Path $env:GITHUB_OUTPUT -Value "description=$description"
        Add-Content -Path $env:GITHUB_OUTPUT -Value "package_found=true"
    }

    Write-Host "Publisher: $publisher"
    Write-Host "Version: $version"
    Write-Host "Description: $description"
} else {
    if ($env:GITHUB_OUTPUT) {
        Add-Content -Path $env:GITHUB_OUTPUT -Value "package_found=false"
    }
    Write-Error "Package '$PackageId' not found in Winget repository"
    exit 1
}
