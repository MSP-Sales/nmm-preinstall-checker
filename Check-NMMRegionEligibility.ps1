#Requires -Version 5.1
<#
.SYNOPSIS
    Nerdio Manager for MSP (NMM) pre-install readiness checker.

.DESCRIPTION
    Three-phase pre-install check to catch the most common NMM deployment blockers
    before the partner starts the Azure Marketplace wizard:

        Phase 0 - Permission check
            Verifies the signed-in account holds Subscription Owner AND Entra ID
            Global Administrator. Missing either will cause the install to fail.

        Phase 1 - Resource provider registration
            Reports the registration state of the 14 providers NMM requires.
            Pass -RegisterProviders to kick off registration automatically and
            poll until all reach "Registered".

        Phase 2 - Region eligibility
            Surfaces the Azure regions that offer BOTH resources the NMM Azure
            Marketplace deployment needs, so an SE can tell a partner on a live call
            which regions are safe to pick in the deployment wizard:

                1. App Service Plan  : Basic Medium (B2), Windows  <- "Basic VM SKU app service quota" pain point
                2. Azure SQL Database: Standard tier / S1 (DTU)     <- "can't deploy managed SQL" pain point

            The script cross-references the two and prints a clean table plus a
            plain-English "these are the regions you could select" summary line,
            and explains why each excluded region was rejected. Optionally writes a CSV.

    AVAILABILITY vs. QUOTA -- READ THIS:
    This tool reports whether each SKU is AVAILABLE / OFFERED to the subscription in a
    region. It does NOT (and cannot) confirm the subscription has the QUOTA HEADROOM to
    actually provision it. The Azure Quota API (Microsoft.Quota) does not cover App
    Service (Microsoft.Web) or Azure SQL, so live quota for these two resources cannot be
    pre-checked via any public API -- it is only enforced at deploy time and raised via a
    support request. So "Eligible" here means "both SKUs are available in the region," not
    "guaranteed to deploy." If a deploy fails on a quota/capacity error in an Eligible
    region, either pick another Eligible region or open an Azure support request
    (issue type: "Service and subscription limits (quotas)") for that region.

.PARAMETER Geography
    Optional. Limits the check to one geography so you don't have to know region slugs.
    Accepts: US, Canada, NorthAmerica, Europe, UK, AsiaPacific, MiddleEast, Africa,
    SouthAmerica, All. If neither -Geography nor -Regions is supplied and the session is
    interactive, the script prompts with a menu ("Where is the partner located?").

.PARAMETER AppServiceSku
    App Service plan SKU to test. Default B2 (NMM default, Windows). Accepts B1, B2, B3, S1, etc.

.PARAMETER SqlEdition
    Azure SQL Database edition/tier to test. Default Standard (NMM default).

.PARAMETER SqlServiceObjective
    SQL service objective (performance level) to test. Default S1 (NMM default, 20 DTU).

.PARAMETER Regions
    Optional shortlist of region slugs (e.g. eastus,westus2,westeurope) to limit the check.
    Faster, and lets you answer "why can't we use <region the partner asked for>?" because
    requested regions are checked for BOTH gates even if App Service excludes them.
    If omitted, the script checks every region that offers the App Service SKU.

.PARAMETER SubscriptionId
    Optional subscription to target. Defaults to the current `az` context.

.PARAMETER OutFile
    Optional path to write a CSV of the full result table.

.PARAMETER RegisterProviders
    When set, Phase 1 automatically registers any unregistered required providers and
    polls until they all reach "Registered" (or ProviderTimeoutMinutes is hit). Without
    this switch Phase 1 reports provider state but makes no changes.

.PARAMETER ProviderTimeoutMinutes
    How long Phase 1 waits for provider registration to complete. Default 15.

.EXAMPLE
    ./Check-NMMRegionEligibility.ps1
    Run all three phases; prompt for the partner's geography for the Phase 2 region check.

.EXAMPLE
    ./Check-NMMRegionEligibility.ps1 -RegisterProviders
    Also register any missing providers automatically during Phase 1.

.EXAMPLE
    ./Check-NMMRegionEligibility.ps1 -Geography US
    Check only US regions (no prompt) -- ideal when the partner just says "we're in the US."

.EXAMPLE
    ./Check-NMMRegionEligibility.ps1 -Regions eastus,eastus2,centralus,westus2 -OutFile result.csv
    Only check the partner's named regions and save a CSV.

.NOTES
    Run in Azure Cloud Shell (PowerShell mode) -- already authenticated -- or in local
    PowerShell with Azure CLI installed and `az login` completed.

    SQL availability comes from the Microsoft.Sql locations/capabilities REST API, which
    also returns the human-readable REASON a region is blocked (e.g. provisioning
    restricted -> open a quota support request). On PowerShell 7+ (Cloud Shell) the
    per-region SQL checks run in parallel; Windows PowerShell 5.1 runs them sequentially.
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
    [int]$ProviderTimeoutMinutes = 15
)

# NOTE: deliberately NOT 'Stop'. The Azure CLI writes harmless warnings to stderr, and
# under 'Stop' PowerShell 5.1 promotes native stderr to a terminating error. Error handling
# here is explicit (throw / try-catch), which terminates regardless of this preference.
$ErrorActionPreference = 'Continue'

$NmmRequiredProviders = @(
    'Microsoft.KeyVault',
    'Microsoft.Compute',
    'Microsoft.Automation',
    'Microsoft.Storage',
    'Microsoft.Insights',
    'Microsoft.OperationalInsights',
    'Microsoft.DesktopVirtualization',
    'Microsoft.Network',
    'Microsoft.AAD',
    'Microsoft.RecoveryServices',
    'Microsoft.Web',
    'Microsoft.Quota',
    'Microsoft.Solutions',
    'Microsoft.Sql'
)

function Write-Banner {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
}

function Get-SqlRegionStatus {
    # Queries the Microsoft.Sql capabilities API for one region and returns whether the
    # requested edition/SLO can be provisioned -- plus the human-readable REASON when it
    # can't (e.g. "Provisioning is restricted in this region..."). Pure/self-contained so
    # it can be reused inside ForEach-Object -Parallel. Returns: Region, Ok, Reason.
    param(
        [string]$Region, [string]$Sub, [string]$Token,
        [string]$Edition, [string]$Slo, [string]$ApiVersion
    )
    $uri = "https://management.azure.com/subscriptions/$Sub/providers/Microsoft.Sql/locations/$Region/capabilities?api-version=$ApiVersion&include=supportedEditions"
    try {
        $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers @{ Authorization = "Bearer $Token" } -ErrorAction Stop

        # A populated reason means provisioning is restricted/blocked for this subscription.
        $reason = $resp.supportedServerVersions.reason | Where-Object { $_ } | Select-Object -First 1
        if ($reason) { $reason = ($reason -replace '\s+', ' ').Trim() }

        # Is the requested edition + service objective actually offered here?
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

        if ($reason) {
            return [pscustomobject]@{ Region = $Region; Ok = $false; Reason = $reason }
        }
        elseif ($sloListed) {
            return [pscustomobject]@{ Region = $Region; Ok = $true;  Reason = '' }
        }
        else {
            return [pscustomobject]@{ Region = $Region; Ok = $false; Reason = "$Edition/$Slo is not offered in this region" }
        }
    }
    catch {
        return [pscustomobject]@{ Region = $Region; Ok = $false; Reason = "SQL capabilities API error: $($_.Exception.Message)" }
    }
}

# --- 0. Pre-flight: az present + authenticated -----------------------------
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI ('az') not found. Run this in Azure Cloud Shell, or install the Azure CLI locally."
}

if ($SubscriptionId) {
    az account set --subscription $SubscriptionId --only-show-errors | Out-Null
}

$ctx = az account show --only-show-errors 2>$null | ConvertFrom-Json
if (-not $ctx) {
    throw "Not logged in to Azure. Run 'az login' (not needed in Cloud Shell) and try again."
}
$subId = $ctx.id

# ARM bearer token for the SQL capabilities REST API (gives the per-region "reason").
$token = az account get-access-token --query accessToken -o tsv 2>$null
if (-not $token) {
    throw "Could not acquire an Azure access token ('az account get-access-token' failed)."
}

Write-Banner "Nerdio Manager for MSP (NMM) - Pre-Install Readiness Check"
Write-Host ("Subscription : {0}" -f $ctx.name)
Write-Host ("Sub ID       : {0}" -f $ctx.id)
Write-Host ("Checking for : App Service '{0}'  +  Azure SQL '{1}/{2}'" -f $AppServiceSku, $SqlEdition, $SqlServiceObjective)
Write-Host ''

# --- Phase 0: Permission check (Owner + Global Administrator) ---------------
Write-Banner "Phase 0: Permission Check"

$me = az ad signed-in-user show --only-show-errors 2>$null | ConvertFrom-Json
if (-not $me) {
    Write-Warning "Could not retrieve signed-in user info -- permission check skipped. Ensure 'az login' is complete."
} else {
    Write-Host ("Signed-in user : {0}  ({1})" -f $me.displayName, $me.userPrincipalName)
    Write-Host ''

    # Owner on the subscription -- direct, group-inherited, and parent-scope (management group) assignments
    $ownerAssignments = az role assignment list `
        --assignee $me.id `
        --role Owner `
        --scope "/subscriptions/$($ctx.id)" `
        --include-groups `
        --include-inherited `
        --only-show-errors 2>$null | ConvertFrom-Json
    $isOwner = ($null -ne $ownerAssignments -and @($ownerAssignments).Count -gt 0)

    # Global Administrator in Entra ID via Microsoft Graph.
    # Role template ID 62e90394-... is the well-known GUID for Global Administrator across all tenants.
    $isGA   = $null   # $null = check indeterminate; $true/$false = definitive
    $gaNote = ''
    try {
        $GA_TEMPLATE_ID = '62e90394-69f5-4237-9190-012177145e10'
        $dirRoles = az rest --method GET `
            --url 'https://graph.microsoft.com/v1.0/me/transitiveMemberOf/microsoft.graph.directoryRole' `
            --only-show-errors 2>$null | ConvertFrom-Json
        if ($dirRoles -and $dirRoles.PSObject.Properties['value']) {
            $isGA = [bool]($dirRoles.value | Where-Object { $_.roleTemplateId -eq $GA_TEMPLATE_ID })
        } else {
            $gaNote = ' (no directory roles returned)'
        }
    } catch {
        $gaNote = ' (Graph API check failed -- verify manually)'
    }

    $ownerLabel = if ($isOwner) { 'PASS' } else { 'FAIL' }
    $gaLabel    = if ($null -eq $isGA) { "UNKNOWN$gaNote" } elseif ($isGA) { 'PASS' } else { 'FAIL' }
    $ownerColor = if ($isOwner) { 'Green' } else { 'Red' }
    $gaColor    = if ($null -eq $isGA) { 'Yellow' } elseif ($isGA) { 'Green' } else { 'Red' }

    "{0,-55} {1}" -f "  Subscription Owner", $ownerLabel | Write-Host -ForegroundColor $ownerColor
    "{0,-55} {1}" -f "  Entra ID Global Administrator", $gaLabel | Write-Host -ForegroundColor $gaColor
    Write-Host ''

    $permFail = (-not $isOwner) -or ($isGA -eq $false)
    if ($permFail) {
        Write-Host '  ACTION REQUIRED: Missing permissions will cause the NMM install to fail.' -ForegroundColor Red
        if (-not $isOwner) {
            Write-Host ("  -> Assign Owner on subscription '{0}' before registering providers or installing NMM." -f $ctx.name) -ForegroundColor Red
        }
        if ($isGA -eq $false) {
            Write-Host '  -> Assign Global Administrator in Entra ID before running the NMM install.' -ForegroundColor Red
        }
        Write-Host '  (Continuing with remaining checks for informational purposes...)' -ForegroundColor DarkGray
    } else {
        Write-Host '  All required permissions confirmed.' -ForegroundColor Green
    }
}
Write-Host ''

# --- Phase 1: Resource provider registration --------------------------------
Write-Banner "Phase 1: Resource Provider Registration"
Write-Host ("Checking {0} required providers..." -f $NmmRequiredProviders.Count) -ForegroundColor DarkGray
Write-Host ''

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
} elseif ($RegisterProviders) {
    Write-Host ("Registering {0} provider(s)..." -f $unregistered.Count) -ForegroundColor Yellow
    foreach ($p in $unregistered) {
        Write-Host ("  {0}: {1} -> registering..." -f $p.Provider, $p.State) -ForegroundColor Yellow
        az provider register --namespace $p.Provider --output none --only-show-errors
    }

    Write-Host ''
    Write-Host ("Polling until all providers reach 'Registered' (timeout: {0}m)..." -f $ProviderTimeoutMinutes)
    $deadline = (Get-Date).AddMinutes($ProviderTimeoutMinutes)
    do {
        Start-Sleep -Seconds 15
        $pending = [System.Collections.Generic.List[string]]::new()
        foreach ($ns in $NmmRequiredProviders) {
            $state = az provider show --namespace $ns --query registrationState --output tsv --only-show-errors 2>$null
            if ($state -and $state -ne 'Registered') { $pending.Add("$ns ($state)") }
        }
        if ($pending.Count -gt 0) {
            Write-Host ("  Still pending: {0}" -f ($pending -join ', '))
        }
    } while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline)

    if ($pending.Count -gt 0) {
        Write-Warning ("Some providers did not finish within {0} minutes. Re-run before attempting the NMM install." -f $ProviderTimeoutMinutes)
    } else {
        Write-Host 'All providers are now Registered.' -ForegroundColor Green
    }
} else {
    Write-Host ("{0} provider(s) are not registered:" -f $unregistered.Count) -ForegroundColor Yellow
    foreach ($p in $unregistered) {
        Write-Host ("  - {0}  ({1})" -f $p.Provider, $p.State) -ForegroundColor Yellow
    }
    Write-Host ''
    Write-Host 'Re-run with -RegisterProviders to register them automatically.' -ForegroundColor Yellow
    Write-Host '(Continuing with region check...)' -ForegroundColor DarkGray
}
Write-Host ''

# --- Phase 2: Region eligibility --------------------------------------------
Write-Banner "Phase 2: Region Eligibility"

# --- 1. Authoritative region map (displayName -> slug) ----------------------
Write-Host "Loading Azure region list..." -ForegroundColor DarkGray
$allLocations = az account list-locations --only-show-errors 2>$null | ConvertFrom-Json
$physical     = $allLocations | Where-Object { $_.metadata.regionType -eq 'Physical' }

# displayName ("East US") -> slug ("eastus")
$nameToSlug = @{}
foreach ($loc in $physical) { $nameToSlug[$loc.displayName] = $loc.name }
# slug -> displayName, for friendly output
$slugToName = @{}
foreach ($loc in $physical) { $slugToName[$loc.name] = $loc.displayName }
# slug -> Azure geographyGroup ("US", "Europe", "Asia Pacific", ...)
$slugToGeo = @{}
foreach ($loc in $physical) { $slugToGeo[$loc.name] = $loc.metadata.geographyGroup }

function Resolve-Slug {
    param([string]$DisplayName)
    if ($nameToSlug.ContainsKey($DisplayName)) { return $nameToSlug[$DisplayName] }
    # fallback: normalize "West US 2" -> "westus2"
    return ($DisplayName -replace '\s', '').ToLower()
}

# Friendly geography choice -> set of Azure geographyGroup values.
# $null means "all regions" (no filter).
$geoMenu = [ordered]@{
    'United States'                     = @('US')
    'Canada'                            = @('Canada')
    'North America (US + Canada + Mexico)' = @('US', 'Canada', 'Mexico')
    'Europe (incl. UK)'                 = @('Europe', 'UK')
    'United Kingdom'                    = @('UK')
    'Asia Pacific'                      = @('Asia Pacific')
    'Middle East'                       = @('Middle East')
    'Africa'                            = @('Africa')
    'South America'                     = @('South America')
    'All regions'                       = $null
}

function Resolve-Geography {
    # Maps a -Geography token (spaces/case-insensitive) to a set of geographyGroup values.
    param([string]$Token)
    switch -Regex (($Token -replace '\s', '').ToLower()) {
        '^(us|usa|unitedstates)$'              { return @('US') }
        '^canada$'                             { return @('Canada') }
        '^(northamerica|na)$'                  { return @('US', 'Canada', 'Mexico') }
        '^(europe|eu)$'                        { return @('Europe', 'UK') }
        '^(uk|unitedkingdom)$'                 { return @('UK') }
        '^(asiapacific|apac|asia)$'            { return @('Asia Pacific') }
        '^(middleeast|me)$'                    { return @('Middle East') }
        '^africa$'                             { return @('Africa') }
        '^(southamerica|latam|latinamerica)$'  { return @('South America') }
        '^(mexico|mx)$'                        { return @('Mexico') }
        '^all$'                                { return $null }
        default {
            throw "Unrecognized -Geography '$Token'. Use one of: US, Canada, NorthAmerica, Europe, UK, AsiaPacific, MiddleEast, Africa, SouthAmerica, Mexico, All."
        }
    }
}

function Show-GeographyPrompt {
    # Interactive numbered menu. Returns a set of geographyGroup values, or $null for all.
    Write-Host ''
    Write-Host "Where is the partner / MSP located? (filters which regions to check)" -ForegroundColor Cyan
    $labels = @($geoMenu.Keys)
    for ($n = 0; $n -lt $labels.Count; $n++) {
        Write-Host ("  {0,2}. {1}" -f ($n + 1), $labels[$n])
    }
    try {
        $pick = Read-Host "Enter choice [1]" -ErrorAction Stop
    }
    catch {
        # Non-interactive host (no console for input): don't guess a geography, scan everything.
        Write-Host "(no interactive input available -- scanning all regions; pass -Geography to filter)" -ForegroundColor Yellow
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($pick)) { $pick = '1' }
    $idx = 0
    if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $labels.Count) {
        Write-Host "Invalid choice; defaulting to United States." -ForegroundColor Yellow
        $idx = 1
    }
    return $geoMenu[$labels[$idx - 1]]
}

# --- 2. App Service regions (Windows; no --linux-workers-enabled flag) ------
Write-Host ("Querying App Service regions that offer the '{0}' SKU..." -f $AppServiceSku) -ForegroundColor DarkGray
$appSvcRaw   = az appservice list-locations --sku $AppServiceSku --only-show-errors 2>$null | ConvertFrom-Json
$appSvcSlugs = [System.Collections.Generic.HashSet[string]]::new()
foreach ($r in $appSvcRaw) { [void]$appSvcSlugs.Add( (Resolve-Slug $r.name) ) }
Write-Host ("  -> {0} regions offer App Service {1}." -f $appSvcSlugs.Count, $AppServiceSku) -ForegroundColor DarkGray

# --- 3. Determine candidate regions to evaluate -----------------------------
# Precedence: explicit -Regions  >  -Geography  >  interactive prompt  >  all regions.
if ($Regions) {
    $candidates = $Regions | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ }
    Write-Host ("Limiting check to {0} requested region(s)." -f $candidates.Count) -ForegroundColor DarkGray
}
else {
    $geoGroups = $null      # $null = no filter (all regions)
    $geoLabel  = 'All regions'
    if ($Geography) {
        $geoGroups = Resolve-Geography $Geography
        $geoLabel  = $Geography
    }
    elseif ([Environment]::UserInteractive) {
        $geoGroups = Show-GeographyPrompt
        $geoLabel  = if ($null -eq $geoGroups) { 'All regions' } else { ($geoGroups -join ', ') }
    }

    # A region must offer the App Service SKU to be worth a SQL call; then filter by geography.
    $candidates = @($appSvcSlugs)
    if ($null -ne $geoGroups) {
        $candidates = $candidates | Where-Object { $geoGroups -contains $slugToGeo[$_] }
    }
    $candidates = $candidates | Sort-Object
    Write-Host ''
    Write-Host ("Checking {0} region(s) in '{1}' for SQL {2}/{3} availability..." -f $candidates.Count, $geoLabel, $SqlEdition, $SqlServiceObjective) -ForegroundColor DarkGray
}

if (-not $candidates -or @($candidates).Count -eq 0) {
    Write-Host ''
    Write-Host "No candidate regions to check (none offer App Service $AppServiceSku in the selected geography)." -ForegroundColor Yellow
    return
}

# --- 4. Evaluate SQL availability per candidate (capabilities API) ----------
# PowerShell 7+ (Azure Cloud Shell) runs the per-region calls in parallel; Windows
# PowerShell 5.1 falls back to a sequential loop with a progress bar.
$apiVersion  = '2023-05-01-preview'
$candidates  = @($candidates)
$useParallel = ($PSVersionTable.PSVersion.Major -ge 7) -and ($candidates.Count -gt 3)

if ($useParallel) {
    Write-Host ("  (running {0} SQL checks in parallel)" -f $candidates.Count) -ForegroundColor DarkGray
    $funcDef = ${function:Get-SqlRegionStatus}.ToString()
    $sqlResults = $candidates | ForEach-Object -Parallel {
        ${function:Get-SqlRegionStatus} = $using:funcDef
        Get-SqlRegionStatus -Region $_ -Sub $using:subId -Token $using:token `
            -Edition $using:SqlEdition -Slo $using:SqlServiceObjective -ApiVersion $using:apiVersion
    } -ThrottleLimit 15
}
else {
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

# Index SQL results by region, then merge with App Service availability.
$sqlByRegion = @{}
foreach ($s in $sqlResults) { $sqlByRegion[$s.Region] = $s }

$results = New-Object System.Collections.Generic.List[object]
foreach ($slug in $candidates) {
    $appOk     = $appSvcSlugs.Contains($slug)
    $sql       = $sqlByRegion[$slug]
    $sqlOk     = [bool]($sql -and $sql.Ok)
    $sqlReason = if ($sql) { $sql.Reason } else { 'no SQL result returned' }
    $display   = if ($slugToName.ContainsKey($slug)) { $slugToName[$slug] } else { $slug }

    $results.Add([pscustomobject]@{
        Region           = $slug
        DisplayName      = $display
        AppService       = if ($appOk) { 'Yes' } else { 'No' }
        SqlDb            = if ($sqlOk) { 'Yes' } else { 'No' }
        Eligible         = if ($appOk -and $sqlOk) { 'YES' } else { 'no' }
        SqlReason        = if ($sqlOk) { '' } else { $sqlReason }
        AppServiceReason = if ($appOk) { '' } else { "App Service $AppServiceSku not offered in this region" }
    })
}

# --- 5. Output --------------------------------------------------------------
$sorted   = $results | Sort-Object @{E={$_.Eligible -eq 'YES'};Descending=$true}, DisplayName
# @() forces array context -- a single Where-Object result is a scalar whose .Count is $null.
$eligible = @($sorted | Where-Object { $_.Eligible -eq 'YES' })

Write-Banner "Results"
$sorted | Format-Table Region, DisplayName, AppService, SqlDb, Eligible -AutoSize | Out-Host

Write-Banner "RECOMMENDATION"
if ($eligible.Count -gt 0) {
    Write-Host "Based on what we found, these are the regions you could select for the" -ForegroundColor Green
    Write-Host "NMM deployment (App Service $AppServiceSku + Azure SQL $SqlEdition/$SqlServiceObjective both available):" -ForegroundColor Green
    Write-Host ''
    $eligible | ForEach-Object { Write-Host ("   - {0}  ({1})" -f $_.DisplayName, $_.Region) -ForegroundColor Green }
}
else {
    Write-Host "No checked region offers BOTH App Service $AppServiceSku and SQL $SqlEdition/$SqlServiceObjective." -ForegroundColor Yellow
    Write-Host "Widen the search (try -Geography All) or consider a different App Service SKU / SQL tier." -ForegroundColor Yellow
}

# Explain the excluded regions (the SQL reason is the partner-facing "why").
$excluded = @($sorted | Where-Object { $_.Eligible -ne 'YES' })
if ($excluded.Count -gt 0) {
    Write-Banner "Why these regions were excluded"
    foreach ($x in $excluded) {
        Write-Host ("  {0} ({1})" -f $x.DisplayName, $x.Region) -ForegroundColor Yellow
        if ($x.AppService -eq 'No') { Write-Host ("      App Service : {0}" -f $x.AppServiceReason) -ForegroundColor DarkGray }
        if ($x.SqlDb -eq 'No')      { Write-Host ("      SQL         : {0}" -f $x.SqlReason)        -ForegroundColor DarkGray }
    }
}

Write-Host ''
Write-Host "AVAILABILITY, NOT QUOTA: 'Eligible' means both SKUs are AVAILABLE to provision in the region." -ForegroundColor DarkGray
Write-Host "For SQL, blocked regions show the reason above (usually a subscription/region provisioning" -ForegroundColor DarkGray
Write-Host "restriction -- lifted via a quota support request). App Service capacity has NO public pre-check" -ForegroundColor DarkGray
Write-Host "API, so it can still fail at deploy time even in an Eligible region. Either way: if a deploy fails" -ForegroundColor DarkGray
Write-Host "on quota/capacity, pick another Eligible region or open an Azure support request (issue type:" -ForegroundColor DarkGray
Write-Host "'Service and subscription limits (quotas)') for that region." -ForegroundColor DarkGray

# --- 6. Optional CSV --------------------------------------------------------
if ($OutFile) {
    $sorted | Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8
    Write-Host ''
    Write-Host ("Full result table written to: {0}" -f $OutFile) -ForegroundColor Cyan
}
