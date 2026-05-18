# Create-IntuneApplication.ps1
# Builds a real .intunewin package from generated Winget scripts and uploads it
# as a Win32LobApp with content version + file commit through Microsoft Graph.

param(
    [Parameter(Mandatory = $true)]
    [string]$AccessToken,

    [Parameter(Mandatory = $true)]
    [string]$PackageId,

    [Parameter(Mandatory = $false)]
    [string]$AppName,

    [Parameter(Mandatory = $false)]
    [string]$AppDescription,

    [Parameter(Mandatory = $false)]
    [string]$Publisher,

    [Parameter(Mandatory = $false)]
    [string]$Version,

    [Parameter(Mandatory = $false)]
    [string]$AppIconBase64,

    [Parameter(Mandatory = $false)]
    [string]$InstallContext = "system",

    [Parameter(Mandatory = $false)]
    [bool]$UsePSADT = $true,

    [Parameter(Mandatory = $false)]
    [string]$IntuneApiUrl = "https://graph.microsoft.com/v1.0",

    [Parameter(Mandatory = $false)]
    [bool]$DryRun = $false,

    [Parameter(Mandatory = $false)]
    [string]$PackageFilesDirectory,

    [Parameter(Mandatory = $false)]
    [string]$InstallCommandLine,

    [Parameter(Mandatory = $false)]
    [string]$UninstallCommandLine,

    [Parameter(Mandatory = $false)]
    [string]$PackageSource = "Winget",

    [Parameter(Mandatory = $false)]
    [string]$PackageNotes
)

$ErrorActionPreference = "Stop"

function Set-WorkflowOutput {
    param([string]$Name, [string]$Value)
    if ($env:GITHUB_OUTPUT) {
        Add-Content -Path $env:GITHUB_OUTPUT -Value "$Name=$Value"
    }
}

function Invoke-GraphJson {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("GET", "POST", "PATCH")]
        [string]$Method,
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [object]$Body = $null,
        [int]$TimeoutSec = 120
    )

    $headers = @{
        Authorization = "Bearer $AccessToken"
        "Content-Type" = "application/json"
    }
    $args = @{
        Method = $Method
        Uri = $Uri
        Headers = $headers
        TimeoutSec = $TimeoutSec
    }
    if ($null -ne $Body) {
        $args.Body = ($Body | ConvertTo-Json -Depth 20)
    }
    Invoke-RestMethod @args
}

function Invoke-GraphDelete {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [int]$TimeoutSec = 120
    )

    Invoke-RestMethod `
        -Method DELETE `
        -Uri $Uri `
        -Headers @{ Authorization = "Bearer $AccessToken" } `
        -TimeoutSec $TimeoutSec | Out-Null
}

function Convert-AppIconBase64ToPayload {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $raw = $Value.Trim()
    $mime = "image/png"
    if ($raw -match "^data:([^;,]+);base64,(.+)$") {
        $mime = $Matches[1]
        $raw = $Matches[2]
    }
    try {
        $bytes = [Convert]::FromBase64String($raw)
        if ($bytes.Length -eq 0 -or $raw.Length -gt 1048576) {
            Write-Warning "Skipping app icon because it is empty or too large for Intune."
            return $null
        }
        return @{
            '@odata.type' = '#microsoft.graph.mimeContent'
            type = $mime
            value = $raw
        }
    } catch {
        Write-Warning "Skipping invalid app icon payload: $($_.Exception.Message)"
        return $null
    }
}

function Ensure-IntuneWinAppUtil {
    $toolsDir = Join-Path $PWD ".tools"
    New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
    $utilPath = Join-Path $toolsDir "IntuneWinAppUtil.exe"
    if (-not (Test-Path -LiteralPath $utilPath -PathType Leaf)) {
        $url = "https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/raw/master/IntuneWinAppUtil.exe"
        Write-Host "Downloading IntuneWinAppUtil.exe..."
        Invoke-WebRequest -Uri $url -OutFile $utilPath -UseBasicParsing
    }
    $utilPath
}

function New-WingetPackageSource {
    $sourceDir = Join-Path $PWD "winget-package-source"
    if (Test-Path -LiteralPath $sourceDir) {
        Remove-Item -LiteralPath $sourceDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $sourceDir | Out-Null
    Copy-Item -LiteralPath "install_script.ps1" -Destination (Join-Path $sourceDir "install_script.ps1") -Force
    Copy-Item -LiteralPath "uninstall_script.ps1" -Destination (Join-Path $sourceDir "uninstall_script.ps1") -Force
    Copy-Item -LiteralPath "detection_script.ps1" -Destination (Join-Path $sourceDir "detection_script.ps1") -Force
    if ($PackageFilesDirectory) {
        if (-not (Test-Path -LiteralPath $PackageFilesDirectory -PathType Container)) {
            throw "PackageFilesDirectory was not found: $PackageFilesDirectory"
        }
        Get-ChildItem -LiteralPath $PackageFilesDirectory -Force | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $sourceDir -Recurse -Force
        }
    }
    $sourceDir
}

function New-IntuneWinPackage {
    param([string]$SourceDir)

    $utilPath = Ensure-IntuneWinAppUtil
    $outDir = Join-Path $PWD "intunewin-output"
    if (Test-Path -LiteralPath $outDir) {
        Remove-Item -LiteralPath $outDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null

    & $utilPath -c $SourceDir -s "install_script.ps1" -o $outDir -q 2>&1 | ForEach-Object {
        Write-Host $_
    }
    if ($LASTEXITCODE -ne 0) {
        throw "IntuneWinAppUtil failed with exit code $LASTEXITCODE"
    }
    $packagePath = Join-Path $outDir "install_script.intunewin"
    if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) {
        throw "IntuneWinAppUtil did not produce $packagePath"
    }
    $packagePath
}

function Get-XmlText {
    param([xml]$Xml, [string]$LocalName)
    $node = $Xml.SelectSingleNode("//*[local-name()='$LocalName']")
    if ($node) { return [string]$node.InnerText }
    $null
}

function Get-IntuneWinPackageInfo {
    param([string]$IntuneWinPath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $extractDir = Join-Path ([IO.Path]::GetTempPath()) ("modern-dev-mgmt-intunewin-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
    [System.IO.Compression.ZipFile]::ExtractToDirectory($IntuneWinPath, $extractDir)

    $detectionXmlPath = Get-ChildItem -LiteralPath $extractDir -Recurse -Filter "Detection.xml" | Select-Object -First 1
    if (-not $detectionXmlPath) {
        throw "Detection.xml was not found in $IntuneWinPath"
    }
    [xml]$detectionXml = Get-Content -LiteralPath $detectionXmlPath.FullName -Raw

    $encryptedContent = Get-ChildItem -LiteralPath $extractDir -Recurse -File |
        Where-Object { $_.Name -ieq "IntunePackage.intunewin" } |
        Select-Object -First 1
    if (-not $encryptedContent) {
        $encryptedContent = Get-ChildItem -LiteralPath $extractDir -Recurse -File |
            Where-Object { $_.FullName -ne $detectionXmlPath.FullName -and $_.Extension -ieq ".intunewin" } |
            Sort-Object Length -Descending |
            Select-Object -First 1
    }
    if (-not $encryptedContent) {
        throw "Encrypted Intune content was not found in $IntuneWinPath"
    }

    $sizeText = Get-XmlText $detectionXml "UnencryptedContentSize"
    $fileName = Get-XmlText $detectionXml "FileName"
    $setupFile = Get-XmlText $detectionXml "SetupFile"
    if (-not $fileName) { $fileName = $encryptedContent.Name }
    if (-not $setupFile) { $setupFile = "install_script.ps1" }

    $profileIdentifier = Get-XmlText $detectionXml "ProfileIdentifier"
    if (-not $profileIdentifier) { $profileIdentifier = "ProfileVersion1" }
    $fileDigestAlgorithm = Get-XmlText $detectionXml "FileDigestAlgorithm"
    if (-not $fileDigestAlgorithm) { $fileDigestAlgorithm = "SHA256" }
    $fileEncryptionInfo = @{
        encryptionKey = Get-XmlText $detectionXml "EncryptionKey"
        macKey = Get-XmlText $detectionXml "MacKey"
        initializationVector = Get-XmlText $detectionXml "InitializationVector"
        mac = Get-XmlText $detectionXml "Mac"
        profileIdentifier = $profileIdentifier
        fileDigest = Get-XmlText $detectionXml "FileDigest"
        fileDigestAlgorithm = $fileDigestAlgorithm
    }
    $requiredEncryptionFields = @(
        "encryptionKey",
        "macKey",
        "initializationVector",
        "mac",
        "profileIdentifier",
        "fileDigest",
        "fileDigestAlgorithm"
    )
    $missingEncryptionFields = $requiredEncryptionFields | Where-Object { -not $fileEncryptionInfo[$_] }
    if ($missingEncryptionFields.Count -gt 0) {
        throw "Detection.xml is missing required Intune encryption metadata: $($missingEncryptionFields -join ', ')"
    }

    Write-Host "IntuneWin metadata: fileName=$fileName setupFile=$setupFile encryptedSize=$($encryptedContent.Length) unencryptedSize=$sizeText"
    Write-Host (
        "Encryption metadata lengths: key={0}, macKey={1}, iv={2}, mac={3}, digest={4}, profile={5}, digestAlgorithm={6}" -f
            $fileEncryptionInfo.encryptionKey.Length,
            $fileEncryptionInfo.macKey.Length,
            $fileEncryptionInfo.initializationVector.Length,
            $fileEncryptionInfo.mac.Length,
            $fileEncryptionInfo.fileDigest.Length,
            $fileEncryptionInfo.profileIdentifier,
            $fileEncryptionInfo.fileDigestAlgorithm
    )

    @{
        encryptedContentPath = $encryptedContent.FullName
        encryptedSize = [int64]$encryptedContent.Length
        unencryptedSize = if ($sizeText) { [int64]$sizeText } else { [int64](Get-Item -LiteralPath $IntuneWinPath).Length }
        fileName = $fileName
        setupFile = $setupFile
        fileEncryptionInfo = $fileEncryptionInfo
    }
}

function Wait-GraphFileState {
    param(
        [string]$AppId,
        [string]$ContentVersionId,
        [string]$FileId,
        [string]$WantedState,
        [int]$TimeoutSec = 180
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $file = Invoke-GraphJson -Method GET -Uri "$IntuneApiUrl/deviceAppManagement/mobileApps/$AppId/microsoft.graph.win32LobApp/contentVersions/$ContentVersionId/files/$FileId" -TimeoutSec 60
        if ($file.uploadState -eq $WantedState) { return $file }
        if ([string]$file.uploadState -like "*Failed") {
            throw "Intune file processing failed with state $($file.uploadState)"
        }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)
    throw "Timed out waiting for Intune file state $WantedState"
}

function Send-AzureBlobFile {
    param([string]$AzureStorageUri, [string]$Path)

    $blockSize = 4 * 1024 * 1024
    $file = Get-Item -LiteralPath $Path
    $totalBlocks = [Math]::Ceiling($file.Length / $blockSize)
    $blockIds = New-Object System.Collections.Generic.List[string]
    $buffer = New-Object byte[] $blockSize
    $stream = [System.IO.File]::OpenRead($Path)

    Write-Host "Uploading encrypted content to Intune blob in $totalBlocks block(s) ($($file.Length) bytes)."
    try {
        $isoEncoding = [System.Text.Encoding]::GetEncoding("iso-8859-1")
        $blockIndex = 0
        while (($bytesRead = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $blockId = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes($blockIndex.ToString("0000")))
            $blockIds.Add($blockId)
            $payload = if ($bytesRead -eq $buffer.Length) {
                $buffer
            } else {
                $slice = New-Object byte[] $bytesRead
                [Array]::Copy($buffer, 0, $slice, 0, $bytesRead)
                $slice
            }
            $encodedBody = $isoEncoding.GetString($payload)
            $separator = if ($AzureStorageUri.Contains("?")) { "&" } else { "?" }
            $blockUrl = "$AzureStorageUri${separator}comp=block&blockid=$blockId"
            Invoke-WebRequest `
                -Method Put `
                -Uri $blockUrl `
                -Headers @{ "x-ms-blob-type" = "BlockBlob" } `
                -Body $encodedBody `
                -TimeoutSec 300 `
                -UseBasicParsing | Out-Null
            $blockIndex += 1
            $progress = [Math]::Round(($blockIndex / [Math]::Max($totalBlocks, 1)) * 100, 1)
            Write-Host "Uploaded block $blockIndex/$totalBlocks ($progress%)."
        }
    } finally {
        $stream.Dispose()
    }

    $blockListXml = '<?xml version="1.0" encoding="utf-8"?><BlockList>'
    foreach ($blockId in $blockIds) {
        $blockListXml += "<Latest>$blockId</Latest>"
    }
    $blockListXml += '</BlockList>'
    $separator = if ($AzureStorageUri.Contains("?")) { "&" } else { "?" }
    $commitUrl = "$AzureStorageUri${separator}comp=blocklist"
    Invoke-WebRequest `
        -Method Put `
        -Uri $commitUrl `
        -Body $blockListXml `
        -ContentType "application/xml" `
        -TimeoutSec 300 `
        -UseBasicParsing | Out-Null
    Write-Host "Azure blob block list committed."
}

if (-not $AppName) {
    $AppName = $PackageId.Split('.')[-1]
}
if (-not $AppDescription) {
    $AppDescription = "$AppName installed via Winget"
}
if (-not $Publisher) {
    $Publisher = "Winget"
}

$appId = $null

try {
    $sourceDir = New-WingetPackageSource
    $intuneWinPath = New-IntuneWinPackage -SourceDir $sourceDir
    $packageInfo = Get-IntuneWinPackageInfo -IntuneWinPath $intuneWinPath

    Write-Host "Built Win32 package: $intuneWinPath"

    if ($DryRun) {
        Write-Host "Dry run complete. The .intunewin package was built but no Intune app was created."
        Set-WorkflowOutput -Name "app_name" -Value $AppName
        Set-WorkflowOutput -Name "success" -Value "true"
        exit 0
    }

    $detectionScript = Get-Content -Path "detection_script.ps1" -Raw
    $installCommand = if ($InstallCommandLine) { $InstallCommandLine } else { 'powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File .\install_script.ps1' }
    $uninstallCommand = if ($UninstallCommandLine) { $UninstallCommandLine } else { 'powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File .\uninstall_script.ps1' }
    $notes = if ($PackageNotes) {
        $PackageNotes
    } else {
        "Package ID: $PackageId`nInstalled via: $PackageSource`nInstall Method: $InstallContext`nUsing PSADT-compatible script hooks: $UsePSADT`nDeployed via: GitHub Actions"
    }

    $appData = @{
        '@odata.type' = '#microsoft.graph.win32LobApp'
        displayName = $AppName
        description = $AppDescription
        publisher = $Publisher
        displayVersion = $Version
        fileName = $packageInfo.fileName
        setupFilePath = $packageInfo.setupFile
        installCommandLine = $installCommand
        uninstallCommandLine = $uninstallCommand
        installExperience = @{
            '@odata.type' = '#microsoft.graph.win32LobAppInstallExperience'
            runAsAccount = $InstallContext
            deviceRestartBehavior = 'basedOnReturnCode'
        }
        applicableArchitectures = 'x64'
        minimumSupportedWindowsRelease = '1607'
        rules = @(
            @{
                '@odata.type' = '#microsoft.graph.win32LobAppPowerShellScriptRule'
                ruleType = 'detection'
                enforceSignatureCheck = $false
                runAs32Bit = $false
                operationType = 'notConfigured'
                operator = 'notConfigured'
                scriptContent = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($detectionScript))
            }
        )
        returnCodes = @(
            @{ returnCode = 0; type = 'success' }
            @{ returnCode = 1707; type = 'success' }
            @{ returnCode = 1641; type = 'hardReboot' }
            @{ returnCode = 3010; type = 'softReboot' }
            @{ returnCode = 1618; type = 'retry' }
        )
        notes = $notes
    }
    $iconPayload = Convert-AppIconBase64ToPayload -Value $AppIconBase64
    if ($iconPayload) {
        $appData.largeIcon = $iconPayload
    }

    $app = Invoke-GraphJson -Method POST -Uri "$IntuneApiUrl/deviceAppManagement/mobileApps" -Body $appData
    $appId = [string]$app.id
    $appDisplayName = [string]$app.displayName
    Write-Host "Created Win32 application shell: $appDisplayName (ID: $appId)"

    $contentVersion = Invoke-GraphJson -Method POST -Uri "$IntuneApiUrl/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions" -Body @{}
    $contentVersionId = [string]$contentVersion.id

    $fileBody = @{
        '@odata.type' = '#microsoft.graph.mobileAppContentFile'
        name = $packageInfo.fileName
        size = $packageInfo.unencryptedSize
        sizeEncrypted = $packageInfo.encryptedSize
        manifest = $null
        isDependency = $false
    }
    $file = Invoke-GraphJson -Method POST -Uri "$IntuneApiUrl/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions/$contentVersionId/files" -Body $fileBody
    $fileId = [string]$file.id
    $file = Wait-GraphFileState -AppId $appId -ContentVersionId $contentVersionId -FileId $fileId -WantedState "azureStorageUriRequestSuccess"

    Send-AzureBlobFile -AzureStorageUri ([string]$file.azureStorageUri) -Path ([string]$packageInfo.encryptedContentPath)

    Write-Host "Committing Intune file with validated encryption metadata..."
    Invoke-GraphJson -Method POST -Uri "$IntuneApiUrl/deviceAppManagement/mobileApps/$appId/microsoft.graph.win32LobApp/contentVersions/$contentVersionId/files/$fileId/commit" -Body @{
        fileEncryptionInfo = $packageInfo.fileEncryptionInfo
    } | Out-Null
    Wait-GraphFileState -AppId $appId -ContentVersionId $contentVersionId -FileId $fileId -WantedState "commitFileSuccess" | Out-Null

    Invoke-GraphJson -Method PATCH -Uri "$IntuneApiUrl/deviceAppManagement/mobileApps/$appId" -Body @{
        '@odata.type' = '#microsoft.graph.win32LobApp'
        committedContentVersion = $contentVersionId
    } | Out-Null

    Write-Host "Successfully uploaded application content: $appDisplayName (ID: $appId)"
    Set-WorkflowOutput -Name "app_id" -Value $appId
    Set-WorkflowOutput -Name "app_name" -Value $appDisplayName
    Set-WorkflowOutput -Name "success" -Value "true"
}
catch {
    $failure = $_
    if (-not $DryRun -and $appId) {
        try {
            Invoke-GraphDelete -Uri "$IntuneApiUrl/deviceAppManagement/mobileApps/$appId"
            Write-Host "Cleaned up failed Intune application shell: $appId"
        } catch {
            Write-Warning "Could not clean up failed Intune application shell $appId`: $_"
        }
    }
    Write-Error "Failed to create/upload application: $failure"
    Set-WorkflowOutput -Name "success" -Value "false"
    exit 1
}
