# NMM Install Pre-Flight

Scripts that de-risk a **Nerdio Manager for MSP (NMM)** Azure deployment: confirm the subscription is ready, pick a region that will actually take the install, surface policy blockers, and (optionally) run the deployment end to end.

Two scripts live here:

| Script | Cloud | What it does |
|---|---|---|
| **`preinstall_install.ps1`** | Commercial | **End-to-end installer, single self-contained file.** Readiness checks (Phases 0-2), advisory policy-deny check + `-PolicyProbe`, region picker, ARM deployment, and post-install configuration. Use `-CheckOnly` to run the readiness checks and stop before any deployment. |
| `Check-NMMPreinstall-Gov.ps1` | Azure Government (GCC-H) | Readiness checks for gov tenants (Phases 0-2) plus the same policy-deny check + `-PolicyProbe`. CLI-only — no Az PowerShell module needed. Read-only; **no deployment phase yet** (there's no ARM template for a gov NMM install). |

---

## ⚠️ Run it in the *partner's* subscription

Region availability and App Service / SQL quota are **per-subscription**. The only result that matters is the one from the tenant where NMM is actually being installed. Run this in the **partner's** Azure Cloud Shell (screen-share and dictate the one-liner), not your own.

---

## Quick Start — installer (commercial)

`preinstall_install.ps1` is now a **single self-contained file** — the ARM template is embedded, so there's nothing else to download. Open Cloud Shell at <https://shell.azure.com> (or the `>_` icon in the Azure portal), make sure it's in **PowerShell** mode, and paste:

### Check only (read-only — safe to run anytime)

Runs Phases 0-2 plus the advisory policy-deny check and stops before any deployment. Nothing in the subscription changes.

```powershell
irm https://raw.githubusercontent.com/MSP-Sales/nmm-preinstall-checker/main/preinstall_install.ps1 -OutFile preinstall_install.ps1
./preinstall_install.ps1 -CheckOnly
```

### Check + install (deploys NMM)

Runs the checks, lets you pick an eligible region, **asks for confirmation**, then deploys and runs post-install configuration. Requires `-ResourceGroupName`.

```powershell
irm https://raw.githubusercontent.com/MSP-Sales/nmm-preinstall-checker/main/preinstall_install.ps1 -OutFile preinstall_install.ps1
./preinstall_install.ps1 -ResourceGroupName nmm-rg
```

> **Nothing deploys until you confirm.** After you pick a region the script prints exactly what it's about to create (resource group, region, NMM version, SKUs) and waits for a yes. Cancel and no resources are created. Pass `-Force` to skip the prompt for unattended runs.

> First-time Cloud Shell users get a one-time "set up storage" prompt (~30s) — or pick the ephemeral/no-storage session. Either works.

### Machine-readable output

Add `-JsonOut <path>` to any run to write a full structured report (permissions, providers, per-region eligibility, policy findings, deployment result) for tickets or automation. Written even on early exit.

```powershell
./preinstall_install.ps1 -CheckOnly -JsonOut ./nmm-readiness.json
```

---

## 🏛️ GCC-H / Azure Government

For **Azure Government (GCC-H)** partners, use `Check-NMMPreinstall-Gov.ps1`. It runs the same readiness phases (permissions, providers, region eligibility, policy deny check) and reads the ARM and Graph API endpoints from `az cloud show` at runtime so the bearer-token audience always matches the gov endpoints. There is **no deployment phase** for gov yet — there's no ARM template for a gov NMM install — so it confirms readiness and surfaces policy blockers so you know which region to target.

Open Cloud Shell at <https://shell.azure.us> (**PowerShell** mode) and paste:

```powershell
irm https://raw.githubusercontent.com/MSP-Sales/nmm-preinstall-checker/main/Check-NMMPreinstall-Gov.ps1 -OutFile nmm-gov.ps1; ./nmm-gov.ps1 -Regions usgovvirginia,usgovtexas,usgovarizona
```

Add `-PolicyProbe` to also run the ground-truth check (creates + deletes representative resources in the first eligible region):

```powershell
./nmm-gov.ps1 -Regions usgovvirginia,usgovtexas,usgovarizona -PolicyProbe
```

> **Check the cloud context first.** Being signed into portal.azure.us does **not** set the `az` CLI cloud. Run `az cloud show --query name -o tsv` — if it returns `AzureCloud` (commercial), run `az cloud set --name AzureUSGovernment && az login` before the script. The script also detects this and warns you. All three gov regions (Arizona, Texas, Virginia) currently pass both gates.

> The gov script's `-PolicyProbe` is **CLI-only** (`az group create` / `az deployment group create` / `az group delete`) — it does not need the Az PowerShell module, unlike the commercial installer's probe.

---

## What it checks (and does)

### Phase 0 — Permissions
Verifies the signed-in account has both **Subscription Owner** (to register providers and complete the install) and **Entra ID Global Administrator** (required by the NMM install itself). Reports PASS / FAIL / UNKNOWN and names exactly what to fix.

### Phase 1 — Resource Provider Registration
Checks that the resource providers NMM needs are registered. Without `-RegisterProviders` it reports state only (read-only); with the flag it registers missing providers and polls until all reach **Registered** (default 15-minute timeout, `-ProviderTimeoutMinutes`).

> The commercial installer checks 15 providers, including `Microsoft.Quota` and `Microsoft.MarketplaceOrdering`. The gov script omits `Microsoft.Quota` (not a registerable namespace in GCC-H).

### Phase 2 — Region Eligibility
Surfaces which regions offer **both** resources the NMM deployment needs:
- App Service Plan: Basic Medium (**B2**), Windows
- Azure SQL Database: **Standard / S1** (20 DTU)

Outputs a ranked table plus the reasons regions were excluded. The SQL check uses the `Microsoft.Sql` capabilities REST API and reports the human-readable reason a region is blocked. On PowerShell 7+ (Cloud Shell) the per-region checks run in parallel. Region filtering matches on both Azure `geographyGroup` and `geography` (so e.g. `-Geography UK` works).

### Policy Deny Check — **advisory**
Lists **Deny** policy assignments in the subscription's management hierarchy that *might* affect the install, filtering out the obvious non-appliers (`DoNotEnforce` mode, subscriptions excluded via `notScopes`, and policy exemptions).

> **This is advisory, not a verdict.** Whether a deny actually blocks NMM depends on `resourceSelectors`, `overrides`, and resource type — which can't be determined by listing alone. Microsoft-managed region/SDP gating policies commonly appear here and usually do **not** block. Use `-PolicyProbe` for the ground-truth answer.

**`-PolicyProbe`** (opt-in) is the authority: it deploys then deletes representative resources (storage account, Key Vault, SQL server) in a throwaway resource group and reports whether policy actually blocks them, capturing the exact blocking policy ID. It always cleans up the probe RG. Works standalone in check-only mode (`-CheckOnly -PolicyProbe`, no NMM deploy) or automatically before a real deployment.

> The probe tests representative resource types, not every resource NMM creates, so a policy scoped only to a type the probe doesn't create could still surprise the real install. It catches the common cases (location/tag/SKU denies).

### Phases 3-5 — Deploy (installer only, not in `-CheckOnly`)
- **Phase 3 — Region picker:** choose one of the eligible regions.
- **Phase 4 — Deployment:** accepts the Azure Marketplace terms for the NMM plan, then (after an explicit confirmation) deploys the NMM managed application from the embedded ARM template and waits for the admin web app to come up.
- **Phase 5 — Post-install configuration:** fetches and runs the NMM post-install configuration script pinned to `-NmmVersion`.

> **Availability ≠ quota:** "Eligible" means both SKUs are *offered* in the region, not that the subscription has quota headroom — App Service capacity has no public pre-check API. If a deploy hits a quota error in an eligible region, switch to another eligible region or open an Azure support request (issue type: "Service and subscription limits (quotas)"). Quota and subscription-management requests are **free** on any plan via the portal (Help + Support → New Support Request); only technical support requires a paid plan.

---

## Parameters

| Parameter | Applies to | Default | Description |
|---|---|---|---|
| `-CheckOnly` | installer | *(off)* | Run readiness checks (Phases 0-2 + advisory policy check) and stop before any deployment. No `-ResourceGroupName` needed. |
| `-ResourceGroupName` | installer | *(required to deploy)* | Resource group for the NMM deployment. Created if it doesn't exist. Not required with `-CheckOnly`. |
| `-PolicyProbe` | all | *(off)* | Ground-truth policy check: create + delete representative resources to confirm what actually blocks. Installer: works with `-CheckOnly` (probe only, no deploy). Gov script: CLI-only, no Az PowerShell module needed. |
| `-JsonOut` | installer | *(none)* | Write a full structured JSON report (all phases + policy findings + deployment result) to this path. |
| `-NmmVersion` | installer | `6.8.0` | NMM package version to deploy and match the post-install script to. |
| `-Force` | all | *(off)* | Skip the deploy confirmation and bypass readiness gates for unattended runs. |
| `-RegisterProviders` | all | *(off)* | Register any unregistered providers and poll to completion. |
| `-ProviderTimeoutMinutes` | all | `15` | How long to wait for provider registration. |
| `-Geography` | all | *(prompts)* | Limit the region check without knowing slugs: `US`, `Canada`, `Mexico`, `NorthAmerica`, `Europe`, `UK`, `AsiaPacific`, `MiddleEast`, `Africa`, `SouthAmerica`, `All`. |
| `-Regions` | all | *(geography/all)* | Comma-separated region slugs (e.g. `eastus,westus2`). Overrides `-Geography`. |
| `-AppServiceSku` | all | `B2` | App Service SKU to test. |
| `-SqlEdition` | all | `Standard` | Azure SQL edition to test. |
| `-SqlServiceObjective` | all | `S1` | Azure SQL service objective to test. |
| `-SubscriptionId` | all | *(prompts / current)* | Target a specific subscription. With multiple subscriptions and no value, the installer prompts you to pick one. |
| `-OutFile` | all | *(none)* | Write the region results table to a CSV. (`-JsonOut` is the fuller, machine-readable report.) |

---

## Requirements

- **Azure Cloud Shell** (PowerShell mode) — already authenticated — or local **PowerShell 7.0+** with the [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) installed and `az login` completed.
- The installer's deploy phases (and its `-PolicyProbe`) also use the **Az PowerShell module** (`Az.Accounts`, `Az.Resources`, `Az.Websites`) — present in Cloud Shell by default. `az login` alone does **not** authenticate Az PowerShell; the script handles this, but locally you may need `Connect-AzAccount`. The **gov script's `-PolicyProbe` does not need Az PowerShell** — it's `az` CLI-only.
- Account needs `Owner` on the subscription and `Global Administrator` in Entra ID to run a full install (Phase 0 flags this if missing).
- The readiness checks are **read-only**. The only things that change the subscription are `-RegisterProviders` (registers providers), `-PolicyProbe` (briefly creates + deletes test resources), and the installer's deploy phases (which require explicit confirmation or `-Force`).
- The installer is a **single file** — no companion `template.json` needed (the ARM template is embedded).
