#Requires -Version 5.1
<#
.SYNOPSIS
    NMM pre-install readiness check for Azure Government / GCC-H tenants.

.DESCRIPTION
    Runs four readiness phases against the active Azure subscription:
      Phase 0 — Permissions (Subscription Owner + Entra Global Administrator)
      Phase 1 — Resource provider registration (14 required providers)
      Phase 2 — Region eligibility (App Service SKU + Azure SQL edition/SLO availability)
      Phase 3 — Policy Deny check (advisory listing, plus an opt-in ground-truth probe)

    Works with any Azure cloud (commercial, AzureUSGovernment, etc.) by reading
    API endpoints from 'az cloud show' rather than hardcoding them. Log in with
    'az login' or 'az cloud set --name AzureUSGovernment && az login' before running.

    No deployment is performed — there is no ARM template for a Gov/GCC-H NMM
    install yet. Use this output to confirm readiness and choose a target region
    before running the NMM marketplace deployment separately.

.PARAMETER AppServiceSku
    App Service plan SKU to verify availability for. Default: B2.

.PARAMETER SqlEdition
    Azure SQL Database edition to verify. Default: Standard.

.PARAMETER SqlServiceObjective
    Azure SQL Database service objective (SLO) to verify. Default: S1.

.PARAMETER Regions
    Explicit list of region slugs to check (e.g. 'usgovvirginia','usgovtexas').
    Skips the geography prompt when provided.

.PARAMETER Geography
    Filter regions by geography group: US, Canada, NorthAmerica, Europe, UK,
    AsiaPacific, MiddleEast, Africa, SouthAmerica, Mexico, All.
    For GCC-H all available regions are in the US geography group.

.PARAMETER SubscriptionId
    Target subscription ID. Defaults to the currently active subscription.

.PARAMETER OutFile
    Optional path for a CSV export of region results.

.PARAMETER RegisterProviders
    Register any unregistered resource providers automatically.

.PARAMETER ProviderTimeoutMinutes
    How long to wait for provider registration to complete. Default: 15.

.PARAMETER Force
    Bypass permission and provider gates (use for re-checks when you know they
    are already resolved upstream).

.PARAMETER PolicyProbe
    Ground-truth Deny-policy check: creates representative NMM resource types
    (storage account, Key Vault, SQL server) in a throwaway resource group in
    the first eligible region (or the first of -Regions), captures any
    blocking policy IDs, then deletes the resource group. Requires the 'az'
    CLI only — no Az PowerShell module needed. Runs after the advisory Deny
    Policy Check, which always runs and does not create any resources.

.EXAMPLE
    # Run all phases; prompt for region geography interactively
    .\Check-NMMPreinstall-Gov.ps1

.EXAMPLE
    # Check only specific regions and export results
    .\Check-NMMPreinstall-Gov.ps1 -Regions usgovvirginia,usgovtexas -OutFile C:\Temp\nmm-gov-check.csv

.EXAMPLE
    # Register providers automatically if missing
    .\Check-NMMPreinstall-Gov.ps1 -RegisterProviders

.EXAMPLE
    # Also run the ground-truth policy probe (creates/deletes test resources)
    .\Check-NMMPreinstall-Gov.ps1 -PolicyProbe
#>
[CmdletBinding()]
param(
    [string]$AppServiceSku       = 'B2',
    [string]$SqlEdition          = 'Standard',
    [string]$SqlServiceObjective = 'S1',
    [string[]]$Regions,
    [string]$Geography,
    [string]$SubscriptionId,
    [string]$OutFile,
    [switch]$RegisterProviders,
    [int]$ProviderTimeoutMinutes = 15,
    [switch]$PolicyProbe,
    [switch]$Force
)

$ErrorActionPreference = 'Continue'

# Microsoft.Quota is not a valid registerable namespace in Azure Government (GCC-H)
# and is omitted from this list. All other 13 providers are available in gov cloud.
$NmmRequiredProviders = @(
    'Microsoft.KeyVault','Microsoft.Compute','Microsoft.Automation','Microsoft.Storage',
    'Microsoft.Insights','Microsoft.OperationalInsights','Microsoft.DesktopVirtualization',
    'Microsoft.Network','Microsoft.AAD','Microsoft.RecoveryServices','Microsoft.Web',
    'Microsoft.Solutions','Microsoft.Sql'
)

# ====================================================================
#  Helper functions
# ====================================================================
function Write-Banner {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
}

# Prompt for a yes/no decision.
#   -Force        -> always returns $true (bypass the gate)
#   non-interactive -> returns $false (caller decides whether to stop)
function Read-YesNo {
    param([string]$Prompt, [bool]$DefaultYes = $true)
    if ($Force) { return $true }
    if (-not [Environment]::UserInteractive) { return $false }
    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    try { $ans = Read-Host "$Prompt $suffix" -ErrorAction Stop }
    catch { return $DefaultYes }
    if ([string]::IsNullOrWhiteSpace($ans)) { return $DefaultYes }
    return ($ans -match '^\s*(y|yes)\s*$')
}

function Register-NmmProviders {
    param(
        [object[]]$Unregistered,
        [string[]]$AllProviders,
        [int]$TimeoutMinutes
    )
    Write-Host ("Registering {0} provider(s)..." -f $Unregistered.Count) -ForegroundColor Yellow
    foreach ($p in $Unregistered) {
        Write-Host ("  {0}: registering..." -f $p.Provider) -ForegroundColor Yellow
        az provider register --namespace $p.Provider --output none --only-show-errors
    }
    Write-Host ("Polling (timeout: {0}m)..." -f $TimeoutMinutes)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        Start-Sleep -Seconds 15
        $pending = [System.Collections.Generic.List[string]]::new()
        foreach ($ns in $AllProviders) {
            $state = az provider show --namespace $ns --query registrationState --output tsv --only-show-errors 2>$null
            if ($state -and $state -ne 'Registered') { $pending.Add("$ns ($state)") }
        }
        if ($pending.Count -gt 0) { Write-Host ("  Pending: {0}" -f ($pending -join ', ')) }
    } while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline)
    if ($pending.Count -gt 0) {
        Write-Warning "Some providers did not finish registering within the timeout."
        return $false
    }
    Write-Host 'All providers Registered.' -ForegroundColor Green
    return $true
}

function Get-SqlRegionStatus {
    param(
        [string]$Region, [string]$Sub,
        [string]$Edition, [string]$Slo, [string]$ApiVersion,
        [string]$ArmEndpoint = 'https://management.azure.com'
    )
    if (-not $Sub) {
        return [pscustomobject]@{ Region = $Region; Ok = $false; Reason = 'no subscription id resolved (internal error)' }
    }
    # Use az rest instead of Invoke-RestMethod so auth is handled internally by
    # the az CLI — avoids bearer token audience mismatches in sovereign clouds.
    $url = "$ArmEndpoint/subscriptions/$Sub/providers/Microsoft.Sql/locations/$Region/capabilities?api-version=$ApiVersion"
    try {
        $resp = az rest --method GET --url $url --only-show-errors 2>$null | ConvertFrom-Json -ErrorAction Stop
        if (-not $resp) {
            return [pscustomobject]@{ Region = $Region; Ok = $false; Reason = "SQL capabilities API returned no data" }
        }
        # An ARM error body (bad api-version, missing RP, empty subscription, etc.)
        # surfaces here in place of the capabilities object — report it verbatim.
        if ($resp.PSObject.Properties['error']) {
            $msg = ($resp.error.message -replace '\s+', ' ').Trim()
            return [pscustomobject]@{ Region = $Region; Ok = $false; Reason = "API error [$($resp.error.code)]: $msg" }
        }

        $serverVersions = @($resp.supportedServerVersions)
        if ($serverVersions.Count -eq 0) {
            # Self-diagnostic: if the schema is not what we expect, show the actual
            # top-level keys so the parser can be adapted without a separate run.
            $keys = ($resp.PSObject.Properties.Name | Sort-Object) -join ', '
            return [pscustomobject]@{ Region = $Region; Ok = $false; Reason = "no supportedServerVersions; response keys=[$keys]" }
        }

        # A capability is usable unless its status is explicitly 'Disabled'.
        $sloListed = $false
        foreach ($sv in $serverVersions) {
            foreach ($e in $sv.supportedEditions) {
                if ($e.name -ne $Edition) { continue }
                foreach ($o in $e.supportedServiceLevelObjectives) {
                    if ($o.name -eq $Slo -and $o.status -ne 'Disabled') { $sloListed = $true }
                }
            }
        }

        if ($sloListed) { return [pscustomobject]@{ Region = $Region; Ok = $true; Reason = '' } }

        # Not offered: list the editions that ARE available so a vCore fallback
        # (e.g. GeneralPurpose) can be chosen if Standard/S1 is absent in gov.
        $available = @($serverVersions | ForEach-Object { $_.supportedEditions } |
            Where-Object { $_.status -ne 'Disabled' } |
            Select-Object -ExpandProperty name -Unique) -join ', '
        $detail = if ($available) { "; editions available: $available" } else { '' }
        return [pscustomobject]@{ Region = $Region; Ok = $false; Reason = "$Edition/$Slo not offered in this region$detail" }
    } catch {
        return [pscustomobject]@{ Region = $Region; Ok = $false; Reason = "SQL capabilities error: $($_.Exception.Message)" }
    }
}

function New-StrongPassword {
    param([int]$Length = 20)
    $upper   = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.ToCharArray()
    $lower   = 'abcdefghijklmnopqrstuvwxyz'.ToCharArray()
    $digit   = '0123456789'.ToCharArray()
    $special = '!@#$%^&*'.ToCharArray()
    $all = $upper + $lower + $digit + $special
    $chars = @(
        (Get-Random -InputObject $upper),
        (Get-Random -InputObject $lower),
        (Get-Random -InputObject $digit),
        (Get-Random -InputObject $special)
    )
    $chars += 1..($Length - 4) | ForEach-Object { Get-Random -InputObject $all }
    -join ($chars | Sort-Object { Get-Random })
}

# Resolve a policy 'effect' that may be a literal ('deny') or parameterized
# ('[parameters('effect')]'). Best-effort: assignment param value wins, then
# the definition's parameter defaultValue.
function Resolve-PolicyEffect {
    param($RawEffect, $AssignmentParams, $DefinitionParams)
    if (-not $RawEffect) { return $null }
    $e = "$RawEffect"
    $m = [regex]::Match($e, "parameters\(\s*'([^']+)'\s*\)")
    if ($m.Success) {
        $pname = $m.Groups[1].Value
        if ($AssignmentParams -and $AssignmentParams.PSObject.Properties[$pname]) {
            return "$($AssignmentParams.$pname.value)"
        }
        if ($DefinitionParams -and $DefinitionParams.PSObject.Properties[$pname]) {
            return "$($DefinitionParams.$pname.defaultValue)"
        }
        return $null
    }
    return $e
}

# List policy assignments in subscription scope whose (resolved) effect is Deny.
# Best-effort for initiatives (member-parameter mapping is not fully resolved);
# -PolicyProbe is the ground-truth check. Uses 'az rest' (not Invoke-RestMethod)
# so auth is handled internally by the az CLI and works against the active
# cloud's ARM endpoint (commercial or Gov/GCC-H) without a separate token call.
function Get-DenyPolicyAssignments {
    param([string]$Sub, [string]$ArmEndpoint)
    $base   = $ArmEndpoint.TrimEnd('/')
    $denies = New-Object System.Collections.Generic.List[object]

    try {
        $auri = "$base/subscriptions/$Sub/providers/Microsoft.Authorization/policyAssignments?api-version=2022-06-01&`$filter=atScope()"
        $assignments = @()
        do {
            $r = az rest --method GET --url $auri --only-show-errors 2>$null | ConvertFrom-Json
            if (-not $r) { break }
            $assignments += $r.value
            $auri = $r.nextLink
        } while ($auri)
    } catch {
        return [pscustomobject]@{ Error = "Policy assignment query failed: $($_.Exception.Message)"; Denies = @() }
    }

    # Policy exemptions that apply to this subscription (atScope includes ancestors).
    # An assignment referenced by an exemption doesn't actually enforce here.
    $subScope    = "/subscriptions/$Sub"
    $exemptedIds = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    try {
        $exUri = "$base/subscriptions/$Sub/providers/Microsoft.Authorization/policyExemptions?api-version=2022-07-01-preview&`$filter=atScope()"
        do {
            $er = az rest --method GET --url $exUri --only-show-errors 2>$null | ConvertFrom-Json
            if (-not $er) { break }
            foreach ($ex in $er.value) {
                if ($ex.properties.policyAssignmentId) { [void]$exemptedIds.Add($ex.properties.policyAssignmentId) }
            }
            $exUri = $er.nextLink
        } while ($exUri)
    } catch {}

    foreach ($a in $assignments) {
        $defId = $a.properties.policyDefinitionId
        if (-not $defId) { continue }
        $assignParams = $a.properties.parameters

        # Skip assignments that do not actually apply to this subscription:
        #   1. enforcementMode = DoNotEnforce (reported/audited but not enforced)
        #   2. this subscription is excluded via notScopes
        #   3. a policy exemption covers this assignment
        if ($a.properties.enforcementMode -eq 'DoNotEnforce') { continue }
        $excluded = $false
        foreach ($ns in @($a.properties.notScopes)) {
            if ($ns -and ($ns -eq $subScope -or $subScope.StartsWith("$ns/", [System.StringComparison]::OrdinalIgnoreCase))) { $excluded = $true; break }
        }
        if ($excluded) { continue }
        if ($a.id -and $exemptedIds.Contains($a.id)) { continue }

        $def = az rest --method GET --url ("$base{0}?api-version=2021-06-01" -f $defId) --only-show-errors 2>$null | ConvertFrom-Json
        if (-not $def) { continue }

        $effects = New-Object System.Collections.Generic.List[string]
        if ($defId -match '/policySetDefinitions/') {
            foreach ($pd in $def.properties.policyDefinitions) {
                $mDef = az rest --method GET --url ("$base{0}?api-version=2021-06-01" -f $pd.policyDefinitionId) --only-show-errors 2>$null | ConvertFrom-Json
                if (-not $mDef) { continue }
                $eff = Resolve-PolicyEffect $mDef.properties.policyRule.then.effect $assignParams $mDef.properties.parameters
                if ($eff) { $effects.Add($eff) }
            }
        } else {
            $eff = Resolve-PolicyEffect $def.properties.policyRule.then.effect $assignParams $def.properties.parameters
            if ($eff) { $effects.Add($eff) }
        }

        if ($effects | Where-Object { $_ -match '^(?i)deny' }) {
            $name = $a.properties.displayName
            if (-not $name) { $name = $a.name }
            $denies.Add([pscustomobject]@{
                displayName        = $name
                policyAssignmentId = $a.id
                policyDefinitionId = $defId
                scope              = $a.properties.scope
                effect             = 'deny'
            })
        }
    }
    return [pscustomobject]@{ Error = $null; Denies = $denies.ToArray() }
}

# Ground-truth Deny check: deploy representative NMM resource types (storage,
# Key Vault, SQL server) into a throwaway RG via 'az deployment group create',
# then delete it. Captures any blocking policy IDs from the deployment error.
# Always cleans up. CLI-only (no Az PowerShell module) to match the rest of
# this script and avoid a new dependency in Gov/GCC-H environments.
function Invoke-PolicyProbe {
    param([string]$Location)
    $result   = [ordered]@{ ran = $true; blocked = $false; blockingPolicyIds = @(); error = $null }
    $probeRg  = "nmm-policyprobe-$(Get-Date -Format 'yyyyMMddHHmmss')"
    $probeTemplate = @'
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "sqlAdminPassword": { "type": "securestring" }
    },
    "variables": {
        "suffix":      "[uniqueString(resourceGroup().id)]",
        "storageName": "[toLower(concat('nmmprobe', variables('suffix')))]",
        "kvName":      "[toLower(concat('nmmprobe-', variables('suffix')))]",
        "sqlName":     "[toLower(concat('nmmprobe-sql-', variables('suffix')))]"
    },
    "resources": [
        {
            "type": "Microsoft.Storage/storageAccounts",
            "apiVersion": "2023-01-01",
            "name": "[variables('storageName')]",
            "location": "[resourceGroup().location]",
            "sku": { "name": "Standard_LRS" },
            "kind": "StorageV2",
            "properties": { "minimumTlsVersion": "TLS1_2", "allowBlobPublicAccess": false }
        },
        {
            "type": "Microsoft.KeyVault/vaults",
            "apiVersion": "2023-02-01",
            "name": "[variables('kvName')]",
            "location": "[resourceGroup().location]",
            "properties": {
                "tenantId": "[subscription().tenantId]",
                "sku": { "family": "A", "name": "standard" },
                "accessPolicies": [],
                "enableSoftDelete": true
            }
        },
        {
            "type": "Microsoft.Sql/servers",
            "apiVersion": "2022-05-01-preview",
            "name": "[variables('sqlName')]",
            "location": "[resourceGroup().location]",
            "properties": {
                "administratorLogin": "probeadmin",
                "administratorLoginPassword": "[parameters('sqlAdminPassword')]",
                "minimalTlsVersion": "1.2"
            }
        }
    ]
}
'@
    $tmpl = Join-Path ([System.IO.Path]::GetTempPath()) "nmm-policyprobe-$(Get-Random).json"
    try {
        $probeTemplate | Out-File -FilePath $tmpl -Encoding UTF8
        az group create --name $probeRg --location $Location --only-show-errors --output none 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Could not create probe resource group '$probeRg'." }

        $sqlPwd = New-StrongPassword -Length 24
        $deployErr = az deployment group create `
            --resource-group $probeRg `
            --template-file $tmpl `
            --parameters ("sqlAdminPassword={0}" -f $sqlPwd) `
            --only-show-errors 2>&1
        if ($LASTEXITCODE -ne 0) {
            $result.blocked = $true
            $text = ($deployErr | Out-String)
            $ids = [regex]::Matches($text, '/providers/Microsoft\.Authorization/policy(?:Assignments|Definitions)/[^\s"'',}]+') |
                ForEach-Object { $_.Value } | Select-Object -Unique
            $result.blockingPolicyIds = @($ids)
            Write-Host "  Policy probe BLOCKED: a policy denied one or more representative resources." -ForegroundColor Red
            if ($ids) {
                foreach ($id in $ids) { Write-Host ("    -> {0}" -f $id) -ForegroundColor Red }
            } else {
                Write-Host "    (Could not extract policy ID; raw error below)" -ForegroundColor DarkGray
                Write-Host "    $text" -ForegroundColor DarkGray
            }
        } else {
            Write-Host "  Policy probe PASSED: representative resources are allowed by policy." -ForegroundColor Green
        }
    } catch {
        $result.error = "Probe setup failed: $($_.Exception.Message)"
        Write-Warning $result.error
    } finally {
        Write-Host "  Cleaning up probe resource group '$probeRg' (waiting for delete)..." -ForegroundColor DarkGray
        az group delete --name $probeRg --yes --only-show-errors --output none 2>$null
        if ($tmpl -and (Test-Path $tmpl)) { Remove-Item $tmpl -ErrorAction SilentlyContinue }
    }
    return $result
}

function Resolve-Geography {
    param([string]$Token)
    switch -Regex (($Token -replace '\s', '').ToLower()) {
        '^(us|usa|unitedstates)$'              { return @('US') }
        '^canada$'                             { return @('Canada') }
        '^(northamerica|na)$'                  { return @('US','Canada','Mexico') }
        '^(europe|eu)$'                        { return @('Europe','UK') }
        '^(uk|unitedkingdom)$'                 { return @('UK') }
        '^(asiapacific|apac|asia)$'            { return @('Asia Pacific') }
        '^(middleeast|me)$'                    { return @('Middle East') }
        '^africa$'                             { return @('Africa') }
        '^(southamerica|latam|latinamerica)$'  { return @('South America') }
        '^(mexico|mx)$'                        { return @('Mexico') }
        '^all$'                                { return $null }
        default { throw "Unrecognized -Geography '$Token'." }
    }
}

$geoMenu = [ordered]@{
    'United States'                        = @('US')
    'Canada'                               = @('Canada')
    'North America (US + Canada + Mexico)' = @('US','Canada','Mexico')
    'Europe (incl. UK)'                    = @('Europe','UK')
    'United Kingdom'                       = @('UK')
    'Asia Pacific'                         = @('Asia Pacific')
    'Middle East'                          = @('Middle East')
    'Africa'                               = @('Africa')
    'South America'                        = @('South America')
    'All regions'                          = $null
}

function Show-GeographyPrompt {
    Write-Host ''
    Write-Host "Filter by region geography? (For GCC-H, choose 'United States' or 'All regions'.)" -ForegroundColor Cyan
    $labels = @($geoMenu.Keys)
    for ($n = 0; $n -lt $labels.Count; $n++) {
        Write-Host ("  {0,2}. {1}" -f ($n + 1), $labels[$n])
    }
    try { $pick = Read-Host "Enter choice [1]" -ErrorAction Stop }
    catch { return $null }
    if ([string]::IsNullOrWhiteSpace($pick)) { $pick = '1' }
    $idx = 0
    if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $labels.Count) {
        Write-Host "Invalid choice; defaulting to United States." -ForegroundColor Yellow
        $idx = 1
    }
    return $geoMenu[$labels[$idx - 1]]
}

# ====================================================================
#  Pre-flight (az auth + cloud endpoint detection)
# ====================================================================
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI ('az') not found. Run in Cloud Shell or install the Azure CLI."
}
if ($SubscriptionId) { az account set --subscription $SubscriptionId --only-show-errors | Out-Null }

$ctx = az account show --only-show-errors 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not logged in. Run 'az login' first (or 'az cloud set --name AzureUSGovernment && az login' for GCC-H)." }
$subId = $ctx.id   # used by the Phase 2 SQL capability calls

# Read API base URLs from the active cloud configuration so this script works
# correctly for both commercial Azure and Azure Government without hardcoding.
$cloudInfo     = az cloud show --only-show-errors 2>$null | ConvertFrom-Json
$armEndpoint   = $cloudInfo.endpoints.resourceManager.TrimEnd('/')
$graphEndpoint = $cloudInfo.endpoints.microsoftGraphResourceId.TrimEnd('/')
$cloudName     = $cloudInfo.name


Write-Banner "Nerdio Manager for MSP (NMM) - Pre-Install Readiness Check"
Write-Host ("Subscription  : {0}" -f $ctx.name)
Write-Host ("Sub ID        : {0}" -f $ctx.id)
Write-Host ("Cloud         : {0}" -f $cloudName)
Write-Host ("ARM endpoint  : {0}" -f $armEndpoint)
Write-Host ("Checking for  : App Service '{0}'  +  Azure SQL '{1}/{2}'" -f $AppServiceSku, $SqlEdition, $SqlServiceObjective)
if ($Force) { Write-Host "-Force         : readiness gates will be bypassed." -ForegroundColor DarkYellow }

if ($cloudName -eq 'AzureCloud') {
    Write-Host ''
    Write-Host "  NOTE: Active cloud is AzureCloud (commercial). To target GCC-H, run:" -ForegroundColor DarkYellow
    Write-Host "        az cloud set --name AzureUSGovernment && az login" -ForegroundColor DarkYellow
}
Write-Host ''

# ====================================================================
#  Phase 0: Permission check
# ====================================================================
Write-Banner "Phase 0: Permission Check"
$me = az ad signed-in-user show --only-show-errors 2>$null | ConvertFrom-Json
if (-not $me) {
    Write-Warning "Could not retrieve signed-in user info -- permission check skipped."
} else {
    Write-Host ("Signed-in user : {0}  ({1})" -f $me.displayName, $me.userPrincipalName)
    Write-Host ''
    $ownerAssignments = az role assignment list `
        --assignee $me.id --role Owner --scope "/subscriptions/$($ctx.id)" `
        --include-groups --include-inherited --only-show-errors 2>$null | ConvertFrom-Json
    $isOwner = ($null -ne $ownerAssignments -and @($ownerAssignments).Count -gt 0)

    $isGA = $null; $gaNote = ''
    try {
        $GA_TEMPLATE_ID = '62e90394-69f5-4237-9190-012177145e10'
        # Use the graph endpoint for the active cloud (graph.microsoft.us for GCC-H,
        # graph.microsoft.com for commercial).
        $dirRoles = az rest --method GET `
            --url "$graphEndpoint/v1.0/me/transitiveMemberOf/microsoft.graph.directoryRole" `
            --only-show-errors 2>$null | ConvertFrom-Json
        if ($dirRoles -and $dirRoles.PSObject.Properties['value']) {
            $isGA = [bool]($dirRoles.value | Where-Object { $_.roleTemplateId -eq $GA_TEMPLATE_ID })
        } else { $gaNote = ' (no directory roles returned)' }
    } catch { $gaNote = ' (Graph API check failed)' }

    $ownerLabel = if ($isOwner) { 'PASS' } else { 'FAIL' }
    $gaLabel    = if ($null -eq $isGA) { "UNKNOWN$gaNote" } elseif ($isGA) { 'PASS' } else { 'FAIL' }
    $ownerColor = if ($isOwner) { 'Green' } else { 'Red' }
    $gaColor    = if ($null -eq $isGA) { 'Yellow' } elseif ($isGA) { 'Green' } else { 'Red' }
    "{0,-55} {1}" -f "  Subscription Owner", $ownerLabel | Write-Host -ForegroundColor $ownerColor
    "{0,-55} {1}" -f "  Entra ID Global Administrator", $gaLabel | Write-Host -ForegroundColor $gaColor
    Write-Host ''

    if ((-not $isOwner) -or ($isGA -eq $false)) {
        Write-Host '  ACTION REQUIRED: Missing permissions will cause the NMM install to fail.' -ForegroundColor Red
        if (-not $isOwner)    { Write-Host ("  -> Assign Owner on subscription '{0}'." -f $ctx.name) -ForegroundColor Red }
        if ($isGA -eq $false) { Write-Host '  -> Assign Global Administrator in Entra ID.' -ForegroundColor Red }
        Write-Host ''
        if ($Force) {
            Write-Host '  -Force specified; continuing despite missing permissions.' -ForegroundColor DarkYellow
        } elseif (-not [Environment]::UserInteractive) {
            throw "Missing required permissions (Owner / Global Administrator). Resolve and re-run, or pass -Force to override."
        } elseif (-not (Read-YesNo -Prompt "  Continue anyway? (the install will very likely fail)" -DefaultYes $false)) {
            throw "Aborted: required permissions are not satisfied."
        }
    } else {
        Write-Host '  All required permissions confirmed.' -ForegroundColor Green
    }
}

# ====================================================================
#  Phase 1: Resource provider registration
# ====================================================================
Write-Banner "Phase 1: Resource Provider Registration"
$providerResults = [System.Collections.Generic.List[object]]::new()
foreach ($ns in $NmmRequiredProviders) {
    $state = az provider show --namespace $ns --query registrationState --output tsv --only-show-errors 2>$null
    if (-not $state) { $state = 'UNKNOWN' }
    $providerResults.Add([pscustomobject]@{ Provider = $ns; State = $state })
}
$providerResults | Format-Table -AutoSize | Out-Host

$unregistered = @($providerResults | Where-Object { $_.State -ne 'Registered' })
if ($unregistered.Count -eq 0) {
    Write-Host 'All required providers are Registered.' -ForegroundColor Green
} else {
    Write-Host ("{0} required provider(s) are NOT registered. The NMM install will fail without them." -f $unregistered.Count) -ForegroundColor Yellow

    $doRegister = $false
    if ($RegisterProviders -or $Force) {
        $doRegister = $true
    } elseif (-not [Environment]::UserInteractive) {
        throw ("{0} required provider(s) not registered. Re-run with -RegisterProviders." -f $unregistered.Count)
    } else {
        $doRegister = Read-YesNo -Prompt "Register them now?" -DefaultYes $true
    }

    if ($doRegister) {
        $ok = Register-NmmProviders -Unregistered $unregistered -AllProviders $NmmRequiredProviders -TimeoutMinutes $ProviderTimeoutMinutes
        if (-not $ok -and -not $Force) {
            throw "Provider registration did not complete within the timeout. Resolve before deploying, or re-run with -Force to override."
        }
    } else {
        throw "Required providers are not registered. Aborting. Re-run with -RegisterProviders once resolved."
    }
}

# ====================================================================
#  Phase 2: Region eligibility
# ====================================================================
Write-Banner "Phase 2: Region Eligibility"
Write-Host "Loading Azure region list..." -ForegroundColor DarkGray
$allLocations = az account list-locations --only-show-errors 2>$null | ConvertFrom-Json
$physical     = $allLocations | Where-Object { $_.metadata.regionType -eq 'Physical' }

$nameToSlug = @{}; $slugToName = @{}; $slugToGeo = @{}
foreach ($loc in $physical) {
    $nameToSlug[$loc.displayName] = $loc.name
    $slugToName[$loc.name]        = $loc.displayName
    $slugToGeo[$loc.name]         = $loc.metadata.geographyGroup
}

Write-Host ("Querying App Service regions that offer '{0}'..." -f $AppServiceSku) -ForegroundColor DarkGray
$appSvcRaw   = az appservice list-locations --sku $AppServiceSku --only-show-errors 2>$null | ConvertFrom-Json
$appSvcSlugs = [System.Collections.Generic.HashSet[string]]::new()
foreach ($r in $appSvcRaw) {
    $slug = if ($nameToSlug.ContainsKey($r.name)) { $nameToSlug[$r.name] } else { ($r.name -replace '\s','').ToLower() }
    [void]$appSvcSlugs.Add($slug)
}
Write-Host ("  -> {0} regions offer App Service {1}." -f $appSvcSlugs.Count, $AppServiceSku) -ForegroundColor DarkGray

if ($Regions) {
    $candidates = $Regions | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ }
} else {
    $geoGroups = $null
    $geoLabel  = 'All regions'
    if ($Geography) {
        $geoGroups = Resolve-Geography $Geography
        $geoLabel  = $Geography
    } elseif ([Environment]::UserInteractive) {
        $geoGroups = Show-GeographyPrompt
        $geoLabel  = if ($null -eq $geoGroups) { 'All regions' } else { ($geoGroups -join ', ') }
    }
    $candidates = @($appSvcSlugs)
    if ($null -ne $geoGroups) {
        $candidates = $candidates | Where-Object { $geoGroups -contains $slugToGeo[$_] }
    }
    $candidates = $candidates | Sort-Object
    Write-Host ("Checking {0} region(s) in '{1}'..." -f $candidates.Count, $geoLabel) -ForegroundColor DarkGray
}

if (-not $candidates -or @($candidates).Count -eq 0) {
    Write-Host "No candidate regions to check." -ForegroundColor Yellow
    return
}

$apiVersion  = '2021-11-01'
$candidates  = @($candidates)
$useParallel = ($PSVersionTable.PSVersion.Major -ge 7) -and ($candidates.Count -gt 3)

if ($useParallel) {
    $funcDef = ${function:Get-SqlRegionStatus}.ToString()
    $sqlResults = $candidates | ForEach-Object -Parallel {
        ${function:Get-SqlRegionStatus} = $using:funcDef
        Get-SqlRegionStatus -Region $_ -Sub $using:subId `
            -Edition $using:SqlEdition -Slo $using:SqlServiceObjective `
            -ApiVersion $using:apiVersion -ArmEndpoint $using:armEndpoint
    } -ThrottleLimit 15
} else {
    $sqlResults = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($slug in $candidates) {
        $i++
        Write-Progress -Activity "Checking SQL availability" -Status $slug -PercentComplete ([int](($i / $candidates.Count) * 100))
        $sqlResults.Add( (Get-SqlRegionStatus -Region $slug -Sub $subId `
            -Edition $SqlEdition -Slo $SqlServiceObjective -ApiVersion $apiVersion `
            -ArmEndpoint $armEndpoint) )
    }
    Write-Progress -Activity "Checking SQL availability" -Completed
}

$sqlByRegion = @{}
foreach ($s in $sqlResults) { $sqlByRegion[$s.Region] = $s }

$results = New-Object System.Collections.Generic.List[object]
foreach ($slug in $candidates) {
    $appOk   = $appSvcSlugs.Contains($slug)
    $sql     = $sqlByRegion[$slug]
    $sqlOk   = [bool]($sql -and $sql.Ok)
    $display = if ($slugToName.ContainsKey($slug)) { $slugToName[$slug] } else { $slug }
    $results.Add([pscustomobject]@{
        Region           = $slug
        DisplayName      = $display
        AppService       = if ($appOk) { 'Yes' } else { 'No' }
        SqlDb            = if ($sqlOk) { 'Yes' } else { 'No' }
        Eligible         = if ($appOk -and $sqlOk) { 'YES' } else { 'no' }
        SqlReason        = if ($sqlOk) { '' } else { if ($sql) { $sql.Reason } else { 'no SQL result' } }
        AppServiceReason = if ($appOk) { '' } else { "App Service $AppServiceSku not offered" }
    })
}

$sorted   = $results | Sort-Object @{E={$_.Eligible -eq 'YES'};Descending=$true}, DisplayName
$eligible = @($sorted | Where-Object { $_.Eligible -eq 'YES' })

Write-Banner "Results"
$sorted | Format-Table Region, DisplayName, AppService, SqlDb, Eligible -AutoSize | Out-Host

if ($OutFile) {
    $sorted | Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8
    Write-Host ("Results CSV: {0}" -f $OutFile) -ForegroundColor Cyan
}

$excluded = @($sorted | Where-Object { $_.Eligible -ne 'YES' -and ($_.SqlReason -or $_.AppServiceReason) })
if ($excluded.Count -gt 0) {
    Write-Host "Why these regions were excluded:" -ForegroundColor DarkGray
    foreach ($r in $excluded) {
        $reason = @($r.SqlReason, $r.AppServiceReason) | Where-Object { $_ } | Select-Object -First 1
        Write-Host ("  {0,-20} {1}" -f $r.Region, $reason) -ForegroundColor DarkGray
    }
    Write-Host ''
}

# ====================================================================
#  Summary: Eligible regions for NMM deployment
# ====================================================================
Write-Banner "Eligible Regions for NMM Deployment"
if ($eligible.Count -eq 0) {
    Write-Host ("No region offers BOTH App Service {0} and SQL {1}/{2} in this subscription." -f $AppServiceSku, $SqlEdition, $SqlServiceObjective) -ForegroundColor Red
    Write-Host ''
    Write-Host "Next steps:" -ForegroundColor Yellow
    Write-Host "  1. Open a support request (Help + Support -> New Support Request) to unlock" -ForegroundColor Yellow
    Write-Host "     SQL provisioning in your preferred region (quota requests are free on any plan)." -ForegroundColor Yellow
    Write-Host "  2. Re-run this script after the unlock is confirmed." -ForegroundColor Yellow
} else {
    Write-Host ("The following {0} region(s) support NMM deployment:" -f $eligible.Count) -ForegroundColor Green
    Write-Host ("  (App Service {0} + Azure SQL {1}/{2} both available)" -f $AppServiceSku, $SqlEdition, $SqlServiceObjective) -ForegroundColor DarkGray
    Write-Host ''
    for ($i = 0; $i -lt $eligible.Count; $i++) {
        Write-Host ("  {0,2}. {1,-35}  slug: {2}" -f ($i + 1), $eligible[$i].DisplayName, $eligible[$i].Region) -ForegroundColor Green
    }
    Write-Host ''
    Write-Host "Use the 'slug' value as the deployment region when running the NMM install." -ForegroundColor Cyan
    Write-Host ''
    Write-Host "IMPORTANT: This check confirms SKU availability for this subscription, not quota" -ForegroundColor DarkYellow
    Write-Host "headroom. The deployment may still fail if vCPU or App Service quotas are exhausted." -ForegroundColor DarkYellow
}

# ====================================================================
#  Phase 3: Policy Deny Check (read-only, always runs; -PolicyProbe is opt-in)
# ====================================================================
Write-Banner "Phase 3: Policy Deny Check"
Write-Host "Querying policy assignments in subscription scope for Deny effects..." -ForegroundColor DarkGray
$denyResult = Get-DenyPolicyAssignments -Sub $subId -ArmEndpoint $armEndpoint
if ($denyResult.Error) {
    Write-Warning $denyResult.Error
} elseif (@($denyResult.Denies).Count -eq 0) {
    Write-Host "No enforced Deny policy assignments found in this hierarchy." -ForegroundColor Green
} else {
    Write-Host ("ADVISORY: {0} Deny policy assignment(s) exist in this subscription's management hierarchy." -f @($denyResult.Denies).Count) -ForegroundColor Yellow
    $denyResult.Denies | Format-Table displayName, policyDefinitionId -AutoSize | Out-Host
    Write-Host "  These MAY affect deployment, but not necessarily. Whether a deny actually blocks NMM" -ForegroundColor DarkGray
    Write-Host "  depends on resource selectors, overrides, and resource type -- which cannot be" -ForegroundColor DarkGray
    Write-Host "  determined by listing alone. (Microsoft-managed region/SDP gating policies commonly" -ForegroundColor DarkGray
    Write-Host "  appear here and usually do NOT block.) Use -PolicyProbe for the ground-truth check." -ForegroundColor DarkGray
}

if ($PolicyProbe) {
    if ($eligible.Count -eq 0) {
        Write-Host ''
        Write-Host "Skipping policy probe: no eligible region was found in Phase 2." -ForegroundColor Yellow
    } else {
        $probeRegion = $eligible[0].Region
        Write-Banner "Policy Probe (create/delete test)"
        Write-Host ("Probing region '{0}' (first eligible; pass -Regions to target another)..." -f $probeRegion) -ForegroundColor Cyan
        [void](Invoke-PolicyProbe -Location $probeRegion)
    }
}
