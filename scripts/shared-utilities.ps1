# Shared Utilities for Intune Deployment Workflows
# This file contains common functions and utilities used by deployment workflows

function Test-IntuneConnection {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AccessToken
    )

    try {
        $headers = @{
            'Authorization' = "Bearer $AccessToken"
            'Content-Type' = 'application/json'
        }

        $response = Invoke-RestMethod -Uri "$env:INTUNE_API_URL/deviceAppManagement/mobileApps?$select=id&$top=1" -Headers $headers -Method GET
        return $true
    }
    catch {
        Write-Error "Failed to connect to Intune: $_"
        return $false
    }
}

function Get-AppByName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AccessToken,
        [Parameter(Mandatory = $true)]
        [string]$AppName
    )

    try {
        $headers = @{
            'Authorization' = "Bearer $AccessToken"
            'Content-Type' = 'application/json'
        }

        $encodedName = [System.Web.HttpUtility]::UrlEncode($AppName)
        $response = Invoke-RestMethod -Uri "$env:INTUNE_API_URL/deviceAppManagement/mobileApps?$filter=displayName eq '$encodedName'" -Headers $headers -Method GET

        return $response.value
    }
    catch {
        Write-Error "Failed to search for app: $_"
        return $null
    }
}

function Write-WorkflowSummary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,
        [Parameter(Mandatory = $true)]
        [hashtable]$Details
    )

    Write-Host ""
    Write-Host "=" * 50
    Write-Host $Title
    Write-Host "=" * 50

    foreach ($key in $Details.Keys) {
        Write-Host "$key : $($Details[$key])"
    }

    Write-Host "=" * 50
    Write-Host ""
}

function Set-GitHubOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    Add-Content -Path $env:GITHUB_OUTPUT -Value "$Name=$Value"
}

function Set-GitHubStepSummary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $Content
}