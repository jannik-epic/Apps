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

# Search for the package using winget
$searchResult = winget search --id $PackageId --source $PackageSource --exact --accept-source-agreements | Out-String

if ($searchResult -match $PackageId) {
    Write-Host "Package found in source: $PackageSource"

    # Get package details
    $showResult = winget show --id $PackageId --source $PackageSource --accept-source-agreements | Out-String

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
