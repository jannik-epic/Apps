param(
    [Parameter(Mandatory = $true)]
    [string]$AccessToken,

    [Parameter(Mandatory = $true)]
    [string]$AppId,

    [Parameter(Mandatory = $false)]
    [string]$AssignmentJson,

    [Parameter(Mandatory = $false)]
    [string]$IntuneApiUrl = "https://graph.microsoft.com/v1.0"
)

if ([string]::IsNullOrWhiteSpace($AssignmentJson)) {
    Write-Host "No assignment payload supplied; skipping app assignment."
    return
}

$payload = $AssignmentJson | ConvertFrom-Json -Depth 100
$assignments = @()
if ($payload.mobileAppAssignments) {
    $assignments = @($payload.mobileAppAssignments)
} elseif ($payload -is [array]) {
    $assignments = @($payload)
}

if ($assignments.Count -eq 0) {
    Write-Host "Assignment payload contains no mobileAppAssignments; skipping."
    return
}

$body = @{
    mobileAppAssignments = $assignments
} | ConvertTo-Json -Depth 100

$headers = @{
    Authorization = "Bearer $AccessToken"
    "Content-Type" = "application/json"
}

$uri = "$IntuneApiUrl/deviceAppManagement/mobileApps/$AppId/assign"
Write-Host "Applying $($assignments.Count) assignment(s) to Intune app $AppId"
Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $body | Out-Null
Write-Host "Assignments applied."
