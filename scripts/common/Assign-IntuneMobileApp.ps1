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

$headers = @{
    Authorization = "Bearer $AccessToken"
    "Content-Type" = "application/json"
}

function Invoke-GraphJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $false)]
        [object]$Body
    )

    if ($null -ne $Body) {
        $json = $Body | ConvertTo-Json -Depth 100
        return Invoke-RestMethod -Uri $Uri -Method $Method -Headers $headers -Body $json
    }

    return Invoke-RestMethod -Uri $Uri -Method $Method -Headers $headers
}

function Escape-ODataString {
    param([Parameter(Mandatory = $true)][string]$Value)
    return $Value -replace "'", "''"
}

function New-ModernDevMgmtMailNickname {
    param([Parameter(Mandatory = $true)][string]$DisplayName)
    $base = ($DisplayName.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ($base.Length -gt 48) {
        $base = $base.Substring(0, 48).Trim('-')
    }
    if ([string]::IsNullOrWhiteSpace($base)) {
        $base = 'mdm-app'
    }
    $chars = 'abcdef0123456789'.ToCharArray()
    $suffix = -join (1..6 | ForEach-Object { $chars[(Get-Random -Minimum 0 -Maximum $chars.Length)] })
    return "$base-$suffix"
}

function Remove-ObjectPropertyIfPresent {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    if ($Object.PSObject.Properties[$Name]) {
        $Object.PSObject.Properties.Remove($Name)
    }
}

function Set-ObjectProperty {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [object]$Value
    )
    if ($Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Ensure-ModernDevMgmtAssignmentGroup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DisplayName,

        [Parameter(Mandatory = $false)]
        [string]$Description
    )

    $escaped = Escape-ODataString -Value $DisplayName
    $filter = [System.Uri]::EscapeDataString("displayName eq '$escaped'")
    $existing = Invoke-GraphJson -Method 'GET' -Uri "$IntuneApiUrl/groups?%24select=id,displayName&%24top=1&%24filter=$filter"
    $match = @($existing.value | Where-Object { $_.displayName -eq $DisplayName } | Select-Object -First 1)
    if ($match.Count -gt 0 -and $match[0].id) {
        Write-Host "Using existing assignment group '$DisplayName' ($($match[0].id))."
        return [string]$match[0].id
    }

    $body = @{
        displayName = $DisplayName
        description = if ($Description) { $Description } else { "Vanguard assignment group." }
        mailEnabled = $false
        mailNickname = New-ModernDevMgmtMailNickname -DisplayName $DisplayName
        securityEnabled = $true
        groupTypes = @()
    }
    $created = Invoke-GraphJson -Method 'POST' -Uri "$IntuneApiUrl/groups" -Body $body
    if (-not $created.id) {
        throw "Microsoft Graph did not return an id after creating assignment group '$DisplayName'."
    }
    Write-Host "Created assignment group '$DisplayName' ($($created.id))."
    return [string]$created.id
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

foreach ($assignment in $assignments) {
    $target = $assignment.target
    if (-not $target) {
        continue
    }
    if ([string]$target.'@odata.type' -ne '#microsoft.graph.groupAssignmentTarget') {
        continue
    }

    $displayName = ''
    $description = ''
    if ($target.PSObject.Properties['modernDevMgmtGroupDisplayName']) {
        $displayName = [string]$target.modernDevMgmtGroupDisplayName
    }
    if ($target.PSObject.Properties['modernDevMgmtGroupDescription']) {
        $description = [string]$target.modernDevMgmtGroupDescription
    }

    if ([string]::IsNullOrWhiteSpace([string]$target.groupId) -and -not [string]::IsNullOrWhiteSpace($displayName)) {
        $groupId = Ensure-ModernDevMgmtAssignmentGroup -DisplayName $displayName -Description $description
        Set-ObjectProperty -Object $target -Name 'groupId' -Value $groupId
    }

    Remove-ObjectPropertyIfPresent -Object $target -Name 'modernDevMgmtGroupDisplayName'
    Remove-ObjectPropertyIfPresent -Object $target -Name 'modernDevMgmtGroupDescription'

    if ([string]::IsNullOrWhiteSpace([string]$target.groupId)) {
        throw "Assignment target '$($displayName)' does not have a groupId and cannot be applied."
    }
}

$body = @{
    mobileAppAssignments = $assignments
} | ConvertTo-Json -Depth 100

$uri = "$IntuneApiUrl/deviceAppManagement/mobileApps/$AppId/assign"
Write-Host "Applying $($assignments.Count) assignment(s) to Intune app $AppId"
Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $body | Out-Null
Write-Host "Assignments applied."
