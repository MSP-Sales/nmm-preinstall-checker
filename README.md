# NMM Install Pre-Flight

Scripts that de-risk a **Nerdio Manager for MSP (NMM)** Azure deployment: confirm the subscription is ready, pick a region that will actually take the install, surface policy blockers, and (optionally) run the deployment end to end.

Two scripts live here:

| Script | Cloud | What it does |
|---|---|---|
| **`preinstall_install.ps1`** | Commercial | **End-to-end installer, single self-contained file, Azure Cloud Shell only.** Resource group check, readiness checks (Phases 0-2, incl. PIM timing and App Service quota), advisory policy-deny check + `-PolicyProbe`, region picker with automatic quota increase and an advanced any-region option, ARM deployment, and post-install configuration. Use `-CheckOnly` to run the readiness checks and stop before any change to the subscription. |
| `Check-NMMPreinstall-Gov.ps1` | Azure Government (GCC-H) | Readiness checks for gov tenants (Phases 0-2) plus the same policy-deny check + `-PolicyProbe`. CLI-only — no Az PowerShell module needed. Read-only; **no deployment phase yet** (there's no ARM template for a gov NMM install). |

---

## ⚠️ Run it in the *partner's* subscription

Region availability and App Service / SQL quota are **per-subscription**. The only result that matters is the one from the tenant where NMM is actually being installed. Run this in the **partner's** Azure Cloud Shell (screen-share and dictate the one-liner), not your own.

---

## Quick Start — installer (commercial)

`preinstall_install.ps1` is a **single self-contained file** — the ARM template is embedded, so there's nothing else to download. It **only runs in Azure Cloud Shell** (the NMM post-install configuration step requires it) and refuses to start anywhere else. Open Cloud Shell at <https://shell.azure.com> (or the `>_` icon in the Azure portal), make sure it's in **PowerShell** mode, and paste:

### Check only (read-only — safe to run anytime)

Runs the resource group check (if `-ResourceGroupName` is given), Phases 0-2 and the advisory policy-deny check, then stops. **Nothing in the subscription changes** — no quota requests and no Key Vault purges. The one exception: if required providers are missing, it offers to register them (or pass `-RegisterProviders`).

```powershell
irm https://raw.githubusercontent.com/MSP-Sales/nmm-preinstall-checker/main/preinstall_install.ps1 -OutFile preinstall_install.ps1
./preinstall_install.ps1 -CheckOnly
```

### Check + install (deploys NMM)

Runs the checks, lets you pick an eligible region, **asks for confirmation**, requests an App Service quota increase if the region needs one, then deploys and runs post-install configuration. Requires `-ResourceGroupName` (must be a **new** resource group).

```powershell
irm https://raw.githubusercontent.com/MSP-Sales/nmm-preinstall-checker/main/preinstall_install.ps1 -OutFile preinstall_install.ps1
./preinstall_install.ps1 -ResourceGroupName nmm-rg
```

> **Nothing deploys until you confirm.** After you pick a region the script prints exactly what it's about to do (resource group, region, SKUs, and any quota request) and waits for a yes. Cancel and no resources are created. Pass `-Force` to skip the prompt for unattended runs.

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

> **Confirm the subscription isn't a free trial before you start.** A Gov free trial ships with a B2 App Service quota of 0, and free trials aren't eligible for quota-adjustment requests — there's no increase path, only upgrading off the trial. Region/policy checks passing doesn't mean anything if the subscription can't be adjusted. See the GCC-H checklist's Step 0 for the pre-assessment gate.

> The gov script's `-PolicyProbe` is **CLI-only** (`az group create` / `az deployment group create` / `az group delete`) — it does not need the Az PowerShell module, unlike the commercial installer's probe.

---

## What it checks (and does)

### Resource Group Check (installer)
NMM deploys into the resource group's region, so the resource group must be **new** — it's created later in the region you pick. The script also looks for **soft-deleted Key Vaults** left by an earlier NMM install into a resource group with the same name (they block the deploy) and offers to purge them. Purging always needs an interactive yes (`-Force` never purges). In `-CheckOnly` mode this only reports.

### Phase 0 — Permissions
Verifies the signed-in account has both **Subscription Owner** (to register providers and complete the install) and **Entra ID Global Administrator** (required by the NMM install itself). Reports PASS / FAIL / UNKNOWN, shows how Owner is granted (direct, via group, inherited from a management group / root), and names exactly what to fix.

**PIM timing check (installer).** A PIM-activated role passes the membership check exactly like a standing one, but using it right after activation has been tied to `RoleAssignmentExists` install failures. The installer reads the PIM schedule instances for Owner (ARM) and Global Administrator (Graph) and reports each as **standing** or **PIM-activated**, then warns when:
- the role was activated **after this Cloud Shell session's token was issued** → restart Cloud Shell, then re-run
- the role was activated **less than ~10 minutes ago** → offers to wait for RBAC propagation
- the activation **expires within ~75 minutes** (an install takes ~45-60) → extend it first

These are advisory prompts, never hard blocks. If the PIM APIs can't be read (e.g. no Entra ID P2 licence) the status shows as *not determined* and the script carries on.

### Phase 1 — Resource Provider Registration
Checks that the resource providers NMM needs are registered. Without `-RegisterProviders` it reports state only (read-only); with the flag it registers missing providers and polls until all reach **Registered** (default 15-minute timeout, `-ProviderTimeoutMinutes`).

> The commercial installer checks 15 providers, including `Microsoft.Quota` and `Microsoft.MarketplaceOrdering`. The gov script omits `Microsoft.Quota` (not a registerable namespace in GCC-H).

### Phase 2 — Region Eligibility
Surfaces which regions offer **both** resources the NMM deployment needs:
- App Service Plan: Basic Medium (**B2**), Windows
- Azure SQL Database: **Standard / S1** (20 DTU)

The installer also reads the subscription's **App Service quota** per region through the `Microsoft.Quota` API needing `-AppServiceInstances` free. **A region with free quota in either the `B2 VMs` row or the *Total Regional VMs* row is a good choice.** When the region returns a `B2 VMs` row, that's the row that counts. Many regions don't return a `B2 VMs` row, only *Total Regional VMs* (e.g. Austria East: 0 of 31); there the regional limit applies, and deploying within it works. The results table shows both rows (`B2Quota` and `TotalRegional`; `-` means the row wasn't returned). **Only `B2 VMs` quota can be increased** (that's what the automatic increase does for QUOTA regions). *Total Regional VMs* quota can't be increased, so a region with no `B2 VMs` row and a full *Total Regional VMs* row is UNVERIFIED.

Each region gets one of four statuses, best first:

| Status | Meaning |
|---|---|
| **YES** | Azure SQL available, `B2` offered, and quota has enough free: the `B2 VMs` row if the region returns one, otherwise *Total Regional VMs* |
| **QUOTA** | Azure SQL available, `B2` offered, `B2 VMs` row too low — the automatic increase fixes it |
| **UNVERIFIED** | Azure SQL available, `B2` offered, but quota couldn't be confirmed: no `B2 VMs` or *Total Regional VMs* row, *Total Regional VMs* full with no `B2 VMs` row, or the quota API errored. These might fail, so they're never recommended |
| **no** | Azure SQL not available, or `B2` not offered (with the reason) |

The SQL check uses the `Microsoft.Sql` capabilities REST API and reports the human-readable reason a region is blocked. SQL and quota checks run together in parallel. Region filtering matches on both Azure `geographyGroup` and `geography` (so e.g. `-Geography UK` works). If nothing is eligible, the region picker still opens so you can go back, use the advanced option, or quit. If the quota API fails in every region, a warning says so (every region then shows as UNVERIFIED).

### Policy Deny Check — **advisory**
Lists **Deny** policy assignments in the subscription's management hierarchy that *might* affect the install, filtering out the obvious non-appliers (`DoNotEnforce` mode, subscriptions excluded via `notScopes`, and policy exemptions).

> **This is advisory, not a verdict.** Whether a deny actually blocks NMM depends on `resourceSelectors`, `overrides`, and resource type — which can't be determined by listing alone. Microsoft-managed region/SDP gating policies commonly appear here and usually do **not** block. Use `-PolicyProbe` for the ground-truth answer.

**`-PolicyProbe`** (opt-in) is the authority: it deploys then deletes representative resources (storage account, Key Vault, SQL server) in a throwaway resource group and reports whether policy actually blocks them, capturing the exact blocking policy ID. It always cleans up the probe RG. Works standalone in check-only mode (`-CheckOnly -PolicyProbe`, no NMM deploy) or automatically before a real deployment.

> The probe tests representative resource types, not every resource NMM creates, so a policy scoped only to a type the probe doesn't create could still surprise the real install. It catches the common cases (location/tag/SKU denies).

### Phases 3-5 — Deploy (installer only, not in `-CheckOnly`)
- **Phase 3 — Region picker:** regions are listed YES, then QUOTA, then UNVERIFIED (marked as might fail). The default is the first YES or QUOTA region; if there's none, the default is `0` (back), so the script never recommends an unverified region. You can still pick one, and the confirmation notes that its quota wasn't verified. `0` goes back to geography selection, `A` is the advanced option, `Q` quits. **Advanced** deploys to any Azure region you type, skipping the eligibility checks and the quota increase (for partners who handle quota themselves); it warns if that region failed the SQL check, and the confirmation marks it as an advanced pick. For a QUOTA region, the confirmation lists the quota increase; once you confirm, the script submits it through `Microsoft.Quota`, waits for it, and then re-reads the limit (Azure sometimes reports `Failed` on a request that still applied). If the increase doesn't apply, you can go back, continue anyway, or exit.
- **Phase 4 — Deployment:** accepts the Azure Marketplace terms for the NMM plan (`az vm image terms accept`, falling back to `az term accept` from the `marketplaceordering` extension, then confirmed with `az vm image terms show`), then (after an explicit confirmation) deploys the NMM managed application from the embedded ARM template and waits for the admin web app to come up.
- **Phase 5 — Post-install configuration:** looks up the latest NMM release from Nerdio's release list (or uses `-NmmVersion` if given), prints the exact command, then downloads and runs the post-install configuration script for that release. (The Azure Marketplace template itself stays fixed at 6.8.0, its marketplace version, which doesn't track NMM releases.)

> **If the automatic quota increase fails,** raise it in the portal (Quotas → App Service → region → `B2 VMs` → pencil icon). A `RoleAssignmentExists` deploy failure prints PIM-specific recovery steps.

---

## Parameters

| Parameter | Applies to | Default | Description |
|---|---|---|---|
| `-CheckOnly` | installer | *(off)* | Run readiness checks (RG check, Phases 0-2 + advisory policy check) and stop. Report-only: no quota requests or Key Vault purges. Still offers to register missing providers. No `-ResourceGroupName` needed. |
| `-ResourceGroupName` | installer | *(required to deploy)* | Resource group for the NMM deployment. Must be **new**; it's created in the region you pick. Optional with `-CheckOnly` (checked if given). |
| `-AppServiceInstances` | installer | `1` | App Service instances the quota check needs free. |
| `-NmmVersion` | installer | *(latest release)* | Pin the NMM release the post-install configuration installs (e.g. `7.3.3`). Leave it out to use the latest release. Doesn't change the Azure Marketplace template, which is always `6.8.0`. |
| `-PolicyProbe` | all | *(off)* | Ground-truth policy check: create + delete representative resources to confirm what actually blocks. Installer: works with `-CheckOnly` (probe only, no deploy). Gov script: CLI-only, no Az PowerShell module needed. |
| `-JsonOut` | installer | *(none)* | Write a full structured JSON report (all phases + policy findings + deployment result) to this path. |
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

- **Installer: Azure Cloud Shell (PowerShell mode) only.** The script refuses to run elsewhere because the NMM post-install configuration only works in Cloud Shell. Its deploy, quota-request and `-PolicyProbe` steps use the Az PowerShell module, which Cloud Shell already provides.
- The gov script runs in Cloud Shell or local **PowerShell 7.0+** with the Azure CLI and `az login`. Its `-PolicyProbe` is `az` CLI-only, with no Az PowerShell needed.
- Account needs `Owner` on the subscription and `Global Administrator` in Entra ID to run a full install (Phase 0 flags this if missing).
- The readiness checks are **read-only**. The only things that change the subscription are `-RegisterProviders` (registers providers), `-PolicyProbe` (briefly creates + deletes test resources), an interactive yes to purge soft-deleted Key Vaults, and the installer's quota request + deploy phases (which require explicit confirmation or `-Force`).
- The installer is a **single file** — no companion `template.json` needed (the ARM template is embedded).
