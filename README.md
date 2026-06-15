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

To check **specific regions only** (faster, useful when the partner has a preference):

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
Checks that all 13 providers required by NMM are registered in the subscription:

`Microsoft.KeyVault` · `Microsoft.Compute` · `Microsoft.Automation` · `Microsoft.Storage` · `Microsoft.Insights` · `Microsoft.OperationalInsights` · `Microsoft.DesktopVirtualization` · `Microsoft.Network` · `Microsoft.AAD` · `Microsoft.RecoveryServices` · `Microsoft.Web` · `Microsoft.Quota` · `Microsoft.Solutions`

Without `-RegisterProviders`, the script reports state only (read-only). With the flag it registers missing providers and polls until all reach **Registered** (default 15-minute timeout, configurable with `-ProviderTimeoutMinutes`).

### Phase 2 — Region Eligibility
Surfaces which Azure regions offer **both** resources the NMM Marketplace deployment needs:
- App Service Plan: Basic Medium (B2), Windows
- Azure SQL Database: Standard / S1 (20 DTU)

Outputs a ranked table and a plain-English recommendation the SE can read directly to the partner.

> **Note:** App Service availability reflects where the B2 SKU is *offered*, not live capacity. If a deploy hits a quota error in an eligible region, switch to another eligible region or open an Azure support ticket.

---

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `-Regions` | *(all)* | Comma-separated region slugs to limit the check (e.g. `eastus,westus2`) |
| `-SubscriptionId` | *(current context)* | Target a specific subscription |
| `-RegisterProviders` | *(off)* | Register any unregistered providers and poll to completion |
| `-ProviderTimeoutMinutes` | `15` | How long to wait for provider registration |
| `-AppServiceSku` | `B2` | App Service SKU to test |
| `-SqlEdition` | `Standard` | Azure SQL edition to test |
| `-SqlServiceObjective` | `S1` | Azure SQL service objective to test |
| `-OutFile` | *(none)* | Path to write a CSV of the full region results table |

---

## Requirements

- **Azure Cloud Shell** (PowerShell mode) — already authenticated, no setup needed
- Or: local PowerShell 5.1+ with [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) installed and `az login` completed
- Account needs `Owner` on the subscription and `Global Administrator` in Entra ID to run a full NMM install (Phase 0 will flag this if missing)
