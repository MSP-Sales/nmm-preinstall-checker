# NMM Pre-Install Readiness Checker

PowerShell script that catches the three most common blockers before a partner starts the Nerdio Manager for MSP (NMM) Azure Marketplace deployment wizard.

## Quick Start

Paste this single command into **Azure Cloud Shell (PowerShell mode)**:

```powershell
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/MSP-Sales/nmm-preinstall-checker/main/Check-NMMRegionEligibility.ps1')))
```

To also **register any missing resource providers automatically**, add the flag:

```powershell
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/MSP-Sales/nmm-preinstall-checker/main/Check-NMMRegionEligibility.ps1'))) -RegisterProviders
```

To check a **specific geography** (skips the interactive location prompt):

```powershell
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/MSP-Sales/nmm-preinstall-checker/main/Check-NMMRegionEligibility.ps1'))) -Geography US
```

To check **specific regions only** (useful when the partner has named a preference):

```powershell
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/MSP-Sales/nmm-preinstall-checker/main/Check-NMMRegionEligibility.ps1'))) -Regions eastus,eastus2,centralus,westus2
```

---

## What It Checks

### Phase 0 — Permissions
Verifies the signed-in account has both:
- **Subscription Owner** (required to register providers and complete the install)
- **Entra ID Global Administrator** (required for the NMM install itself)

Missing either will cause the install to fail. The script reports PASS / FAIL / UNKNOWN per check and calls out exactly what needs to be fixed before proceeding.

### Phase 1 — Resource Provider Registration
Checks that all 14 providers required by NMM are registered in the subscription:

`Microsoft.KeyVault` · `Microsoft.Compute` · `Microsoft.Automation` · `Microsoft.Storage` · `Microsoft.Insights` · `Microsoft.OperationalInsights` · `Microsoft.DesktopVirtualization` · `Microsoft.Network` · `Microsoft.AAD` · `Microsoft.RecoveryServices` · `Microsoft.Web` · `Microsoft.Quota` · `Microsoft.Solutions` · `Microsoft.Sql`

Without `-RegisterProviders`, the script reports state only (read-only). With the flag it registers missing providers and polls until all reach **Registered** (default 15-minute timeout, configurable with `-ProviderTimeoutMinutes`).

### Phase 2 — Region Eligibility
With no region arguments, the script **prompts for the partner's location** (US, Canada, Europe, etc.) so you don't need to know region slugs — pass `-Geography` or `-Regions` to skip the prompt. It then surfaces which Azure regions offer **both** resources the NMM Marketplace deployment needs:
- App Service Plan: Basic Medium (B2), Windows
- Azure SQL Database: Standard / S1 (20 DTU)

Outputs a ranked table and a plain-English recommendation the SE can read directly to the partner — plus a **"Why these regions were excluded"** section. The SQL check uses the `Microsoft.Sql` capabilities REST API, which returns the human-readable *reason* a region is blocked (e.g. provisioning restricted → open a quota support request). On PowerShell 7+ (Cloud Shell) the per-region checks run in parallel.

> **Availability ≠ quota:** "Eligible" means both SKUs are *offered* in the region, not that the subscription has quota headroom — App Service capacity has no public pre-check API. If a deploy hits a quota error in an eligible region, switch to another eligible region or open an Azure support request (issue type: "Service and subscription limits (quotas)").

---

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `-RegisterProviders` | *(off)* | Register any unregistered providers and poll to completion. The only switch that changes anything — otherwise the script is read-only. |
| `-ProviderTimeoutMinutes` | `15` | How long to wait for provider registration |
| `-Geography` | *(prompts)* | Limit the region check to one part of the world: `US`, `Canada`, `Mexico`, `NorthAmerica`, `Europe`, `UK`, `AsiaPacific`, `MiddleEast`, `Africa`, `SouthAmerica`, `All`. If omitted (and no `-Regions`), shows an interactive menu. |
| `-Regions` | *(geography/all)* | Comma-separated region slugs to limit the check (e.g. `eastus,westus2`). Overrides `-Geography`. |
| `-SubscriptionId` | *(current context)* | Target a specific subscription |
| `-AppServiceSku` | `B2` | App Service SKU to test |
| `-SqlEdition` | `Standard` | Azure SQL edition to test |
| `-SqlServiceObjective` | `S1` | Azure SQL service objective to test |
| `-OutFile` | *(none)* | Path to write a CSV of the full region results table |

---

## Requirements

- **Azure Cloud Shell** (PowerShell mode) — already authenticated, no setup needed
- Or: local PowerShell 5.1+ with [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) installed and `az login` completed
- Account needs `Owner` on the subscription and `Global Administrator` in Entra ID to run a full NMM install (Phase 0 will flag this if missing)
- The script is **read-only by default**; only `-RegisterProviders` makes changes (registering resource providers)
