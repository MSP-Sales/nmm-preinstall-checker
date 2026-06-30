#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ResourceGroupName,
    [string]$AppServiceSku       = 'B2',
    [string]$SqlEdition          = 'Standard',
    [string]$SqlServiceObjective = 'S1',
    [string[]]$Regions,
    [string]$Geography,
    [string]$SubscriptionId,
    [string]$OutFile,
    [switch]$RegisterProviders,
    [int]$ProviderTimeoutMinutes = 15,
    [string]$NmmVersion          = '6.8.0',
    [switch]$CheckOnly,
    [switch]$Force
)

$ErrorActionPreference = 'Continue'

# -CheckOnly runs the read-only readiness phases (0-2) and stops before any
# deployment. Outside CheckOnly mode a resource group name is required for the
# Phase 4 deploy; fail fast now rather than after the checks.
if (-not $CheckOnly -and [string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    throw "ResourceGroupName is required to deploy. Pass -ResourceGroupName <name>, or run with -CheckOnly to only run the readiness checks."
}

$NmmRequiredProviders = @(
    'Microsoft.KeyVault','Microsoft.Compute','Microsoft.Automation','Microsoft.Storage',
    'Microsoft.Insights','Microsoft.OperationalInsights','Microsoft.DesktopVirtualization',
    'Microsoft.Network','Microsoft.AAD','Microsoft.RecoveryServices','Microsoft.Web',
    'Microsoft.Quota','Microsoft.Solutions','Microsoft.Sql'
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

function Get-SqlRegionStatus {
    param(
        [string]$Region, [string]$Sub, [string]$Token,
        [string]$Edition, [string]$Slo, [string]$ApiVersion
    )
    $uri = "https://management.azure.com/subscriptions/$Sub/providers/Microsoft.Sql/locations/$Region/capabilities?api-version=$ApiVersion&include=supportedEditions"
    try {
        $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers @{ Authorization = "Bearer $Token" } -ErrorAction Stop
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
#  Pre-flight (az auth)
# ====================================================================
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI ('az') not found. Run in Cloud Shell or install the Azure CLI."
}
if ($SubscriptionId) { az account set --subscription $SubscriptionId --only-show-errors | Out-Null }

$ctx = az account show --only-show-errors 2>$null | ConvertFrom-Json
if (-not $ctx) { throw "Not logged in. Run 'az login' first." }
$subId = $ctx.id

$token = az account get-access-token --query accessToken -o tsv 2>$null
if (-not $token) { throw "Could not acquire Azure access token." }

Write-Banner "Nerdio Manager for MSP (NMM) - Pre-Install Readiness Check"
Write-Host ("Subscription : {0}" -f $ctx.name)
Write-Host ("Sub ID       : {0}" -f $ctx.id)
Write-Host ("NMM version  : {0}" -f $NmmVersion)
Write-Host ("Checking for : App Service '{0}'  +  Azure SQL '{1}/{2}'" -f $AppServiceSku, $SqlEdition, $SqlServiceObjective)
if ($Force) { Write-Host "-Force        : readiness gates will be bypassed." -ForegroundColor DarkYellow }
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
        $dirRoles = az rest --method GET `
            --url 'https://graph.microsoft.com/v1.0/me/transitiveMemberOf/microsoft.graph.directoryRole' `
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
    # Decide whether to register. The install deploys a managed application that
    # provisions resources across every provider above; an unregistered provider
    # causes a MissingSubscriptionRegistration failure partway through the nested
    # deployment, leaving a half-built managed resource group to clean up. So we
    # do NOT continue to deployment unless these are resolved.
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
        throw "Required providers are not registered. Aborting before deployment. Re-run with -RegisterProviders once resolved."
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

$apiVersion  = '2023-05-01-preview'
$candidates  = @($candidates)
$useParallel = ($PSVersionTable.PSVersion.Major -ge 7) -and ($candidates.Count -gt 3)

if ($useParallel) {
    $funcDef = ${function:Get-SqlRegionStatus}.ToString()
    $sqlResults = $candidates | ForEach-Object -Parallel {
        ${function:Get-SqlRegionStatus} = $using:funcDef
        Get-SqlRegionStatus -Region $_ -Sub $using:subId -Token $using:token `
            -Edition $using:SqlEdition -Slo $using:SqlServiceObjective -ApiVersion $using:apiVersion
    } -ThrottleLimit 15
} else {
    $sqlResults = New-Object System.Collections.Generic.List[object]
    $i = 0
    foreach ($slug in $candidates) {
        $i++
        Write-Progress -Activity "Checking SQL availability" -Status $slug -PercentComplete ([int](($i / $candidates.Count) * 100))
        $sqlResults.Add( (Get-SqlRegionStatus -Region $slug -Sub $subId -Token $token `
            -Edition $SqlEdition -Slo $SqlServiceObjective -ApiVersion $apiVersion) )
    }
    Write-Progress -Activity "Checking SQL availability" -Completed
}

$sqlByRegion = @{}
foreach ($s in $sqlResults) { $sqlByRegion[$s.Region] = $s }

$results = New-Object System.Collections.Generic.List[object]
foreach ($slug in $candidates) {
    $appOk     = $appSvcSlugs.Contains($slug)
    $sql       = $sqlByRegion[$slug]
    $sqlOk     = [bool]($sql -and $sql.Ok)
    $display   = if ($slugToName.ContainsKey($slug)) { $slugToName[$slug] } else { $slug }
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

if ($eligible.Count -eq 0) {
    Write-Host "No region offers BOTH App Service $AppServiceSku and SQL $SqlEdition/$SqlServiceObjective. Exiting." -ForegroundColor Red
    return
}

if ($CheckOnly) {
    Write-Host ''
    Write-Host ("Check-only mode: {0} eligible region(s) found. Stopping before deployment." -f $eligible.Count) -ForegroundColor Cyan
    Write-Host "Re-run with -ResourceGroupName <name> (and without -CheckOnly) to deploy." -ForegroundColor DarkGray
    return
}

# ====================================================================
#  Phase 3: Region picker
# ====================================================================
Write-Banner "Select a region for NMM deployment"
for ($i = 0; $i -lt $eligible.Count; $i++) {
    Write-Host ("  {0,2}. {1}  ({2})" -f ($i + 1), $eligible[$i].DisplayName, $eligible[$i].Region)
}
$pick = Read-Host "`nEnter choice [1]"
if ([string]::IsNullOrWhiteSpace($pick)) { $pick = '1' }
$idx = 0
if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $eligible.Count) {
    Write-Host "Invalid choice. Exiting." -ForegroundColor Red
    return
}
$Location = $eligible[$idx - 1].Region
Write-Host ("Selected: {0} ({1})" -f $eligible[$idx - 1].DisplayName, $Location) -ForegroundColor Green

# Confirmation gate: nothing has changed in the subscription up to this point.
# Phase 4 creates real resources, so require an explicit yes (or -Force).
Write-Host ''
Write-Host "About to deploy NMM:" -ForegroundColor Yellow
Write-Host ("  Resource group : {0}" -f $ResourceGroupName)
Write-Host ("  Region         : {0} ({1})" -f $eligible[$idx - 1].DisplayName, $Location)
Write-Host ("  NMM version    : {0}" -f $NmmVersion)
Write-Host ("  App Service    : {0}    Azure SQL : {1}/{2}" -f $AppServiceSku, $SqlEdition, $SqlServiceObjective)
Write-Host ''
if (-not (Read-YesNo -Prompt "Proceed with deployment? (creates billable Azure resources)" -DefaultYes $false)) {
    Write-Host "Deployment cancelled. No resources were created." -ForegroundColor Cyan
    return
}

# ====================================================================
#  Phase 4: Deployment
# ====================================================================
Write-Banner "Deploying NMM"
if (-not (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue)) {
    New-AzResourceGroup -Name $ResourceGroupName -Location $Location
}

$SqlPassword    = New-StrongPassword -Length 20
$deploymentName = "nmm-deploy-$(Get-Date -Format 'yyyyMMddHHmmss')"

$job = New-AzResourceGroupDeployment `
    -Name $deploymentName `
    -ResourceGroupName $ResourceGroupName `
    -TemplateFile .\template.json `
    -TemplateParameterObject @{ sqlServerPassword = $SqlPassword; packageVersion = $NmmVersion } `
    -AsJob

Write-Host "Deployment '$deploymentName' started..." -ForegroundColor Cyan
$start = Get-Date
while ($job.State -eq 'Running') {
    $elapsed = (Get-Date) - $start
    $d = Get-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -Name $deploymentName -ErrorAction SilentlyContinue
    $state = if ($d) { $d.ProvisioningState } else { 'Starting' }
    Write-Host ("`r[{0:hh\:mm\:ss}] {1}    " -f $elapsed, $state) -NoNewline
    Start-Sleep -Seconds 10
}
Write-Host ""

try {
    $result = Receive-Job -Job $job -Wait -ErrorAction Stop
    Write-Host "Deployment succeeded ($($result.ProvisioningState))." -ForegroundColor Green

    # The managed app lives in $ResourceGroupName; its app components (incl. the
    # web-admin-portal App Service) live in the derived managed resource group.
    $app = Get-AzResource -ResourceGroupName $ResourceGroupName `
        -ResourceType 'Microsoft.Solutions/applications' -ExpandProperties | Select-Object -First 1
    $managedRg = ($app.Properties.managedResourceGroupId -split '/')[-1]

    # Name-filter so we grab the admin portal even if the managed RG holds more
    # than one App Service; fall back to first web app if no match.
    $webapp = Get-AzWebApp -ResourceGroupName $managedRg |
        Where-Object { $_.Name -like 'web-admin-portal-*' } |
        Select-Object -First 1
    if (-not $webapp) {
        $webapp = Get-AzWebApp -ResourceGroupName $managedRg | Select-Object -First 1
    }
    $url = "https://$($webapp.DefaultHostName)"
    Write-Host "Web app URL: $url" -ForegroundColor Cyan

    Write-Host "Waiting for web app to respond" -NoNewline
    $webAppReady = $false
    $timeout = (Get-Date).AddMinutes(20)
    while ((Get-Date) -lt $timeout) {
        try {
            $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10 -SkipHttpErrorCheck -ErrorAction Stop
            Write-Host ""
            Write-Host "Web app responded (HTTP $($r.StatusCode))." -ForegroundColor Green
            $webAppReady = $true
            break
        } catch {
            Write-Host "." -NoNewline
            Start-Sleep -Seconds 15
        }
    }
    if (-not $webAppReady) { Write-Host "" }

    # ================================================================
    #  Phase 5: Post-install configuration
    # ================================================================
    # Fetches a configuration script from Nerdio's maintenance endpoint
    # (keyed to the NMM package version) and runs it against this install.
    # The script version is pinned to $NmmVersion so it always matches the
    # package deployed by template.json.
    Write-Banner "Phase 5: Post-Install Configuration"
    $maintUri  = "https://nmm-live-maintenance.azurewebsites.net/api/packages/$NmmVersion/script/install"
    $maintBody = @{
        app   = $webapp.Name
        rg    = $managedRg
        subId = $subId
    } | ConvertTo-Json -Compress

    if (-not $webAppReady) {
        Write-Warning "Web app did not confirm readiness within the timeout; attempting post-install config anyway."
    }

    Write-Host ("Target app   : {0}" -f $webapp.Name) -ForegroundColor DarkGray
    Write-Host ("Managed RG   : {0}" -f $managedRg)    -ForegroundColor DarkGray
    Write-Host "Fetching and running NMM post-install configuration script..." -ForegroundColor Cyan
    try {
        $maintScript = Invoke-RestMethod -Uri $maintUri -Method POST -Body $maintBody -ContentType 'application/json' -ErrorAction Stop
        & ([ScriptBlock]::Create($maintScript))
        Write-Host "Post-install configuration completed." -ForegroundColor Green
    } catch {
        Write-Host "Post-install configuration failed: $_" -ForegroundColor Red
        Write-Host "Re-run it manually with the command below once the web app is reachable:" -ForegroundColor Yellow
        Write-Host ""
        Write-Host ("& ([ScriptBlock]::Create((Invoke-RestMethod '{0}' -Method POST -Body '{1}' -ContentType 'application/json')))" -f $maintUri, $maintBody) -ForegroundColor Gray
        Write-Host ""
    }
}
catch {
    Write-Host "Deployment failed: $_" -ForegroundColor Red
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
}
finally {
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
}
