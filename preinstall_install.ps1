#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$ResourceGroupName,
    [string]$AppServiceSku       = 'B2',
    [int]$AppServiceInstances    = 1,
    [string]$SqlEdition          = 'Standard',
    [string]$SqlServiceObjective = 'S1',
    [string[]]$Regions,
    [string]$Geography,
    [string]$SubscriptionId,
    [string]$OutFile,
    [string]$JsonOut,
    [switch]$PolicyProbe,
    [switch]$RegisterProviders,
    [int]$ProviderTimeoutMinutes = 15,
    [string]$NmmVersion          = '6.8.0',
    [switch]$CheckOnly,
    [switch]$Force
)

$ErrorActionPreference = 'Continue'

# ====================================================================
#  Machine-readable report (emitted to -JsonOut). Populated per-phase so
#  results -- including any blocking policy IDs -- flow into tickets/automation.
# ====================================================================
$script:report = [ordered]@{
    timestamp        = (Get-Date -Format 'o')
    nmmVersion       = $NmmVersion
    checkOnly        = [bool]$CheckOnly
    subscriptionId   = $null
    subscriptionName = $null
    signedInUser     = $null
    resourceGroup    = [ordered]@{ name = $null; valid = $null; exists = $null; softDeletedVaults = @(); purged = $false }
    permissions      = [ordered]@{
        owner = $null; globalAdmin = $null
        ownerHolding = $null; globalAdminHolding = $null   # Standing | PIM | Unknown
        pimWarnings  = @()
    }
    providers        = @()
    regions          = @()
    selectedRegion   = $null
    quotaRequest     = [ordered]@{ requested = $false; sku = $null; region = $null; fromLimit = $null; toLimit = $null; ok = $null; message = $null }
    policy           = [ordered]@{
        denyAssignments = @()
        probe           = [ordered]@{ ran = $false; blocked = $null; blockingPolicyIds = @() }
    }
    deployment       = [ordered]@{ name = $null; provisioningState = $null; webAppUrl = $null }
}

function Save-Report {
    if (-not $JsonOut) { return }
    try {
        $script:report | ConvertTo-Json -Depth 8 | Out-File -FilePath $JsonOut -Encoding UTF8
    } catch {
        Write-Warning ("Could not write JSON report to {0}: {1}" -f $JsonOut, $_.Exception.Message)
    }
}

# Flush the report on any terminating error (e.g. a gating throw), then rethrow.
trap { Save-Report; break }

# The NMM post-install configuration script only runs in Azure Cloud Shell, and
# the readiness results only matter from the partner's own tenant, so the whole
# script is Cloud Shell-only.
$inCloudShell = $env:ACC_CLOUD -or
                ($env:AZUREPS_HOST_ENVIRONMENT -like 'cloud-shell*') -or
                ($env:POWERSHELL_DISTRIBUTION_CHANNEL -like 'CloudShell*')
if (-not $inCloudShell) {
    throw "This script must be run in Azure Cloud Shell (PowerShell). Open https://shell.azure.com and run it there."
}

# -CheckOnly runs the read-only readiness phases and stops before any change to
# the subscription. Outside CheckOnly mode a resource group name is required for
# the Phase 4 deploy; fail fast now rather than after the checks.
if (-not $CheckOnly -and [string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    throw "ResourceGroupName is required to deploy. Pass -ResourceGroupName <name>, or run with -CheckOnly to only run the readiness checks."
}
if ($AppServiceInstances -lt 1) { $AppServiceInstances = 1 }

$NmmRequiredProviders = @(
    'Microsoft.KeyVault','Microsoft.Compute','Microsoft.Automation','Microsoft.Storage',
    'Microsoft.Insights','Microsoft.OperationalInsights','Microsoft.DesktopVirtualization',
    'Microsoft.Network','Microsoft.AAD','Microsoft.RecoveryServices','Microsoft.Web',
    'Microsoft.Quota','Microsoft.Solutions','Microsoft.Sql','Microsoft.MarketplaceOrdering'
)

$GA_TEMPLATE_ID    = '62e90394-69f5-4237-9190-012177145e10'   # Entra ID Global Administrator
$OWNER_ROLE_ID     = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'   # Azure built-in Owner
$PimSettleMinutes  = 10    # time to allow a fresh PIM activation to propagate into Azure RBAC
$DeployWindowMins  = 75    # an NMM deploy + post-install takes ~45-60 min; warn if a role expires sooner

# ====================================================================
#  NMM deployment template (inline)
# ====================================================================
# Embedded so the script is a single self-contained file -- works with a
# Cloud Shell curl-pipe / one-liner and from any working directory (no
# companion template.json to ship). 'packageVersion' is a template parameter
# fed from -NmmVersion at deploy time, so the version stays single-sourced and
# cannot drift. Single-quoted here-string: no PowerShell interpolation of the
# ARM '$schema' / "[...]" expressions.
$nmmTemplateJson = @'
{
    "$schema": "https://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "sqlServerLogin": {
            "type": "string",
            "defaultValue": "sqladmin",
            "metadata": {
                "description": "SQL Server administrator login name"
            }
        },
        "sqlServerPassword": {
            "type": "securestring",
            "minLength": 8,
            "maxLength": 128,
            "metadata": {
                "description": "SQL Server administrator password. Must be 8-128 characters and contain at least: uppercase letters (A-Z), lowercase letters (a-z), digits (0-9), and special characters (!@#$%^&*)."
            }
        },
        "applicationResourceName": {
            "type": "string",
            "defaultValue": "nerdioMspApp"
        },
        "packageVersion": {
            "type": "string",
            "defaultValue": "6.8.0",
            "metadata": {
                "description": "NMM marketplace package version to deploy. Fed from the script's -NmmVersion parameter so the install and the post-install configuration script target the same version."
            }
        }
    },
    "variables": {},
    "resources": [
        {
            "type": "Microsoft.Solutions/applications",
            "apiVersion": "2021-07-01",
            "location": "[resourceGroup().Location]",
            "kind": "MarketPlace",
            "name": "[parameters('applicationResourceName')]",
            "plan": {
                "name": "nmm-plan",
                "product": "nmm",
                "publisher": "nerdio",
                "version": "[parameters('packageVersion')]"
            },
            "properties": {
                "managedResourceGroupId": "[concat(subscription().id,'/resourceGroups/',take(concat(resourceGroup().name,'-',uniquestring(resourceGroup().id),uniquestring(parameters('applicationResourceName'))),90))]",
                "parameters": {
                    "location": {
                        "value": "[resourceGroup().location]"
                    },
                    "sqlServerLogin": {
                        "value": "[parameters('sqlServerLogin')]"
                    },
                    "sqlServerPassword": {
                        "value": "[parameters('sqlServerPassword')]"
                    }
                },
                "jitAccessPolicy": null
            }
        }
    ]
}
'@

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

function New-StrongPassword {
    param([int]$Length = 20)
    $sets  = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz', '0123456789', '!@#$%^&*'
    $all   = -join $sets
    $rng   = [System.Security.Cryptography.RandomNumberGenerator]
    $chars = [System.Collections.Generic.List[char]]::new()
    foreach ($s in $sets) { $chars.Add($s[$rng::GetInt32($s.Length)]) }
    while ($chars.Count -lt $Length) { $chars.Add($all[$rng::GetInt32($all.Length)]) }
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = $rng::GetInt32($i + 1)
        $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
    }
    -join $chars
}

function Invoke-ArmGet {
    # GET against ARM with retry on throttling (429), server errors (5xx) and dropped connections
    param([string]$Uri, [string]$Token, [int]$MaxAttempts = 4)
    for ($attempt = 1; ; $attempt++) {
        try {
            return Invoke-RestMethod -Method GET -Uri $Uri -Headers @{ Authorization = "Bearer $Token" } -ErrorAction Stop
        } catch {
            $status    = [int]$_.Exception.Response.StatusCode
            $retryable = ($status -eq 0) -or ($status -eq 429) -or ($status -ge 500)
            if (-not $retryable -or $attempt -ge $MaxAttempts) { throw }
            $wait = [Math]::Pow(2, $attempt)
            $retryAfter = $_.Exception.Response.Headers.RetryAfter.Delta
            if ($retryAfter) { $wait = [Math]::Min(60, $retryAfter.TotalSeconds) }
            Start-Sleep -Seconds ([int][Math]::Ceiling($wait))
        }
    }
}

function Get-ProviderStates {
    $map  = @{}
    $list = az provider list --query "[].{ns:namespace, state:registrationState}" -o json --only-show-errors 2>$null | ConvertFrom-Json
    foreach ($p in $list) { $map[$p.ns] = $p.state }
    return $map
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
        $states  = Get-ProviderStates
        $pending = @($AllProviders | Where-Object { $states[$_] -and $states[$_] -ne 'Registered' } |
            ForEach-Object { "$_ ($($states[$_]))" })
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
        [string]$Region, [string]$Sub, [string]$Token, [string]$ArmBase,
        [string]$Edition, [string]$Slo, [string]$ApiVersion
    )
    $uri = "$($ArmBase.TrimEnd('/'))/subscriptions/$Sub/providers/Microsoft.Sql/locations/$Region/capabilities?api-version=$ApiVersion&include=supportedEditions"
    try {
        $resp = Invoke-ArmGet -Uri $uri -Token $Token
        $reason = $resp.supportedServerVersions.reason | Where-Object { $_ } | Select-Object -First 1
        if ($reason) { $reason = ($reason -replace '\s+', ' ').Trim() }

        $sloListed = $false
        foreach ($sv in $resp.supportedServerVersions) {
            foreach ($e in $sv.supportedEditions) {
                if ($e.name -eq $Edition) {
                    foreach ($o in $e.supportedServiceLevelObjectives) {
                        if ($o.name -eq $Slo) { $sloListed = $true }
                    }
                }
            }
        }

        if ($reason)       { return [pscustomobject]@{ Region = $Region; Ok = $false; Reason = $reason } }
        elseif ($sloListed){ return [pscustomobject]@{ Region = $Region; Ok = $true;  Reason = '' } }
        else               { return [pscustomobject]@{ Region = $Region; Ok = $false; Reason = "$Edition/$Slo is not offered in this region" } }
    } catch {
        return [pscustomobject]@{ Region = $Region; Ok = $false; Reason = "SQL capabilities API error: $($_.Exception.Message)" }
    }
}

function Get-AppServiceQuotaStatus {
    param(
        [string]$Region, [string]$Sub, [string]$Token, [string]$ArmBase,
        [string]$Sku = 'B2',            # e.g. B1, B2, S1, P0v4, P1v3
        [int]$Required = 1,             # instances the deployment needs
        [string]$ApiVersion = '2025-03-01'
    )
    if ($Required -lt 1) { $Required = 1 }   # never allow a 0-instance check to pass a 0 limit
    $scope = "$($ArmBase.TrimEnd('/'))/subscriptions/$Sub/providers/Microsoft.Web/locations/$Region/providers/Microsoft.Quota"

    $out = [pscustomobject]@{
        Region = $Region; Ok = $false; Reason = ''
        SkuUsed = $null; SkuLimit = $null; TotalUsed = $null; TotalLimit = $null
        SkuRowName = ''; SkuRowCount = 0
        NeedsQuota = $false   # quota row exists but limit is too low -> fixable with a quota increase
    }

    # Follows nextLink so large result sets aren't truncated
    function Get-All([string]$uri) {
        $items = @()
        while ($uri) {
            $r = Invoke-ArmGet -Uri $uri -Token $Token
            $items += @($r.value)
            $uri = $r.nextLink
        }
        return ,$items
    }

    # Returns ALL rows matching the API name or the portal display name ("B2 VMs")
    function Find-Rows($rows, [string]$pattern) {
        @($rows | Where-Object {
            $_.properties.name.value -match $pattern -or $_.properties.name.localizedValue -match $pattern
        })
    }

    try {
        $quotas = Get-All "$scope/quotas?api-version=$ApiVersion"
        $usages = Get-All "$scope/usages?api-version=$ApiVersion"
    } catch {
        $code = $null
        try { $code = ($_.ErrorDetails.Message | ConvertFrom-Json).error.code } catch {}
        $msg = if ($code) { "$code - $($_.Exception.Message)" } else { $_.Exception.Message }
        $out.Reason = "Quota API error: $msg"
        return $out
    }

    if (@($quotas).Count -eq 0) {
        $out.Reason = "No App Service quota data returned for this subscription/region"
        return $out
    }

    $checks = @(
        @{ Key = 'Sku';   Label = "$Sku VMs";           Pattern = "^$([regex]::Escape($Sku))(\s*VMs)?$" },
        @{ Key = 'Total'; Label = 'Total Regional VMs'; Pattern = 'Total\s*Regional' }
    )

    foreach ($chk in $checks) {
        $qHits = Find-Rows $quotas $chk.Pattern
        if ($chk.Key -eq 'Sku') {
            $out.SkuRowCount = $qHits.Count
            $out.SkuRowName  = (@($qHits | ForEach-Object { $_.properties.name.value }) -join ',')
        }
        if ($qHits.Count -eq 0) {
            # Total Regional VMs is informational; a missing row is not a blocker
            if ($chk.Key -eq 'Total') { continue }
            # Total Regional VMs can be listed while the SKU row is missing -> effective SKU limit is 0
            $out.Reason = "No '$($chk.Label)' quota row in this subscription/region (effective limit 0; request via support)"
            return $out
        }

        # Fail closed: a missing limit counts as 0, and with several matching rows use the smallest limit
        $limits = @($qHits | ForEach-Object {
            $v = $_.properties.limit.value
            if ($null -eq $v -or "$v" -eq '') { 0 } else { [int]$v }
        })
        $limit = ($limits | Measure-Object -Minimum).Minimum

        $uHits = Find-Rows $usages $chk.Pattern
        $used  = if ($uHits.Count -gt 0) {
            # The usages API reports -1 when there is no usage to report (seen on 0-limit SKUs), so clamp to 0
            ($uHits | ForEach-Object { $v = $_.properties.usages.value; if ($null -eq $v) { 0 } else { [Math]::Max(0, [int]$v) } } |
                Measure-Object -Maximum).Maximum
        } else { 0 }

        if ($chk.Key -eq 'Sku') { $out.SkuUsed = $used;   $out.SkuLimit = $limit }
        else                    { $out.TotalUsed = $used; $out.TotalLimit = $limit }

        # Total Regional VMs is informational: Azure shows it as 0/0 in regions where it isn't populated
        # (e.g. West US with B2 0/31), and it rises automatically when SKU quota is granted. Only treat it
        # as a blocker when it has a real limit that is exhausted; raising the SKU quota fixes that case too.
        if ($chk.Key -eq 'Total' -and $limit -eq 0) { continue }

        if ($limit -lt $Required -or ($limit - $used) -lt $Required) {
            $out.Reason     = "$($chk.Label): $used of $limit used, need $Required free (quota increase needed)"
            $out.NeedsQuota = $true
            return $out
        }
    }

    $out.Ok = $true
    return $out
}

function Request-AppServiceQuotaIncrease {
    # Raises the App Service SKU quota in one region through the Microsoft.Quota API.
    # Uses Invoke-AzRestMethod (signed-in Az PowerShell context) because it exposes the 202
    # response headers needed to track the async operation.
    param(
        [string]$Region, [string]$Sub, [string]$Sku,
        [int]$NewLimit,
        [string]$ApiVersion = '2025-03-01',
        [int]$TimeoutMinutes = 10
    )
    $terminal = 'Succeeded','Failed','Invalid','Cancelled','Canceled'
    $path     = "/subscriptions/$Sub/providers/Microsoft.Web/locations/$Region/providers/Microsoft.Quota/quotas/$Sku`?api-version=$ApiVersion"

    if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ Ok = $false; Limit = $null; Message = "No Az PowerShell context. Run Connect-AzAccount and retry." }
    }

    $body = @{
        properties = @{
            limit = @{ limitObjectType = 'LimitValue'; value = $NewLimit }
            name  = @{ value = $Sku }
        }
    } | ConvertTo-Json -Depth 5

    # 1. Submit the request
    try {
        $put = Invoke-AzRestMethod -Method PUT -Path $path -Payload $body -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ Ok = $false; Limit = $null; Message = "Quota request call failed: $($_.Exception.Message)" }
    }
    Write-Host ("    PUT status: {0}" -f $put.StatusCode)

    if ($put.StatusCode -notin 200, 201, 202) {
        return [pscustomobject]@{ Ok = $false; Limit = $null; Message = "Quota request rejected (HTTP $($put.StatusCode)): $($put.Content)" }
    }

    # 2. Poll the async operation until it reaches a terminal state
    $opState = 'Succeeded'; $opError = ''
    if ($put.StatusCode -eq 202) {
        $statusUrl = $null
        foreach ($h in 'Location', 'Azure-AsyncOperation') {
            if (-not $statusUrl) { try { $statusUrl = @($put.Headers.GetValues($h))[0] } catch {} }
        }
        if (-not $statusUrl) {
            $opState = 'Unknown'; $opError = 'Azure returned 202 without a status URL'
        } else {
            $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
            do {
                Start-Sleep -Seconds 10
                $poll    = Invoke-AzRestMethod -Method GET -Uri $statusUrl
                $pj      = $poll.Content | ConvertFrom-Json
                $opState = if ($pj.properties.provisioningState) { $pj.properties.provisioningState }
                           elseif ($pj.status) { $pj.status } else { 'Unknown' }
                Write-Host ("    [{0:HH:mm:ss}] {1}" -f (Get-Date), $opState)
            } while ($opState -notin $terminal -and (Get-Date) -lt $deadline)

            if ($opState -notin $terminal) {
                $opError = "timed out after $TimeoutMinutes minutes"
            } elseif ($pj.error) {
                $opError = "$($pj.error.code) - $($pj.error.message)"
            }
        }
    }

    # 3. The quota itself is the source of truth: Azure has been seen to report
    #    'Failed' (ContactSupport) on an operation that still applied the new limit.
    $limit = $null
    $get   = Invoke-AzRestMethod -Method GET -Path $path
    if ($get.StatusCode -eq 200) { $limit = ($get.Content | ConvertFrom-Json).properties.limit.value }

    if ($null -ne $limit -and [int]$limit -ge $NewLimit) {
        $note = if ($opState -ne 'Succeeded') { "Operation reported '$opState' ($opError) but the limit is now $limit." } else { '' }
        return [pscustomobject]@{ Ok = $true; Limit = [int]$limit; Message = $note }
    }

    $why = if ($opError) { $opError } else { "operation state '$opState'" }
    return [pscustomobject]@{ Ok = $false; Limit = $limit; Message = "Quota request did not apply ($why). Current limit: $limit." }
}

# NOTE: tokens are matched against EITHER a region's metadata.geographyGroup
# OR its metadata.geography. Azure reports UK regions with geographyGroup
# 'Europe' and geography 'United Kingdom', so 'United Kingdom' must match on
# the geography field, while 'Europe' (the group) already includes UK regions.
function Resolve-Geography {
    param([string]$Token)
    switch -Regex (($Token -replace '\s', '').ToLower()) {
        '^(us|usa|unitedstates)$'              { return @('US') }
        '^canada$'                             { return @('Canada') }
        '^(northamerica|na)$'                  { return @('US','Canada','Mexico') }
        '^(europe|eu)$'                        { return @('Europe') }
        '^(uk|unitedkingdom)$'                 { return @('United Kingdom') }
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
    'Europe (incl. UK)'                    = @('Europe')
    'United Kingdom'                       = @('United Kingdom')
    'Asia Pacific'                         = @('Asia Pacific')
    'Middle East'                          = @('Middle East')
    'Africa'                               = @('Africa')
    'South America'                        = @('South America')
    'All regions'                          = $null
}

function Show-GeographyPrompt {
    Write-Host ''
    Write-Host "Where is the partner / MSP located?" -ForegroundColor Cyan
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
#  PIM helpers
# ====================================================================
# A PIM-activated role looks identical to a standing one in the membership /
# role-assignment checks, but two timing races can break the install when the
# role was only just activated: (1) the Cloud Shell token was minted before the
# activation, and (2) the activation hasn't finished propagating into Azure RBAC
# (managed-app deploys create role assignments late in the run, which fails with
# RoleAssignmentExists / authorization errors). An activation that expires
# mid-deploy fails the same way. These helpers classify how each role is held.

function ConvertTo-UtcDate {
    param($Value)
    if (-not $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    try { return ([datetimeoffset]::Parse("$Value", [cultureinfo]::InvariantCulture)).UtcDateTime } catch { return $null }
}

# Returns the 'iat' (issued-at) claim of a JWT as a UTC DateTime, or $null.
function Get-TokenIssuedUtc {
    param([string]$Jwt)
    try {
        $p = $Jwt.Split('.')[1].Replace('-', '+').Replace('_', '/')
        switch ($p.Length % 4) { 2 { $p += '==' } 3 { $p += '=' } }
        $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
        return [DateTimeOffset]::FromUnixTimeSeconds([long]$claims.iat).UtcDateTime
    } catch { return $null }
}

# Entra ID: the signed-in user's active directory-role schedule instances for Global Administrator.
# Returns @{ Ok; Instances } -- Ok = $false when the API can't be read (no P2 licence, no permission).
function Get-GlobalAdminScheduleInstances {
    $url = "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignmentScheduleInstances/filterByCurrentUser(on='principal')"
    $raw = az rest --method GET --url $url --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $raw) { return [pscustomobject]@{ Ok = $false; Instances = @() } }
    try { $r = $raw | ConvertFrom-Json } catch { return [pscustomobject]@{ Ok = $false; Instances = @() } }
    $inst = @($r.value | Where-Object { $_.roleDefinitionId -eq $GA_TEMPLATE_ID } | ForEach-Object {
        [pscustomobject]@{ AssignmentType = $_.assignmentType; Start = (ConvertTo-UtcDate $_.startDateTime); End = (ConvertTo-UtcDate $_.endDateTime) }
    })
    return [pscustomobject]@{ Ok = $true; Instances = $inst }
}

# Azure RBAC: the signed-in user's active Owner schedule instances on this subscription.
function Get-OwnerScheduleInstances {
    param([string]$Sub, [string]$Token, [string]$ArmBase)
    $uri   = "$($ArmBase.TrimEnd('/'))/subscriptions/$Sub/providers/Microsoft.Authorization/roleAssignmentScheduleInstances?api-version=2020-10-01&`$filter=asTarget()"
    $items = @()
    try {
        while ($uri) {
            $r = Invoke-ArmGet -Uri $uri -Token $Token
            $items += @($r.value)
            $uri = $r.nextLink
        }
    } catch { return [pscustomobject]@{ Ok = $false; Instances = @() } }
    $inst = @($items | Where-Object { $_.properties.roleDefinitionId -like "*/$OWNER_ROLE_ID" } | ForEach-Object {
        [pscustomobject]@{ AssignmentType = $_.properties.assignmentType; Start = (ConvertTo-UtcDate $_.properties.startDateTime); End = (ConvertTo-UtcDate $_.properties.endDateTime) }
    })
    return [pscustomobject]@{ Ok = $true; Instances = $inst }
}

# Classifies how a role is held and returns any timing warnings.
#   Holding: Standing (any non-PIM active assignment) | PIM (only activations) | Unknown
function Get-PimAssessment {
    param([string]$Role, $Lookup, $TokenIssuedUtc)
    $out = [pscustomobject]@{ Role = $Role; Holding = 'Unknown'; Start = $null; End = $null; Warnings = @() }
    if (-not $Lookup.Ok -or @($Lookup.Instances).Count -eq 0) { return $out }

    if (@($Lookup.Instances | Where-Object { $_.AssignmentType -eq 'Assigned' }).Count -gt 0) {
        $out.Holding = 'Standing'
        return $out
    }
    $act = @($Lookup.Instances | Where-Object { $_.AssignmentType -eq 'Activated' })
    if ($act.Count -eq 0) { return $out }

    # Several activations (e.g. direct + via group): use the one that lasts longest.
    $best = $act | Sort-Object @{ E = { if ($_.End) { $_.End } else { [datetime]::MaxValue } } } -Descending | Select-Object -First 1
    $out.Holding = 'PIM'; $out.Start = $best.Start; $out.End = $best.End
    $now  = (Get-Date).ToUniversalTime()
    $warn = [System.Collections.Generic.List[object]]::new()

    if ($best.Start -and $TokenIssuedUtc -and $TokenIssuedUtc -lt $best.Start) {
        $warn.Add([pscustomobject]@{ Code = 'StaleToken'; Role = $Role
            Message = ("$Role was activated at {0:HH:mm} UTC, after this Cloud Shell's token was issued ({1:HH:mm} UTC). The session may not carry the new role." -f $best.Start, $TokenIssuedUtc) })
    }
    if ($best.Start) {
        $mins = ($now - $best.Start).TotalMinutes
        if ($mins -lt $PimSettleMinutes) {
            $warn.Add([pscustomobject]@{ Code = 'RecentActivation'; Role = $Role
                Message = ("$Role was activated {0:N0} minute(s) ago. Allow ~{1} minutes for it to propagate into Azure RBAC." -f [Math]::Max(0, $mins), $PimSettleMinutes)
                WaitSeconds = [int][Math]::Ceiling(($PimSettleMinutes - $mins) * 60) })
        }
    }
    if ($best.End -and $best.End -lt $now.AddMinutes($DeployWindowMins)) {
        $warn.Add([pscustomobject]@{ Code = 'ExpiringSoon'; Role = $Role
            Message = ("$Role activation expires at {0:HH:mm} UTC ({1:N0} min from now). An NMM install takes ~45-60 minutes; extend the activation first." -f $best.End, [Math]::Max(0, ($best.End - $now).TotalMinutes)) })
    }
    $out.Warnings = $warn.ToArray()
    return $out
}

# ====================================================================
#  Policy helpers
# ====================================================================

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
# the -PolicyProbe switch is the ground-truth check.
function Get-DenyPolicyAssignments {
    param([string]$Sub, [string]$Token, [string]$ArmBase)
    $base    = $ArmBase.TrimEnd('/')
    $denies  = New-Object System.Collections.Generic.List[object]

    try {
        $auri = "$base/subscriptions/$Sub/providers/Microsoft.Authorization/policyAssignments?api-version=2022-06-01&`$filter=atScope()"
        $assignments = @()
        do {
            $r = Invoke-ArmGet -Uri $auri -Token $Token
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
            $er = Invoke-ArmGet -Uri $exUri -Token $Token
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

        $def = $null
        try { $def = Invoke-ArmGet -Uri ("$base{0}?api-version=2021-06-01" -f $defId) -Token $Token } catch {}
        if (-not $def) { continue }

        $effects = New-Object System.Collections.Generic.List[string]
        if ($defId -match '/policySetDefinitions/') {
            foreach ($pd in $def.properties.policyDefinitions) {
                $mDef = $null
                try { $mDef = Invoke-ArmGet -Uri ("$base{0}?api-version=2021-06-01" -f $pd.policyDefinitionId) -Token $Token } catch {}
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
# Key Vault, SQL server) into a throwaway RG, then delete it. Captures any
# blocking policy IDs from the deployment error. Always cleans up.
function Invoke-PolicyProbe {
    param([string]$Location)
    $result   = [ordered]@{ ran = $true; blocked = $false; blockingPolicyIds = @(); error = $null }
    $probeRg  = "nmm-policyprobe-$(Get-Date -Format 'yyyyMMddHHmmss')"
    $depName  = "policyprobe-$(Get-Date -Format 'HHmmss')"
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
        New-AzResourceGroup -Name $probeRg -Location $Location -Force -ErrorAction Stop | Out-Null
        try {
            New-AzResourceGroupDeployment -Name $depName -ResourceGroupName $probeRg `
                -TemplateFile $tmpl `
                -TemplateParameterObject @{ sqlAdminPassword = (New-StrongPassword -Length 24) } `
                -ErrorAction Stop | Out-Null
            Write-Host "  Policy probe PASSED: representative resources are allowed by policy." -ForegroundColor Green
        } catch {
            $result.blocked = $true
            $text = "$($_.Exception.Message)"
            $ops  = Get-AzResourceGroupDeploymentOperation -ResourceGroupName $probeRg -DeploymentName $depName -ErrorAction SilentlyContinue
            if ($ops) { $text += ' ' + (($ops | ForEach-Object { $_.StatusMessage }) -join ' ') }
            $ids = [regex]::Matches($text, '/providers/Microsoft\.Authorization/policy(?:Assignments|Definitions)/[^\s"'',}]+') |
                ForEach-Object { $_.Value } | Select-Object -Unique
            $result.blockingPolicyIds = @($ids)
            Write-Host "  Policy probe BLOCKED: a policy denied one or more representative resources." -ForegroundColor Red
            if ($ids) {
                foreach ($id in $ids) { Write-Host ("    -> {0}" -f $id) -ForegroundColor Red }
            } else {
                Write-Host ("    (Could not extract policy ID; raw error: {0})" -f $_.Exception.Message) -ForegroundColor DarkGray
            }
        }
    } catch {
        $result.error = "Probe setup failed: $($_.Exception.Message)"
        Write-Warning $result.error
    } finally {
        Write-Host "  Cleaning up probe resource group '$probeRg' (waiting for delete)..." -ForegroundColor DarkGray
        $null = Remove-AzResourceGroup -Name $probeRg -Force -ErrorAction SilentlyContinue
        if ($tmpl -and (Test-Path $tmpl)) { Remove-Item $tmpl -ErrorAction SilentlyContinue }
    }
    return $result
}

# ====================================================================
#  Pre-flight (az auth)
# ====================================================================
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI ('az') not found. Run in Azure Cloud Shell (PowerShell)."
}

# Deployment, quota-request and policy-probe steps use Az PowerShell cmdlets.
# Present in Cloud Shell by default; verified here so a broken session fails
# fast. Pure read-only -CheckOnly skips this.
$needAz = (-not $CheckOnly) -or $PolicyProbe
if ($needAz) {
    $missingAzModules = @('Az.Accounts','Az.Resources','Az.Websites') |
        Where-Object { -not (Get-Module -ListAvailable -Name $_) }
    if ($missingAzModules.Count -gt 0) {
        throw ("Required Az PowerShell module(s) not found: {0}. Restart Cloud Shell in PowerShell mode and retry." -f ($missingAzModules -join ', '))
    }
}

# Subscription selection: honor -SubscriptionId, else auto-pick a lone enabled
# sub, else prompt. --refresh pulls the live list instead of the CLI cache;
# --all includes non-Enabled subs so they're visible (but not selectable).
if (-not $SubscriptionId) {
    $allSubs     = @(az account list --refresh --all --only-show-errors 2>$null | ConvertFrom-Json)
    $enabledSubs = @($allSubs | Where-Object { $_.state -eq 'Enabled' })
    if ($enabledSubs.Count -eq 0) {
        throw "No enabled Azure subscriptions found for this account."
    }
    if ($enabledSubs.Count -eq 1) {
        $SubscriptionId = $enabledSubs[0].id
        Write-Host ("Using only enabled subscription: {0}" -f $enabledSubs[0].name) -ForegroundColor DarkGray
    } elseif (-not [Environment]::UserInteractive) {
        $current = @($enabledSubs | Where-Object { $_.isDefault }) + $enabledSubs | Select-Object -First 1
        $SubscriptionId = $current.id
        Write-Host ("Non-interactive session; using current subscription: {0}" -f $current.name) -ForegroundColor DarkGray
    } else {
        Write-Host ''
        Write-Host "Select an Azure subscription:" -ForegroundColor Cyan
        $defaultIdx = 0
        for ($i = 0; $i -lt $allSubs.Count; $i++) {
            $s      = $allSubs[$i]
            $marker = if ($s.isDefault) { ' (current)' } else { '' }
            if ($s.state -eq 'Enabled') {
                Write-Host ("  {0,2}. {1}  [{2}]{3}" -f ($i + 1), $s.name, $s.id, $marker)
                if ($s.isDefault -or $defaultIdx -eq 0) { $defaultIdx = $i + 1 }
            } else {
                Write-Host ("  {0,2}. {1}  [{2}]{3}  - {4}, can't be used" -f ($i + 1), $s.name, $s.id, $marker, $s.state) -ForegroundColor DarkGray
            }
        }
        do {
            $pick = Read-Host "Enter choice [$defaultIdx]"
            if ([string]::IsNullOrWhiteSpace($pick)) { $pick = "$defaultIdx" }
            $idx = 0
            $valid = [int]::TryParse($pick, [ref]$idx) -and $idx -ge 1 -and $idx -le $allSubs.Count
            if (-not $valid) {
                Write-Host ("Invalid choice. Enter 1-{0}." -f $allSubs.Count) -ForegroundColor Yellow
            } elseif ($allSubs[$idx - 1].state -ne 'Enabled') {
                Write-Host ("That subscription is {0} and can't be used. Pick another." -f $allSubs[$idx - 1].state) -ForegroundColor Yellow
                $valid = $false
            }
        } while (-not $valid)
        $SubscriptionId = $allSubs[$idx - 1].id
        Write-Host ("Selected: {0}" -f $allSubs[$idx - 1].name) -ForegroundColor Green
    }
}

az account set --subscription $SubscriptionId --only-show-errors | Out-Null
$ctx = az account show --only-show-errors 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not logged in. Run 'az login' first." }
if ($ctx.id -ne $SubscriptionId -and $ctx.name -ne $SubscriptionId) {
    throw "Azure CLI couldn't switch to subscription '$SubscriptionId' (still on '$($ctx.name)')."
}
$subId = $ctx.id
$script:report.subscriptionId   = $ctx.id
$script:report.subscriptionName = $ctx.name

# Read the ARM endpoint from the active cloud rather than hardcoding it.
$armBase = az cloud show --query 'endpoints.resourceManager' -o tsv 2>$null
if (-not $armBase) { $armBase = 'https://management.azure.com' }
$armBase = $armBase.TrimEnd('/')

# The checks use Azure CLI but the deploy / quota request / probe use Az
# PowerShell, so both must point at the same subscription.
if ($needAz) {
    if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
        Write-Host "Az PowerShell not connected; running Connect-AzAccount..." -ForegroundColor DarkGray
        Connect-AzAccount -Tenant $ctx.tenantId -SubscriptionId $subId -ErrorAction Stop | Out-Null
    }
    $azCtx = Set-AzContext -SubscriptionId $subId -Tenant $ctx.tenantId -ErrorAction SilentlyContinue
    if (-not $azCtx -or $azCtx.Subscription.Id -ne $subId) {
        throw "Az PowerShell couldn't switch to subscription '$($ctx.name)'. Run 'Connect-AzAccount -Tenant $($ctx.tenantId)' and re-run the script."
    }
}

$token = az account get-access-token --query accessToken -o tsv 2>$null
if (-not $token) { throw "Could not acquire Azure access token." }

Write-Banner "Nerdio Manager for MSP (NMM) - Pre-Install Readiness Check"
Write-Host ("Subscription : {0}" -f $ctx.name)
Write-Host ("Sub ID       : {0}" -f $ctx.id)
Write-Host ("NMM version  : {0}" -f $NmmVersion)
Write-Host ("Checking for : App Service '{0}' x{1} (quota)  +  Azure SQL '{2}/{3}'" -f $AppServiceSku, $AppServiceInstances, $SqlEdition, $SqlServiceObjective)
if ($CheckOnly) { Write-Host "Mode         : check only (no changes to the subscription)" -ForegroundColor DarkGray }
if ($Force)     { Write-Host "-Force       : readiness gates will be bypassed." -ForegroundColor DarkYellow }
Write-Host ''

# ====================================================================
#  Resource group check
# ====================================================================
# NMM deploys into the resource group's region, so the RG must be new (created
# in the region picked later). A soft-deleted Key Vault left by an earlier
# install into an RG with the same name also blocks the deployment.
# In -CheckOnly mode this only reports; it never prompts or purges.
Write-Banner "Resource Group Check"
if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    Write-Host "No -ResourceGroupName given; skipping (check-only mode)." -ForegroundColor DarkGray
} else {
    function Get-NewRgName([string]$Why) {
        if ($Force -or -not [Environment]::UserInteractive) {
            throw "$Why Re-run with a different -ResourceGroupName."
        }
        return (Read-Host "Enter a new resource group name")
    }
    while ($true) {
        $ResourceGroupName = "$ResourceGroupName".Trim()
        $script:report.resourceGroup.name = $ResourceGroupName

        $valid = ($ResourceGroupName -match '^[-\w\.\(\)]{1,90}$') -and -not $ResourceGroupName.EndsWith('.')
        $script:report.resourceGroup.valid = $valid
        if (-not $valid) {
            $msg = "'$ResourceGroupName' isn't a valid resource group name (1-90 letters, digits, - _ . ( ), can't end in a period)."
            Write-Host $msg -ForegroundColor Yellow
            if ($CheckOnly) { break }
            $ResourceGroupName = Get-NewRgName $msg
            continue
        }

        $exists = (az group exists --name $ResourceGroupName --only-show-errors 2>$null) -eq 'true'
        $script:report.resourceGroup.exists = $exists
        if ($exists) {
            $msg = "Resource group '$ResourceGroupName' already exists. NMM needs a new resource group."
            Write-Host $msg -ForegroundColor Yellow
            if ($CheckOnly) { break }
            $ResourceGroupName = Get-NewRgName $msg
            continue
        }

        $deletedVaults = @(az keyvault list-deleted --only-show-errors 2>$null | ConvertFrom-Json |
            Where-Object { $_.properties.vaultId -like "*/resourceGroups/$ResourceGroupName-*" })
        $script:report.resourceGroup.softDeletedVaults = @($deletedVaults | ForEach-Object { $_.name })
        if ($deletedVaults.Count -gt 0) {
            Write-Host "Soft-deleted Key Vault(s) from an earlier NMM install into '$ResourceGroupName' will block this deployment:" -ForegroundColor Yellow
            foreach ($kv in $deletedVaults) {
                Write-Host ("  - {0}  ({1}, deleted {2})" -f $kv.name, $kv.properties.location, $kv.properties.deletionDate) -ForegroundColor Yellow
            }
            if ($CheckOnly) {
                Write-Host "  Check-only: not purging. Purge them or use a different resource group name before deploying." -ForegroundColor DarkGray
                break
            }
            # Purging is irreversible, so it always needs an interactive yes -- -Force does not purge.
            if (-not [Environment]::UserInteractive) {
                throw "Soft-deleted Key Vault(s) block resource group '$ResourceGroupName'. Purge them or re-run with a different -ResourceGroupName."
            }
            $ans = Read-Host "Purge them now? [Y/n, N = use a different resource group name]"
            if ([string]::IsNullOrWhiteSpace($ans) -or $ans -match '^[Yy]') {
                $purgeFailed = $false
                foreach ($kv in $deletedVaults) {
                    Write-Host ("  Purging {0} (can take a few minutes)..." -f $kv.name) -ForegroundColor Cyan
                    az keyvault purge --name $kv.name --location $kv.properties.location --only-show-errors
                    if ($LASTEXITCODE -ne 0) { $purgeFailed = $true }
                }
                if (-not $purgeFailed) {
                    Write-Host "  Purged." -ForegroundColor Green
                    $script:report.resourceGroup.purged = $true
                    break
                }
                Write-Host "  Purge failed (purge protection may be on). Use a different resource group name." -ForegroundColor Red
            }
            $ResourceGroupName = Read-Host "Enter a new resource group name"
            continue
        }
        break
    }
    if ($CheckOnly) {
        Write-Host ("Resource group '{0}' checked (report only)." -f $ResourceGroupName) -ForegroundColor DarkGray
    } else {
        Write-Host ("Resource group '{0}' will be created in the region you pick." -f $ResourceGroupName) -ForegroundColor Green
    }
}

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
    $script:report.signedInUser = $me.userPrincipalName
    $ownerAssignments = az role assignment list `
        --assignee $me.id --role Owner --scope "/subscriptions/$($ctx.id)" `
        --include-groups --include-inherited --only-show-errors 2>$null | ConvertFrom-Json
    $isOwner = ($null -ne $ownerAssignments -and @($ownerAssignments).Count -gt 0)

    $isGA = $null; $gaNote = ''
    try {
        $dirRoles = az rest --method GET `
            --url 'https://graph.microsoft.com/v1.0/me/transitiveMemberOf/microsoft.graph.directoryRole' `
            --only-show-errors 2>$null | ConvertFrom-Json
        if ($dirRoles -and $dirRoles.PSObject.Properties['value']) {
            $isGA = [bool]($dirRoles.value | Where-Object { $_.roleTemplateId -eq $GA_TEMPLATE_ID })
        } else { $gaNote = ' (no directory roles returned)' }
    } catch { $gaNote = ' (Graph API check failed)' }

    $script:report.permissions.owner       = [bool]$isOwner
    $script:report.permissions.globalAdmin = $isGA

    $ownerLabel = if ($isOwner) { 'PASS' } else { 'FAIL' }
    $gaLabel    = if ($null -eq $isGA) { "UNKNOWN$gaNote" } elseif ($isGA) { 'PASS' } else { 'FAIL' }
    $ownerColor = if ($isOwner) { 'Green' } else { 'Red' }
    $gaColor    = if ($null -eq $isGA) { 'Yellow' } elseif ($isGA) { 'Green' } else { 'Red' }
    "{0,-55} {1}" -f "  Subscription Owner", $ownerLabel | Write-Host -ForegroundColor $ownerColor
    if ($isOwner) {
        # Report how each Owner assignment reaches this user: direct, via group, and/or inherited
        $subScope = "/subscriptions/$($ctx.id)"
        foreach ($a in @($ownerAssignments)) {
            $via = if ($a.principalId -eq $me.id) { 'direct to user' }
                   else { "via $($a.principalType) '$($a.principalName)'" }
            $at  = if ($a.scope -eq $subScope) { 'on this subscription' }
                   elseif ($a.scope -eq '/') { 'inherited from tenant root (/)' }
                   elseif ($a.scope -match '/managementGroups/([^/]+)$') { "inherited from management group '$($Matches[1])'" }
                   else { "inherited from $($a.scope)" }
            Write-Host ("      - Owner {0}, {1}" -f $via, $at) -ForegroundColor DarkGray
        }
    }
    "{0,-55} {1}" -f "  Entra ID Global Administrator", $gaLabel | Write-Host -ForegroundColor $gaColor

    # --- PIM: standing vs activated, and activation timing -------------------
    $pimWarnings = @()
    if ($isOwner -or $isGA) {
        $armIssued   = Get-TokenIssuedUtc $token
        $graphToken  = az account get-access-token --resource-type ms-graph --query accessToken -o tsv 2>$null
        $graphIssued = if ($graphToken) { Get-TokenIssuedUtc $graphToken } else { $null }

        $assessments = @()
        if ($isOwner) { $assessments += Get-PimAssessment -Role 'Owner' -Lookup (Get-OwnerScheduleInstances -Sub $subId -Token $token -ArmBase $armBase) -TokenIssuedUtc $armIssued }
        if ($isGA)    { $assessments += Get-PimAssessment -Role 'Global Administrator' -Lookup (Get-GlobalAdminScheduleInstances) -TokenIssuedUtc $graphIssued }

        foreach ($pa in $assessments) {
            $line = switch ($pa.Holding) {
                'Standing' { 'standing assignment' }
                'PIM'      { if ($pa.End) { "PIM-activated {0:HH:mm} UTC, expires {1:HH:mm} UTC" -f $pa.Start, $pa.End } else { "PIM-activated {0:HH:mm} UTC, no expiry" -f $pa.Start } }
                default    { 'standing vs PIM not determined (PIM API unavailable or no P2 licence)' }
            }
            Write-Host ("      - {0}: {1}" -f $pa.Role, $line) -ForegroundColor DarkGray
            $pimWarnings += @($pa.Warnings)
        }
        $script:report.permissions.ownerHolding       = ($assessments | Where-Object Role -eq 'Owner').Holding
        $script:report.permissions.globalAdminHolding = ($assessments | Where-Object Role -eq 'Global Administrator').Holding
        $script:report.permissions.pimWarnings        = @($pimWarnings | ForEach-Object { [ordered]@{ code = $_.Code; role = $_.Role; message = $_.Message } })
    }
    Write-Host ''

    if ((-not $isOwner) -or ($isGA -eq $false)) {
        Write-Host '  ACTION REQUIRED: Missing permissions will cause the NMM install to fail.' -ForegroundColor Red
        if (-not $isOwner)    { Write-Host ("  -> Assign Owner on subscription '{0}'." -f $ctx.name) -ForegroundColor Red }
        if ($isGA -eq $false) { Write-Host '  -> Assign Global Administrator in Entra ID.' -ForegroundColor Red }
        Write-Host ''
        if ($CheckOnly) {
            Write-Host '  Check-only: continuing so the remaining checks still run.' -ForegroundColor DarkGray
        } elseif ($Force) {
            Write-Host '  -Force specified; continuing despite missing permissions.' -ForegroundColor DarkYellow
        } elseif (-not [Environment]::UserInteractive) {
            throw "Missing required permissions (Owner / Global Administrator). Resolve and re-run, or pass -Force to override."
        } elseif (-not (Read-YesNo -Prompt "  Continue anyway? (the install will very likely fail)" -DefaultYes $false)) {
            throw "Aborted: required permissions are not satisfied."
        }
    } else {
        Write-Host '  All required permissions confirmed.' -ForegroundColor Green
    }

    # PIM timing warnings are advisory: they have been linked to RoleAssignmentExists
    # install failures, but a PIM-activated role usually installs fine.
    if ($pimWarnings.Count -gt 0) {
        Write-Host ''
        Write-Host '  PIM TIMING WARNING:' -ForegroundColor Yellow
        foreach ($w in $pimWarnings) { Write-Host ("  -> {0}" -f $w.Message) -ForegroundColor Yellow }

        $stale    = @($pimWarnings | Where-Object Code -eq 'StaleToken')
        $recent   = @($pimWarnings | Where-Object Code -eq 'RecentActivation')
        $expiring = @($pimWarnings | Where-Object Code -eq 'ExpiringSoon')

        if ($CheckOnly) {
            Write-Host '  Before deploying: restart Cloud Shell after activating PIM roles, wait ~10 minutes, and make sure the activation outlasts the install.' -ForegroundColor DarkGray
        } else {
            if ($stale.Count -gt 0) {
                Write-Host '  Recommended: restart Cloud Shell (toolbar > Restart) so the session picks up the activated role, then re-run.' -ForegroundColor Yellow
                if (-not (Read-YesNo -Prompt "  Continue in this session anyway?" -DefaultYes $false)) {
                    throw "Stopped so Cloud Shell can be restarted after PIM activation. Re-run the script in a fresh session."
                }
            }
            if ($recent.Count -gt 0) {
                $waitSec = ($recent | Measure-Object -Property WaitSeconds -Maximum).Maximum
                if ($waitSec -gt 0 -and -not $Force -and (Read-YesNo -Prompt ("  Wait {0:N0} more minute(s) for the activation to settle? (recommended)" -f [Math]::Ceiling($waitSec / 60)) -DefaultYes $true)) {
                    $until = (Get-Date).AddSeconds($waitSec)
                    while ((Get-Date) -lt $until) {
                        Write-Host ("`r  Waiting... {0:mm\:ss} remaining   " -f ($until - (Get-Date))) -NoNewline
                        Start-Sleep -Seconds 5
                    }
                    Write-Host ''
                }
            }
            if ($expiring.Count -gt 0) {
                if (-not (Read-YesNo -Prompt "  Continue even though a PIM activation may expire mid-install?" -DefaultYes $false)) {
                    throw "Stopped: extend the PIM activation, then re-run."
                }
            }
        }
    }
}

# ====================================================================
#  Phase 1: Resource provider registration
# ====================================================================
Write-Banner "Phase 1: Resource Provider Registration"
$states = Get-ProviderStates
$providerResults = @(foreach ($ns in $NmmRequiredProviders) {
    [pscustomobject]@{ Provider = $ns; State = if ($states[$ns]) { $states[$ns] } else { 'UNKNOWN' } }
})
$providerResults | Format-Table -AutoSize | Out-Host
$script:report.providers = @($providerResults | ForEach-Object { [ordered]@{ name = $_.Provider; state = $_.State } })

$unregistered = @($providerResults | Where-Object { $_.State -ne 'Registered' })
if ($unregistered.Count -eq 0) {
    Write-Host 'All required providers are Registered.' -ForegroundColor Green
} else {
    # The install deploys a managed application that provisions resources across
    # every provider above; an unregistered provider causes a
    # MissingSubscriptionRegistration failure partway through the nested
    # deployment, leaving a half-built managed resource group to clean up. So we
    # do NOT continue to deployment unless these are resolved.
    Write-Host ("{0} required provider(s) are NOT registered. The NMM install will fail without them:" -f $unregistered.Count) -ForegroundColor Yellow
    foreach ($p in $unregistered) {
        Write-Host ("  - {0}  ({1})" -f $p.Provider, $p.State) -ForegroundColor Yellow
    }

    $doRegister = $false
    if ($RegisterProviders -or $Force) {
        $doRegister = $true
    } elseif ($CheckOnly) {
        # Check-only still offers to register (providers are a prerequisite, not a deploy);
        # declining just reports and carries on with the remaining checks.
        if ([Environment]::UserInteractive) { $doRegister = Read-YesNo -Prompt "Register them now?" -DefaultYes $true }
        if (-not $doRegister) {
            Write-Host "Not registering. Re-run with -RegisterProviders, or register them before deploying." -ForegroundColor DarkGray
        }
    } elseif (-not [Environment]::UserInteractive) {
        throw ("{0} required provider(s) not registered. Re-run with -RegisterProviders." -f $unregistered.Count)
    } else {
        $doRegister = Read-YesNo -Prompt "Register them now?" -DefaultYes $true
        if (-not $doRegister) {
            throw "Required providers are not registered. Aborting before deployment. Re-run with -RegisterProviders once resolved."
        }
    }

    if ($doRegister) {
        $ok = Register-NmmProviders -Unregistered $unregistered -AllProviders $NmmRequiredProviders -TimeoutMinutes $ProviderTimeoutMinutes
        if (-not $ok -and -not $Force -and -not $CheckOnly) {
            throw "Provider registration did not complete within the timeout. Resolve before deploying, or re-run with -Force to override."
        }
        # Re-snapshot provider states (they may have changed after registration).
        $states = Get-ProviderStates
        $script:report.providers = @($NmmRequiredProviders | ForEach-Object {
            [ordered]@{ name = $_; state = if ($states[$_]) { $states[$_] } else { 'UNKNOWN' } }
        })
    }
}

# ====================================================================
#  Policy Deny Check (read-only) -- part of readiness, runs in CheckOnly too
# ====================================================================
Write-Banner "Policy Deny Check"
Write-Host "Querying policy assignments in subscription scope for Deny effects..." -ForegroundColor DarkGray
$denyResult = Get-DenyPolicyAssignments -Sub $subId -Token $token -ArmBase $armBase
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
$script:report.policy.denyAssignments = @($denyResult.Denies)

# ====================================================================
#  Phase 2: Region eligibility (SQL availability + App Service quota)
# ====================================================================
Write-Banner "Phase 2: Region Eligibility"
Write-Host "Loading Azure region list..." -ForegroundColor DarkGray
$allLocations = az account list-locations --only-show-errors 2>$null | ConvertFrom-Json
$physical     = $allLocations | Where-Object { $_.metadata.regionType -eq 'Physical' }

$nameToSlug = @{}; $slugToName = @{}; $slugToGeo = @{}; $slugToGeography = @{}
foreach ($loc in $physical) {
    $nameToSlug[$loc.displayName] = $loc.name
    $slugToName[$loc.name]        = $loc.displayName
    $slugToGeo[$loc.name]         = $loc.metadata.geographyGroup
    $slugToGeography[$loc.name]   = $loc.metadata.geography
}

# Region discovery only: this lists where the SKU is OFFERED, not whether this
# subscription has quota for it. Quota is checked per region further below.
Write-Host ("Querying App Service regions that offer '{0}'..." -f $AppServiceSku) -ForegroundColor DarkGray
$appSvcRaw   = az appservice list-locations --sku $AppServiceSku --only-show-errors 2>$null | ConvertFrom-Json
$appSvcSlugs = [System.Collections.Generic.HashSet[string]]::new()
foreach ($r in $appSvcRaw) {
    $slug = if ($nameToSlug.ContainsKey($r.name)) { $nameToSlug[$r.name] } else { ($r.name -replace '\s','').ToLower() }
    [void]$appSvcSlugs.Add($slug)
}
Write-Host ("  -> {0} regions offer App Service {1}." -f $appSvcSlugs.Count, $AppServiceSku) -ForegroundColor DarkGray

$apiVersion      = '2023-05-01-preview'   # Microsoft.Sql capabilities
$quotaApiVersion = '2025-03-01'           # Microsoft.Quota (App Service SKU quota)
$quotaCol        = "${AppServiceSku}Quota"

# Region selection loop: "back" options return here to choose a different geography
while ($true) {
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
            # Match on either geographyGroup (e.g. 'Europe') or geography (e.g. 'United Kingdom').
            $candidates = $candidates | Where-Object {
                ($geoGroups -contains $slugToGeo[$_]) -or ($geoGroups -contains $slugToGeography[$_])
            }
        }
        $candidates = $candidates | Sort-Object
        Write-Host ("Checking {0} region(s) in '{1}'..." -f @($candidates).Count, $geoLabel) -ForegroundColor DarkGray
    }

    if (-not $candidates -or @($candidates).Count -eq 0) {
        Write-Host "No candidate regions to check." -ForegroundColor Yellow
        if ([Environment]::UserInteractive -and (Read-YesNo -Prompt "Go back and choose a different geography?" -DefaultYes $true) -and -not $Force) {
            $Regions = $null; $Geography = $null; continue
        }
        Save-Report
        return
    }
    $candidates = @($candidates)

    # SQL availability and App Service quota for a region run in the same parallel worker (one pass, not two)
    Write-Host ("Checking Azure SQL {0}/{1} availability and App Service {2} quota..." -f $SqlEdition, $SqlServiceObjective, $AppServiceSku) -ForegroundColor DarkGray
    $fnArm   = ${function:Invoke-ArmGet}.ToString()
    $fnSql   = ${function:Get-SqlRegionStatus}.ToString()
    $fnQuota = ${function:Get-AppServiceQuotaStatus}.ToString()
    $checkResults = $candidates | ForEach-Object -Parallel {
        ${function:Invoke-ArmGet}             = $using:fnArm
        ${function:Get-SqlRegionStatus}       = $using:fnSql
        ${function:Get-AppServiceQuotaStatus} = $using:fnQuota
        $sql = Get-SqlRegionStatus -Region $_ -Sub $using:subId -Token $using:token -ArmBase $using:armBase `
                   -Edition $using:SqlEdition -Slo $using:SqlServiceObjective -ApiVersion $using:apiVersion
        $app = Get-AppServiceQuotaStatus -Region $_ -Sub $using:subId -Token $using:token -ArmBase $using:armBase `
                   -Sku $using:AppServiceSku -Required $using:AppServiceInstances -ApiVersion $using:quotaApiVersion
        [pscustomobject]@{ Region = $_; Sql = $sql; App = $app }
    } -ThrottleLimit 15

    $sqlByRegion = @{}; $appByRegion = @{}
    foreach ($c in $checkResults) { $sqlByRegion[$c.Region] = $c.Sql; $appByRegion[$c.Region] = $c.App }

    # If the Quota API failed in EVERY region, the problem is the API call itself
    # (unsupported scope, auth, registration), not the subscription's quota.
    $appQuotaResults = @($checkResults | ForEach-Object { $_.App } | Where-Object { $_ })
    if ($appQuotaResults.Count -gt 0 -and
        @($appQuotaResults | Where-Object { $_.Reason -like 'Quota API error*' }).Count -eq $appQuotaResults.Count) {
        Write-Warning "App Service quota API failed in every region; quota could not be verified. First error: $($appQuotaResults[0].Reason)"
    }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($slug in $candidates) {
        $offered   = $appSvcSlugs.Contains($slug)
        $app       = $appByRegion[$slug]
        $appOk     = $offered -and ($null -ne $app) -and ($app.Ok -eq $true)
        $appQuota  = $offered -and ($null -ne $app) -and ($app.NeedsQuota -eq $true)
        $sql       = $sqlByRegion[$slug]
        $sqlOk     = ($null -ne $sql) -and ($sql.Ok -eq $true)
        $display   = if ($slugToName.ContainsKey($slug)) { $slugToName[$slug] } else { $slug }
        $appReason = if ($appOk) { '' }
                     elseif (-not $offered) { "App Service $AppServiceSku not offered" }
                     elseif ($app) { $app.Reason }
                     else { 'no App Service quota result' }
        $skuQuota   = '-'
        if ($app -and $null -ne $app.SkuLimit)   { $skuQuota   = '{0}/{1}' -f $app.SkuUsed, $app.SkuLimit }
        $totalQuota = '-'
        if ($app -and $null -ne $app.TotalLimit) { $totalQuota = '{0}/{1}' -f $app.TotalUsed, $app.TotalLimit }
        $results.Add([pscustomobject]@{
            Region           = $slug
            DisplayName      = $display
            AppService       = if ($appOk) { 'Yes' } elseif ($appQuota) { 'Quota' } else { 'No' }
            $quotaCol        = $skuQuota
            SqlDb            = if ($sqlOk) { 'Yes' } else { 'No' }
            Eligible         = if ($appOk -and $sqlOk) { 'YES' } elseif ($appQuota -and $sqlOk) { 'QUOTA' } else { 'no' }
            SqlReason        = if ($sqlOk) { '' } else { if ($sql) { $sql.Reason } else { 'no SQL result' } }
            AppServiceReason = $appReason
            SkuRowName       = if ($app) { $app.SkuRowName } else { '' }
            SkuRowCount      = if ($app) { $app.SkuRowCount } else { 0 }
            TotalRegional    = $totalQuota
        })
    }

    $eligRank = @{ 'YES' = 0; 'QUOTA' = 1; 'no' = 2 }
    $sorted   = @($results | Sort-Object @{E={ $eligRank[$_.Eligible] }}, DisplayName)
    # Regions that only need a quota increase are still offered in the picker, with a warning
    $eligible = @($sorted | Where-Object { $_.Eligible -eq 'YES' -or $_.Eligible -eq 'QUOTA' })

    $script:report.regions = @($sorted | ForEach-Object {
        [ordered]@{
            region              = $_.Region
            displayName         = $_.DisplayName
            status              = $_.Eligible
            eligible            = ($_.Eligible -eq 'YES')
            quotaIncreaseNeeded = ($_.Eligible -eq 'QUOTA')
            appService          = $_.AppService
            appServiceQuota     = $_.$quotaCol
            totalRegionalQuota  = $_.TotalRegional
            sqlDb               = ($_.SqlDb -eq 'Yes')
            reasons             = @($_.SqlReason, $_.AppServiceReason | Where-Object { $_ })
        }
    })

    Write-Banner "Results"
    $sorted | Format-Table Region, DisplayName, AppService, $quotaCol, SqlDb, Eligible -AutoSize | Out-Host

    $needQuota = @($sorted | Where-Object { $_.Eligible -eq 'QUOTA' })
    if ($needQuota.Count -gt 0) {
        Write-Host "Eligible after a quota increase (SKU quota row exists but limit is too low):" -ForegroundColor Yellow
        foreach ($r in $needQuota) {
            Write-Host ("  {0,-22} {1}" -f $r.Region, $r.AppServiceReason) -ForegroundColor Yellow
        }
        if ($CheckOnly) {
            Write-Host "  A deploy run offers to request this increase automatically after you confirm." -ForegroundColor DarkGray
        }
        Write-Host ''
    }

    $ineligible = @($sorted | Where-Object { $_.Eligible -eq 'no' })
    if ($ineligible.Count -gt 0) {
        Write-Host "Why regions are not eligible:" -ForegroundColor DarkYellow
        foreach ($r in $ineligible) {
            $why = @($r.AppServiceReason, $r.SqlReason | Where-Object { $_ }) -join ' | '
            Write-Host ("  {0,-22} {1}" -f $r.Region, $why) -ForegroundColor DarkYellow
        }
        Write-Host ''
    }

    if ($OutFile) {
        $sorted | Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8
        Write-Host ("Results CSV: {0}" -f $OutFile) -ForegroundColor Cyan
    }

    if ($eligible.Count -eq 0) {
        Write-Host "No region has App Service $AppServiceSku (available or requestable) and SQL $SqlEdition/$SqlServiceObjective available." -ForegroundColor Red
        if (-not $CheckOnly -and -not $Force -and [Environment]::UserInteractive -and
            (Read-YesNo -Prompt "Go back and choose a different geography?" -DefaultYes $true)) {
            $Regions = $null; $Geography = $null; continue
        }
        Write-Host "Exiting." -ForegroundColor Red
        Save-Report
        return
    }

    if ($CheckOnly) {
        # Optional ground-truth probe without deploying NMM: create+delete test
        # resources in the first eligible region (or a -Regions-specified one).
        if ($PolicyProbe) {
            $probeRegion = $eligible[0].Region
            Write-Banner "Policy Probe (create/delete test)"
            Write-Host ("Probing region '{0}' (first eligible; pass -Regions to target another)..." -f $probeRegion) -ForegroundColor Cyan
            $probe = Invoke-PolicyProbe -Location $probeRegion
            $script:report.policy.probe.ran               = $probe.ran
            $script:report.policy.probe.blocked           = $probe.blocked
            $script:report.policy.probe.blockingPolicyIds = @($probe.blockingPolicyIds)
        }
        Write-Host ''
        $readyCount = @($eligible | Where-Object Eligible -eq 'YES').Count
        Write-Host ("Check-only mode: {0} region(s) ready, {1} eligible after a quota increase. Stopping before deployment." -f $readyCount, ($eligible.Count - $readyCount)) -ForegroundColor Cyan
        Write-Host "Re-run with -ResourceGroupName <name> (and without -CheckOnly) to deploy." -ForegroundColor DarkGray
        Save-Report
        return
    }

    # ====================================================================
    #  Phase 3: Region picker
    # ====================================================================
    Write-Banner "Select a region for NMM deployment"
    for ($i = 0; $i -lt $eligible.Count; $i++) {
        $e = $eligible[$i]
        if ($e.Eligible -eq 'QUOTA') {
            Write-Host ("  {0,2}. {1}  ({2})  [needs {3} quota increase, currently {4} - requested automatically after you confirm]" -f ($i + 1), $e.DisplayName, $e.Region, $AppServiceSku, $e.$quotaCol) -ForegroundColor Yellow
        } else {
            Write-Host ("  {0,2}. {1}  ({2})" -f ($i + 1), $e.DisplayName, $e.Region)
        }
    }
    Write-Host ''
    Write-Host "   0. << Back to geography / region selection" -ForegroundColor Cyan

    $idx = -1
    do {
        $pick = Read-Host "`nEnter choice [1]"
        if ([string]::IsNullOrWhiteSpace($pick)) { $pick = '1' }
        if ($pick -match '^[Bb]') { $pick = '0' }
        if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 0 -or $idx -gt $eligible.Count) {
            Write-Host ("Invalid choice. Enter 0-{0}." -f $eligible.Count) -ForegroundColor Yellow
            $idx = -1
        }
    } while ($idx -lt 0)

    if ($idx -eq 0) {
        Write-Host "Returning to geography selection..." -ForegroundColor Cyan
        $Regions = $null; $Geography = $null
        continue
    }
    $sel      = $eligible[$idx - 1]
    $Location = $sel.Region
    $script:report.selectedRegion = $Location
    Write-Host ("Selected: {0} ({1})" -f $sel.DisplayName, $Location) -ForegroundColor Green

    # Ground-truth policy probe (opt-in): create+delete representative resources in
    # the chosen region to confirm no policy blocks the install. Runs before the
    # deploy confirmation so a block can stop us before spending money.
    if ($PolicyProbe) {
        Write-Banner "Policy Probe (create/delete test)"
        Write-Host ("Creating + deleting representative resources in '{0}'..." -f $Location) -ForegroundColor Cyan
        $probe = Invoke-PolicyProbe -Location $Location
        $script:report.policy.probe.ran               = $probe.ran
        $script:report.policy.probe.blocked           = $probe.blocked
        $script:report.policy.probe.blockingPolicyIds = @($probe.blockingPolicyIds)
        if ($probe.blocked -and -not $Force) {
            Write-Host ''
            Write-Host "A policy would block the NMM deployment. Resolve the policies above before continuing." -ForegroundColor Red
            if (-not (Read-YesNo -Prompt "Continue with the deployment anyway?" -DefaultYes $false)) {
                Write-Host "Exiting due to blocking policy." -ForegroundColor Red
                Save-Report
                return
            }
        }
    }

    # Work out the quota request (if any) up front so the confirmation lists it.
    $quotaPlan = $null
    if ($sel.Eligible -eq 'QUOTA') {
        $selApp   = $appByRegion[$Location]
        $curLimit = if ($null -ne $selApp.SkuLimit) { [int]$selApp.SkuLimit } else { 0 }
        $curUsed  = if ($null -ne $selApp.SkuUsed)  { [int]$selApp.SkuUsed }  else { 0 }
        # +1 over the current limit, or enough to cover the instances needed, whichever is higher
        $quotaPlan = [pscustomobject]@{ Current = $curLimit; Used = $curUsed; New = [Math]::Max($curLimit + 1, $curUsed + $AppServiceInstances) }
    }

    # Confirmation gate: nothing has changed in the subscription up to this point.
    # The quota request and Phase 4 change the subscription, so require an explicit yes (or -Force).
    Write-Host ''
    Write-Host "About to deploy NMM:" -ForegroundColor Yellow
    Write-Host ("  Resource group : {0} (new)" -f $ResourceGroupName)
    Write-Host ("  Region         : {0} ({1})" -f $sel.DisplayName, $Location)
    Write-Host ("  NMM version    : {0}" -f $NmmVersion)
    Write-Host ("  App Service    : {0} x{1}    Azure SQL : {2}/{3}" -f $AppServiceSku, $AppServiceInstances, $SqlEdition, $SqlServiceObjective)
    if ($quotaPlan) {
        Write-Host ("  Quota request  : raise {0} quota in {1} from {2} to {3} (currently {4} used) -- submitted first" -f $AppServiceSku, $Location, $quotaPlan.Current, $quotaPlan.New, $quotaPlan.Used) -ForegroundColor Yellow
    }
    Write-Host ''
    if (-not (Read-YesNo -Prompt "Proceed? (creates billable Azure resources)" -DefaultYes $false)) {
        Write-Host "Deployment cancelled. No resources were created." -ForegroundColor Cyan
        Save-Report
        return
    }

    if ($quotaPlan) {
        $script:report.quotaRequest.requested = $true
        $script:report.quotaRequest.sku       = $AppServiceSku
        $script:report.quotaRequest.region    = $Location
        $script:report.quotaRequest.fromLimit = $quotaPlan.Current
        $script:report.quotaRequest.toLimit   = $quotaPlan.New

        Write-Host ("  Submitting {0} quota request ({1} -> {2})..." -f $AppServiceSku, $quotaPlan.Current, $quotaPlan.New) -ForegroundColor Cyan
        $qr = Request-AppServiceQuotaIncrease -Region $Location -Sub $subId -Sku $AppServiceSku `
                -NewLimit $quotaPlan.New -ApiVersion $quotaApiVersion
        $script:report.quotaRequest.ok      = [bool]$qr.Ok
        $script:report.quotaRequest.message = $qr.Message
        if ($qr.Ok) {
            Write-Host ("  Quota increased: {0} limit in {1} is now {2}." -f $AppServiceSku, $Location, $qr.Limit) -ForegroundColor Green
            if ($qr.Message) { Write-Host ("  Note: {0}" -f $qr.Message) -ForegroundColor Yellow }
        } else {
            Write-Host ("  Quota increase failed: {0}" -f $qr.Message) -ForegroundColor Red
            Write-Host ("  Manual option: Portal > Quotas > App Service > Region '{0}' > {1} VMs > pencil icon, or open a free 'Service and subscription limits (quotas)' support request." -f $sel.DisplayName, $AppServiceSku) -ForegroundColor Yellow
            if (-not $Force) {
                $go = Read-Host "Continue with deployment anyway? (it will likely fail) [y/N, B = back to region selection]"
                if ($go -match '^[Bb]') { $Regions = $null; $Geography = $null; continue }
                if ($go -notmatch '^[Yy]') {
                    Write-Host "Exiting without deploying." -ForegroundColor Yellow
                    Save-Report
                    return
                }
            }
        }
    }

    break   # region chosen, confirmed, and quota handled -> continue to deployment
}

# ====================================================================
#  Phase 4: Deployment
# ====================================================================
Write-Banner "Deploying NMM"
try {
    New-AzResourceGroup -Name $ResourceGroupName -Location $Location -ErrorAction Stop | Out-Null
    Write-Host ("Created resource group '{0}' in {1}." -f $ResourceGroupName, $Location) -ForegroundColor Green
} catch {
    Write-Host "Could not create resource group '$ResourceGroupName': $_" -ForegroundColor Red
    Save-Report
    return
}

# Accept the marketplace agreement for the managed application plan. Without
# this the deployment can fail with MarketplacePurchaseEligibilityFailed.
# (Managed app -> 'az term accept', not 'az vm image terms accept'.)
Write-Host "Accepting Azure Marketplace terms for nerdio/nmm/nmm-plan..." -ForegroundColor Cyan
$termsOutput = az term accept --publisher nerdio --product nmm --plan nmm-plan --only-show-errors 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "Marketplace terms accepted." -ForegroundColor Green
} else {
    Write-Warning ("Could not accept marketplace terms: {0}" -f ($termsOutput -join ' '))
    Write-Warning "If deployment fails with MarketplacePurchaseEligibilityFailed, the subscription type may not allow marketplace purchases (e.g. CSP/MSDN/sponsored), or a private marketplace policy may be blocking the publisher."
}

$SqlPassword    = New-StrongPassword -Length 20
$deploymentName = "nmm-deploy-$(Get-Date -Format 'yyyyMMddHHmmss')"
$script:report.deployment.name = $deploymentName

# Materialize the inline template to a temp file for the deployment (removed in
# the finally block below).
$templatePath = Join-Path ([System.IO.Path]::GetTempPath()) "nmm-template-$(Get-Random).json"
$nmmTemplateJson | Out-File -FilePath $templatePath -Encoding UTF8

$job = $null
try {
    $job = New-AzResourceGroupDeployment `
        -Name $deploymentName `
        -ResourceGroupName $ResourceGroupName `
        -TemplateFile $templatePath `
        -TemplateParameterObject @{ sqlServerPassword = $SqlPassword; packageVersion = $NmmVersion } `
        -AsJob -ErrorAction Stop
} catch {
    Write-Host "Could not start the deployment: $_" -ForegroundColor Red
}
if (-not $job) {
    Remove-Item $templatePath -ErrorAction SilentlyContinue
    Write-Host "Nothing was deployed. Delete the empty resource group '$ResourceGroupName' before re-running with the same name." -ForegroundColor Yellow
    $script:report.deployment.provisioningState = 'NotStarted'
    Save-Report
    return
}

Write-Host "Deployment '$deploymentName' started..." -ForegroundColor Cyan
$start = Get-Date
while ($job.State -in 'NotStarted', 'Running') {
    $elapsed = (Get-Date) - $start
    $d = Get-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -Name $deploymentName -ErrorAction SilentlyContinue
    $state = if ($d) { $d.ProvisioningState } else { 'Starting' }
    Write-Host ("`r[{0:hh\:mm\:ss}] {1}    " -f $elapsed, $state) -NoNewline
    Start-Sleep -Seconds 10
}
Write-Host ""

$deployOk = $false
try {
    $result = Receive-Job -Job $job -Wait -ErrorAction Stop | Select-Object -Last 1
    $script:report.deployment.provisioningState = "$($result.ProvisioningState)"
    if ($result.ProvisioningState -ne 'Succeeded') {
        throw "Deployment finished with state '$($result.ProvisioningState)'."
    }
    $deployOk = $true
    Write-Host "Deployment succeeded." -ForegroundColor Green
}
catch {
    Write-Host "Deployment failed: $_" -ForegroundColor Red
    $script:report.deployment.provisioningState = 'Failed'
    $failed = Get-AzResourceGroupDeploymentOperation -ResourceGroupName $ResourceGroupName `
        -DeploymentName $deploymentName -ErrorAction SilentlyContinue |
        Where-Object { $_.ProvisioningState -eq 'Failed' }
    if ($failed) {
        $failed | ForEach-Object {
            Write-Host "---"
            Write-Host "Resource: $($_.TargetResource)"
            Write-Host "Status:   $($_.StatusCode)"
            Write-Host "Message:  $($_.StatusMessage)"
        }
    } else {
        Write-Host "(No deployment record - failure occurred before submission to Azure.)"
    }

    # RoleAssignmentExists on the managed app has been tied to PIM-activated roles
    # used right after activation (stale session token / RBAC propagation lag).
    $failText = "$_ " + (($failed | ForEach-Object { $_.StatusMessage }) -join ' ')
    if ($failText -match 'RoleAssignmentExists') {
        Write-Host ''
        Write-Host "RoleAssignmentExists usually means the installing account's roles were not fully in effect:" -ForegroundColor Yellow
        Write-Host "  1. If Owner / Global Administrator come from PIM, re-activate them (or use a standing assignment)." -ForegroundColor Yellow
        Write-Host "  2. Restart Cloud Shell AFTER activation and wait ~10 minutes." -ForegroundColor Yellow
        Write-Host "  3. Delete the failed managed application + its managed resource group, then re-run with a NEW resource group name." -ForegroundColor Yellow
    }
}
finally {
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    Remove-Item $templatePath -ErrorAction SilentlyContinue
    Save-Report
}
if (-not $deployOk) {
    if ($JsonOut) { Write-Host ("JSON report: {0}" -f $JsonOut) -ForegroundColor Cyan }
    return
}

# ====================================================================
#  Phase 5: Post-install configuration
# ====================================================================
# Fetches a configuration script from Nerdio's maintenance endpoint (keyed to
# the NMM package version) and runs it against this install. The script
# version is pinned to $NmmVersion so it always matches the package deployed
# by the inline template (packageVersion).
Write-Banner "Phase 5: Post-Install Configuration"

# The managed app lives in $ResourceGroupName; its app components (incl. the
# web-admin-portal App Service) live in the derived managed resource group.
$app = Get-AzResource -ResourceGroupName $ResourceGroupName `
    -ResourceType 'Microsoft.Solutions/applications' -ExpandProperties -ErrorAction SilentlyContinue | Select-Object -First 1
$managedRg = if ($app) { ($app.Properties.managedResourceGroupId -split '/')[-1] }
$webapp = $null
if ($managedRg) {
    $webApps = @(Get-AzWebApp -ResourceGroupName $managedRg -ErrorAction SilentlyContinue)
    $webapp  = $webApps | Where-Object { $_.Name -like 'web-admin-portal-*' } | Select-Object -First 1
    if (-not $webapp) { $webapp = $webApps | Select-Object -First 1 }
}
if (-not $webapp) {
    Write-Host "Deployment succeeded, but the NMM admin portal web app wasn't found in managed resource group '$managedRg'." -ForegroundColor Red
    Write-Host "Open the managed application in the Azure portal to finish setup." -ForegroundColor Yellow
    Save-Report
    return
}
$url = "https://$($webapp.DefaultHostName)"
$script:report.deployment.webAppUrl = $url
Write-Host "Web app URL: $url" -ForegroundColor Cyan

# 502/503/504 mean App Service is still starting. NMM has returned 500 before
# post-install config runs, so 500 counts as up.
Write-Host "Waiting for web app to respond" -NoNewline
$ready   = $false
$timeout = (Get-Date).AddMinutes(20)
while ((Get-Date) -lt $timeout) {
    try {
        $r = Invoke-WebRequest -Uri $url -TimeoutSec 10 -SkipHttpErrorCheck -ErrorAction Stop
        if ($r.StatusCode -notin 502, 503, 504) { $ready = $true; break }
    } catch {}
    Write-Host "." -NoNewline
    Start-Sleep -Seconds 15
}
Write-Host ""
if ($ready) {
    Write-Host "Web app responded (HTTP $($r.StatusCode))." -ForegroundColor Green
} else {
    Write-Warning "Web app didn't respond within 20 minutes. Trying the post-install configuration anyway."
}

$maintUri  = "https://nmm-live-maintenance.azurewebsites.net/api/packages/$NmmVersion/script/install"
$maintBody = @{
    app   = $webapp.Name
    rg    = $managedRg
    subId = $subId
} | ConvertTo-Json -Compress

Write-Host ("Target app   : {0}" -f $webapp.Name) -ForegroundColor DarkGray
Write-Host ("Managed RG   : {0}" -f $managedRg)    -ForegroundColor DarkGray
Write-Host "Fetching and running NMM post-install configuration script..." -ForegroundColor Cyan
try {
    $maintScript = Invoke-RestMethod -Uri $maintUri -Method POST -Body $maintBody -ContentType 'application/json' -ErrorAction Stop
    & ([ScriptBlock]::Create($maintScript))
    Write-Host "Post-install configuration completed." -ForegroundColor Green
} catch {
    Write-Host "Post-install configuration failed: $_" -ForegroundColor Red
    Write-Host "Re-run it manually in Cloud Shell with the command below once the web app is reachable:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host ("& ([ScriptBlock]::Create((Invoke-RestMethod '{0}' -Method POST -Body '{1}' -ContentType 'application/json')))" -f $maintUri, $maintBody) -ForegroundColor Gray
    Write-Host ""
}

Save-Report
if ($JsonOut) { Write-Host ("JSON report: {0}" -f $JsonOut) -ForegroundColor Cyan }
