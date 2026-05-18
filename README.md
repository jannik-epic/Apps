# Intune App Deployment Workflows

This repository contains automated workflows for deploying applications to Microsoft Intune using GitHub Actions.

## Available Workflows

### 1. Winget App Deployment
- **File**: `.github/workflows/deploy-winget-app.yml`
- **Purpose**: Deploy Windows applications from the Winget repository to Intune
- **Features**:
  - Support for PowerShell App Deployment Toolkit (PSADT)
  - Automatic detection script generation
  - Registry-based fallback detection
  - Custom installation contexts (system/user)
  - Assignment template application to Required/Available/Uninstall groups

### 2. Homebrew App Deployment
- **File**: `.github/workflows/deploy-homebrew-app.yml`
- **Purpose**: Deploy macOS/Linux applications from Homebrew to Intune
- **Features**:
  - Support for both formulae and casks
  - Automatic Homebrew installation if missing
  - PATH configuration for different Homebrew installations
  - Custom detection scripts
  - Assignment template application to Required/Available/Uninstall groups

### 3. Custom Installer Deployment
- **File**: `.github/workflows/deploy-custom-package.yml`
- **Purpose**: Deploy uploaded Windows MSI/EXE installers from Modern Dev Mgmt release assets to Intune
- **Features**:
  - Downloads the uploaded installer from a tenant-repo GitHub release asset
  - Packages the installer together with generated install, uninstall and detection scripts
  - Supports Modern Dev Mgmt app-setting script overrides through base64 workflow inputs
  - Applies assignment templates and writes auditable run state under `.modern-dev-mgmt/runs/`

### 4. Custom macOS Package Deployment
- **File**: `.github/workflows/deploy-custom-macos-package.yml`
- **Purpose**: Deploy uploaded macOS PKG/DMG installers from Modern Dev Mgmt release assets to Intune
- **Features**:
  - Downloads the uploaded PKG/DMG from a tenant-repo GitHub release asset
  - Converts DMGs containing an app bundle into a signed-package-ready PKG payload
  - Uploads through Microsoft Graph `macOSPkgApp` content-version flow
  - Applies assignment templates and writes auditable run state under `.modern-dev-mgmt/runs/`

### 5. Patch Scan
- **File**: `.github/workflows/patch-scan.yml`
- **Purpose**: Scheduled upstream version checks for managed Winget and Homebrew apps
- **Features**:
  - Runs every 30 minutes
  - Detects major, minor and patch updates
  - Writes `patch-analysis.json` for Modern Dev Mgmt to ingest

### 6. Intune Inventory Coverage
- **File**: `.github/workflows/intune-inventory-coverage.yml`
- **Purpose**: Scheduled check for detected device apps that have no centrally managed Intune app
- **Features**:
  - Filters out Android/iOS/system packages outside the Windows/macOS scope
  - Compares detected apps with Intune managed apps
  - Writes `intune-inventory-coverage.json` for MSP review

### 7. Wave Assignment
- **File**: `.github/workflows/apply-wave-assignment.yml`
- **Purpose**: Apply follow-up deployment-wave assignments for existing Intune apps
- **Features**:
  - Uses the same Azure federated credential model as deployments
  - Writes auditable run and wave status files under `.modern-dev-mgmt/`
  - Lets the Modern Dev Mgmt web UI monitor rollout progress without doing direct Intune writes

### 8. Radar Group Sync
- **File**: `.github/workflows/sync-dynamic-app-group.yml`
- **Purpose**: Reconcile per-app dynamic Entra groups for Radar tracking
- **Features**:
  - Resolves Intune device IDs to Entra device objects inside the tenant repository
  - Adds outdated devices and removes devices that reached the target version
  - Persists auditable Radar sync results under `.modern-dev-mgmt/dynamic-groups/`

### 9. Directory Provisioning
- **File**: `.github/workflows/provision-directory-object.yml`
- **Purpose**: Create or update tenant Entra users and security groups from Modern Dev Mgmt
- **Features**:
  - Runs through the tenant repository and federated credential
  - Supports dry-run planning before writing to Entra ID
  - Keeps user/group provisioning auditable with GitHub run summaries

### 10. Tenant Operation Packs
- **File**: `.github/workflows/tenant-operation-pack.yml`
- **Purpose**: Run read-side tenant administration packs from Modern Dev Mgmt while keeping Graph access inside the tenant repository
- **Features**:
  - Covers identity, tenant administration, security, Intune, Teams/SharePoint, email/Exchange boundaries and reporting evidence
  - Writes JSON/CSV evidence under `.modern-dev-mgmt/tenant-operations/`
  - Uploads the same evidence bundle as a GitHub Actions artifact
  - Supports optional repository commits for audit trails

## Usage

### Deploying a Winget Application

1. Go to the **Actions** tab in your repository
2. Select **Deploy Winget App to Intune**
3. Click **Run workflow** and provide:
   - **Package ID**: The Winget package identifier (e.g., `Microsoft.VisualStudioCode`)
   - **App Name**: Display name in Intune (optional, will use package name if not provided)
   - **Description**: App description (optional, will fetch from Winget if not provided)
   - **Install Context**: Choose between `system` or `user` installation
   - **Use PSADT**: Enable PowerShell App Deployment Toolkit for enterprise deployment
   - **Detection Script**: Custom PowerShell detection script (optional)

### Deploying a Homebrew Application

1. Go to the **Actions** tab in your repository
2. Select **Deploy Homebrew App to Intune**
3. Click **Run workflow** and provide:
   - **Package ID**: The Homebrew package name (e.g., `visual-studio-code` or `node`)
   - **Package Type**: Choose between `cask` (GUI applications) or `formula` (CLI tools)
   - **App Name**: Display name in Intune (optional)
   - **Description**: App description (optional)
   - **Install Context**: Choose between `system` or `user` installation
   - **Detection Script**: Custom shell detection script (optional)

## Authentication

These workflows use Azure AD federated credentials for secure authentication with Microsoft Graph API. No secrets are stored in the repository.

### Required Azure AD App Registration Permissions

The following application permissions are required:

- `DeviceManagementApps.ReadWrite.All` - Read and write Intune applications
- `DeviceManagementConfiguration.ReadWrite.All` - Read and write Intune configuration
- `DeviceManagementServiceConfig.Read.All` - Read Intune service configuration, enrollment, and Autopilot reporting
- `DeviceManagementManagedDevices.Read.All` - Read detected app/device inventory for coverage checks
- `DeviceManagementScripts.Read.All` - Read Intune remediation script and assignment evidence
- `ThreatHunting.Read.All` - Read Defender advanced hunting evidence where available
- `Directory.Read.All` - Read directory data
- `Group.ReadWrite.All` - Create assignment backing groups from Modern Dev Mgmt
- `User.ReadWrite.All` - Create or update users from tenant GitHub workflows
- `Application.ReadWrite.All` - Manage application registrations
- `AppRoleAssignment.ReadWrite.All` - Grant/administer application role assignments

## Workflow Outputs

The workflows provide detailed outputs including:

- Application ID in Intune
- Deployment status
- Generated scripts (install, uninstall, detection)
- Links to the created application in Intune admin center
- Modern Dev Mgmt run state under `.modern-dev-mgmt/runs/`
- Patch and wave state under `.modern-dev-mgmt/patch-runs/` and `.modern-dev-mgmt/waves/`
- Tenant operation evidence under `.modern-dev-mgmt/tenant-operations/`

## Troubleshooting

### Common Issues

1. **Authentication Failures**
   - Verify federated credentials are configured correctly
   - Check that the App Registration has required permissions
   - Ensure admin consent has been granted

2. **Package Not Found**
   - Verify the package ID is correct for the respective package manager
   - Check that the package exists in the public repository

3. **Deployment Failures**
   - Review the workflow logs for detailed error messages
   - Verify Intune tenant permissions
   - Check that the scripts are valid for the target platform

### Getting Help

- Review workflow run logs for detailed error information
- Check the GitHub Actions documentation for workflow syntax
- Refer to Microsoft Graph API documentation for Intune operations

## Security Best Practices

- Federated credentials provide secure, token-based authentication
- No long-lived secrets are stored in the repository
- All API calls use encrypted HTTPS connections
- Workflows run in isolated GitHub-hosted runners

## Contributing

When modifying workflows:

1. Test changes in a development environment first
2. Validate all script generation functions
3. Ensure proper error handling is in place
4. Update documentation as needed

## Links

- [Microsoft Intune Documentation](https://docs.microsoft.com/en-us/mem/intune/)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)
- [Winget Package Repository](https://github.com/microsoft/winget-pkgs)
- [Homebrew Formulae](https://formulae.brew.sh/)