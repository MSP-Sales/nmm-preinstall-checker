#Requires -Version 5.1
<#
.SYNOPSIS
    Nerdio Manager for MSP (NMM) pre-install region eligibility checker.

.DESCRIPTION
    Surfaces the Azure regions that offer BOTH resources the NMM Azure Marketplace
    deployment needs, so an SE can tell a partner on a live call which regions are
    safe to pick in the deployment wizard:

        1. App Service Plan  : Basic Medium (B2), Windows  <- "Basic VM SKU app service quota" pain point
        2. Azure SQL Database: Standard tier / S1 (DTU)     <- "can't deploy managed SQL" pain point

    The script cross-references the two and prints a clean table plus a plain-English
    "these are the regions you could select" summary line. Optionally writes a CSV.

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

.EXAMPLE
    ./Check-NMMRegionEligibility.ps1
    Prompt for the partner's geography, then check those regions for B2 + Standard/S1.

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

    # When set, prompts to file Azure support tickets for SQL regions where the
    # capabilities API returns a provisioning restriction ("open a support request").
    # Requires a paid Azure support plan (Developer, Standard, or higher).
    [switch]$OpenTicket
)

# NOTE: deliberately NOT 'Stop'. The Azure CLI writes harmless warnings to stderr, and
# under 'Stop' PowerShell 5.1 promotes native stderr to a terminating error. Error handling
# here is explicit (throw / try-catch), which terminates regardless of this preference.
$ErrorActionPreference = 'Continue'

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

Write-Banner "Nerdio Manager for MSP (NMM) - Region Eligibility Check"
Write-Host ("Subscription : {0}" -f $ctx.name)
Write-Host ("Sub ID       : {0}" -f $ctx.id)
Write-Host ("Checking for : App Service '{0}'  +  Azure SQL '{1}/{2}'" -f $AppServiceSku, $SqlEdition, $SqlServiceObjective)
Write-Host ''

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
$sorted | Format-Table Region, DisplayName, AppService, SqlDb, Eligible -AutoSize

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

# --- 7. Support Ticket Filing (pass -OpenTicket to enable) ------------------
# Targets SQL-blocked regions where the capabilities API says to open a support
# request. One ticket per region (each restriction is subscription+region-specific).
# Runs in the partner's Cloud Shell / subscription context on their behalf.

$sqlTicketable = @($excluded | Where-Object {
    $_.SqlDb -eq 'No' -and $_.SqlReason -match 'support.?request|provisioning is restricted'
})

if (-not $OpenTicket) {
    if ($sqlTicketable.Count -gt 0) {
        Write-Host ''
        Write-Host ("TIP: {0} region(s) above have SQL provisioning restrictions that can be lifted via a support ticket." -f $sqlTicketable.Count) -ForegroundColor DarkYellow
        Write-Host "     Re-run with -OpenTicket to file them automatically from Cloud Shell." -ForegroundColor DarkYellow
    }
}
else {
    Write-Banner "Phase 3 — Support Ticket Filing"

    if ($sqlTicketable.Count -eq 0) {
        Write-Host ''
        Write-Host "  No SQL provisioning restrictions found — nothing to ticket." -ForegroundColor DarkGray
    }
    else {
        Write-Host ''
        Write-Host ("  {0} region(s) with SQL provisioning restrictions:" -f $sqlTicketable.Count) -ForegroundColor Yellow
        $sqlTicketable | ForEach-Object {
            Write-Host ("    • {0}  ({1})" -f $_.DisplayName, $_.Region) -ForegroundColor White
        }

        Write-Host ''
        $doTicket = 'n'
        try { $doTicket = Read-Host "  File support ticket(s) for these region(s)? (y/n)" -ErrorAction Stop } catch {}

        if ($doTicket -eq 'y') {
            # Collect partner contact info once; used for all tickets in this run.
            Write-Host ''
            Write-Host "  Partner contact information:" -ForegroundColor Cyan
            $cFirst = Read-Host "    First name"
            $cLast  = Read-Host "    Last name"
            $cEmail = Read-Host "    Email"
            $cTz    = ''
            try { $cTz = Read-Host "    Time zone [Pacific Standard Time]" -ErrorAction Stop } catch {}
            if ([string]::IsNullOrWhiteSpace($cTz)) { $cTz = 'Pacific Standard Time' }

            # Resolve support service + problem classification via the Azure Support REST API.
            # Uses the same bearer token already acquired for the SQL capabilities check —
            # no CLI extension required and no hardcoded GUIDs.
            $supportBase = 'https://management.azure.com'
            $supportVer  = '2020-04-01'
            $restHeaders = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }

            Write-Host ''
            Write-Host "  Resolving Azure support classification..." -ForegroundColor DarkGray
            $svc = $null
            $pc  = $null
            try {
                $svcsResp = Invoke-RestMethod -Method GET `
                    -Uri "$supportBase/providers/Microsoft.Support/services?api-version=$supportVer" `
                    -Headers $restHeaders -ErrorAction Stop
                $svc = $svcsResp.value | Where-Object { $_.properties.displayName -match 'Service and subscription limits' } | Select-Object -First 1
                if (-not $svc) {
                    $svc = $svcsResp.value | Where-Object { $_.properties.displayName -match 'SQL Database' -and $_.properties.displayName -notmatch 'Managed Instance' } | Select-Object -First 1
                }

                if ($svc) {
                    $pcsResp = Invoke-RestMethod -Method GET `
                        -Uri "$supportBase/providers/Microsoft.Support/services/$($svc.name)/problemClassifications?api-version=$supportVer" `
                        -Headers $restHeaders -ErrorAction Stop
                    # \bSQL\b avoids matching "MySQL", "PostgreSQL", etc.
                    $pc = $pcsResp.value | Where-Object { $_.properties.displayName -match '\bSQL\b' -and $_.properties.displayName -notmatch 'MySQL|PostgreSQL|MariaDB|Cosmos|Redis' } | Select-Object -First 1
                    if (-not $pc) {
                        $pc = $pcsResp.value | Where-Object { $_.properties.displayName -match 'quota|limit|provisioning|region' -and $_.properties.displayName -notmatch 'MySQL|PostgreSQL|MariaDB|Cosmos|Redis' } | Select-Object -First 1
                    }
                    if (-not $pc) { $pc = $pcsResp.value | Select-Object -First 1 }
                }
            }
            catch {
                Write-Warning ("  Could not resolve support classification: {0}" -f $_.Exception.Message)
            }

            if (-not $svc -or -not $pc) {
                Write-Host ''
                Write-Host "  Open tickets manually:" -ForegroundColor Yellow
                Write-Host "  Portal > Help + Support > New Support Request" -ForegroundColor White
                Write-Host "  Issue type : Service and subscription limits (quotas)" -ForegroundColor White
                Write-Host "  Service    : SQL Database" -ForegroundColor White
                Write-Host ("  Region(s)  : {0}" -f (($sqlTicketable | Select-Object -ExpandProperty DisplayName) -join ', ')) -ForegroundColor White
                Write-Host ("  Sub ID     : {0}" -f $subId) -ForegroundColor White
            }
            else {
                Write-Host ("  Classification : {0}" -f $pc.properties.displayName) -ForegroundColor DarkGray
                Write-Host ''

                foreach ($r in $sqlTicketable) {
                    $tName  = "nmm-sql-$($r.Region)-$(Get-Date -Format 'yyyyMMddHHmm')"
                    $tTitle = "SQL Standard S1 provisioning restricted: $($r.DisplayName)"
                    $tBody  = @"
Requesting lift of Azure SQL Standard S1 provisioning restriction for a Nerdio Manager for MSP (NMM) Azure Marketplace deployment.

Subscription : $subId
Region       : $($r.DisplayName) ($($r.Region))
API message  : $($r.SqlReason)

NMM requires an Azure SQL Database Standard S1 (20 DTU, non-Managed-Instance). The Microsoft.Sql/locations/capabilities API reports provisioning is restricted in $($r.DisplayName) for this subscription. Please lift the restriction or advise on expected availability.
"@
                    $ticketPayload = @{
                        properties = @{
                            serviceId               = $svc.id
                            problemClassificationId = $pc.id
                            title                   = $tTitle
                            description             = $tBody
                            severity                = 'minimal'
                            advancedDiagnosticConsent = 'Yes'
                            contactDetails          = @{
                                firstName                = $cFirst
                                lastName                 = $cLast
                                primaryEmailAddress      = $cEmail
                                preferredContactMethod   = 'email'
                                preferredSupportLanguage = 'en-US'
                                preferredTimeZone        = $cTz
                                country                  = 'USA'
                            }
                        }
                    } | ConvertTo-Json -Depth 10

                    Write-Host ("  Filing ticket for {0}..." -f $r.DisplayName) -ForegroundColor DarkGray
                    try {
                        $t = Invoke-RestMethod -Method PUT `
                            -Uri "$supportBase/subscriptions/$subId/providers/Microsoft.Support/supportTickets/$($tName)?api-version=$supportVer" `
                            -Headers $restHeaders -Body $ticketPayload -ErrorAction Stop

                        # PUT succeeded — report immediately; do not let a slow GET mask this.
                        Write-Host ("  [OK] {0}  (status: {1})" -f $t.name, $t.properties.status) -ForegroundColor Green
                        if ($t.properties.supportPlanDisplayName) {
                            Write-Host ("       Plan   : {0}" -f $t.properties.supportPlanDisplayName) -ForegroundColor DarkGray
                        }
                        Write-Host ("       Portal : https://portal.azure.com/#resource/subscriptions/$subId/providers/Microsoft.Support/supportTickets/$($t.name)") -ForegroundColor Cyan

                        # Best-effort verification — ticket propagation can exceed 4s; failure here is not a problem.
                        Start-Sleep -Seconds 5
                        try {
                            $verify = Invoke-RestMethod -Method GET `
                                -Uri "$supportBase/subscriptions/$subId/providers/Microsoft.Support/supportTickets/$($t.name)?api-version=$supportVer" `
                                -Headers $restHeaders -ErrorAction Stop
                            if ($verify.properties.status -and $verify.properties.status -ne $t.properties.status) {
                                Write-Host ("       Verified status: {0}" -f $verify.properties.status) -ForegroundColor DarkGray
                            }
                        }
                        catch {
                            Write-Host "       (Portal link may take a few minutes to activate)" -ForegroundColor DarkGray
                        }
                    }
                    catch {
                        $errMsg   = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
                        $reason   = if ($errMsg.error.message) { $errMsg.error.message } else { $_.Exception.Message }
                        Write-Warning ("  Ticket creation failed: {0}" -f $reason)
                        Write-Host   "  Fallback: Portal > Help + Support > New Support Request" -ForegroundColor Yellow
                    }
                }

                Write-Host ''
                Write-Host "  All support requests: https://portal.azure.com/#view/Microsoft_Azure_Support/HelpAndSupportBlade/~/manageSupportRequest" -ForegroundColor Cyan
            }
        }
    }
}
