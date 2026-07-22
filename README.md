# SharePoint → Azure AI Search (Multimodal, ACL-Preserving RAG Kit)

Ingests documents from a SharePoint site into **Azure AI Search** with:

- **Content Understanding** (Foundry) for text extraction + semantic chunking + AI-generated figure descriptions.
- **Multimodal indexing** — every page produces text chunks (`kind=text`, 3072-dim text vectors) and extracted images (`kind=image`, 1024-dim Vision vectors), so you can search text *and* images.
- **SharePoint ACL ingestion + synchronization** — per-document `UserIds` / `GroupIds` are pulled from SharePoint and used for query-time security trimming, so users only see what they're allowed to.

Everything is provisioned **from scratch into a single region** (Sweden Central) and a **dedicated resource group**, so the whole project can be torn down with one command.

---

## Architecture

```
SharePoint site ──► AI Search indexer ──► Skillset ──────────────► Index (sharepoint-page-index)
 (docs + ACLs)        (datasource)     │  Content Understanding      • text rows  (contentVector 3072)
                                       │  text embeddings            • image rows (imageVector 1024)
                                       │  Vision image embeddings     • UserIds / GroupIds (ACL trim)
                                       │  conditional kind routing
                                       └─ index projections (text + image selectors)
```

| Component | Resource | Purpose |
|-----------|----------|---------|
| Search | `spmm-rag-search` (S1) | Index, indexer, skillset, security trimming |
| Foundry (AIServices) | `spmm-rag-foundry` | Content Understanding + `text-embedding-3-large` + `gpt-4.1-mini` |
| Vision (AIServices) | `spmm-rag-vision` | Multimodal image embeddings (skill + query-time vectorizer) |

All resources live in resource group **`spmm-rag-poc`** in **Sweden Central** — the only region that supports Content Understanding, the required models, *and* Vision multimodal embeddings together.

---

## Prerequisites

### 1. Tooling (local machine)

| Tool | Notes |
|------|-------|
| [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) | `az login` completed, with rights to create resources + role assignments in the subscription |
| Azure CLI Bicep | `az bicep install` (or it auto-installs on first build) |
| PowerShell 7+ | The `scripts/*.ps1` deployment scripts |
| Python 3.9+ | Only for the query client (`scripts/query.py`) |

Install the Python query dependencies:

```powershell
pip install -r scripts/requirements.txt
```

### 2. Azure subscription

- A subscription where you can create **Azure AI Search**, **Azure AI Services (Foundry + Vision)**, model deployments, and **role assignments** (you need `Owner` or `User Access Administrator` + `Contributor` to create the role assignments in the Bicep template).
- Model quota in Sweden Central for `text-embedding-3-large` (Standard) and `gpt-4.1-mini` (Standard). The template defaults are `EMBED_CAPACITY=30` and `GPT_CAPACITY=1000` — adjust in `.env` if your quota is lower.

### 3. Manual prerequisites (cannot be automated in Bicep)

These must be done **once, by an administrator**, before running the deployment:

1. **Entra app registration for the SharePoint indexer**
   - Register an app in Microsoft Entra ID.
   - Grant **Microsoft Graph application permissions**: `Files.Read.All` and `Sites.FullControl.All` (or `Sites.Selected` scoped to your site).
   - **Grant admin consent** for those permissions.
   - Create a **client secret**.
   - Record the **client ID**, **tenant ID**, and **client secret** — these go into `.env` (`SP_APP_CLIENT_ID`, `SP_APP_TENANT_ID`, `SP_APP_CLIENT_SECRET`).

2. **Register for the SharePoint indexer preview**
   - Submit the preview registration form: <https://aka.ms/azure-cognitive-search/indexer-preview> (auto-approved). Required because the SharePoint data source is a preview feature.

3. **SharePoint content**
   - A SharePoint site with one or more document libraries containing the files to index (PDF/DOCX/PPTX/XLSX). Set `SP_SITE_URL` in `.env`.

> ⚠️ **Secrets:** `.env` contains the client secret. It is git-ignored (see `.gitignore`) — never commit it. Rotate the secret if it is ever exposed.

---

## Configuration

All settings live in **`.env`** at the repo root. It is kept **minimal** — only the values a deployment must provide. Everything else (model deployments, SKUs, search API version, index/skillset/indexer names) has sensible defaults applied by [scripts/_common.ps1](scripts/_common.ps1); override any of them by simply adding the variable to `.env`. Provisioning outputs (endpoints, principal IDs) are written to **`.env.derived`** automatically — you don't edit that file.

Required variables in `.env`:

| Variable | Meaning |
|----------|---------|
| `AZ_SUBSCRIPTION_ID` | Target subscription |
| `AZ_RG` | Dedicated resource group (created by step 1) |
| `RESOURCE_LOCATION` | Region for **all** resources (default `swedencentral`) |
| `SP_SITE_URL`, `SP_APP_CLIENT_ID`, `SP_APP_TENANT_ID`, `SP_APP_CLIENT_SECRET` | SharePoint site + app registration |

**Resource names are auto-generated.** If you don't set `SEARCH_NAME` / `FOUNDRY_NAME` / `VISION_NAME`, step 1 generates globally-unique names as `<RESOURCE_PREFIX>-<role>-<random-suffix>` (default prefix `spmmrag`) and persists them to `.env.derived`, so re-runs reuse them. Set `RESOURCE_PREFIX` to brand them, or set the full names explicitly to pin them.

Optional overrides (defaults in `_common.ps1`): `RESOURCE_PREFIX`, `SEARCH_NAME`/`FOUNDRY_NAME`/`VISION_NAME`, `EMBED_*`, `CU_MODEL_*`, `GPT_*` (model deployments/SKUs/capacities), `SEARCH_SKU`, `INDEX_NAME`, `DATASOURCE_NAME`, `SKILLSET_NAME`, `INDEXER_NAME`, `SEARCH_API_VERSION`, and `QUERY_PRINCIPAL_ID` (force the Search Index Data Reader grant).

> If you pin names explicitly, the Search / Foundry / Vision names must be **globally unique**. If a name is taken, deployment preflight fails with `ServiceNameUnavailable` / `CustomDomainInUse` — pick a different name (or just leave them unset to auto-generate).

---

## Deployment steps

Run from the repo root in PowerShell 7 (after `az login`).

### Step 1 — Provision Azure resources

```powershell
.\scripts\01-provision-resources.ps1
```

Creates the resource group, deploys `iac/main.bicep` (Search + Foundry + models + Vision + role assignments), and captures endpoints into `.env.derived`.

- Grants the Search managed identity **Cognitive Services User** on Foundry and Vision.
- Grants the signed-in user **Search Index Data Reader** (so token-based queries / the query notebook work).
- Optional flag `-SkipDeployments` skips the model deployments (useful if model quota is temporarily unavailable).

### Step 2 — Deploy the search artifacts

```powershell
.\scripts\03-deploy-search.ps1
```

Creates/updates (PUT = create-or-update) the **index**, **datasource**, **skillset**, and **indexer** from the JSON in `skillset/`, substituting endpoints and SharePoint credentials from `.env` / `.env.derived`.

### Step 3 — Run the indexer & watch status

```powershell
.\scripts\04-check-status.ps1 -MaxMinutes 30
```

Triggers an on-demand indexer run and polls every 15s until it completes (or the timeout).

- `-NoRun` — poll the current run without triggering a new one.
- `-MaxMinutes <n>` — polling timeout (default is the script's built-in value).

The indexer also runs automatically on its `PT1H` schedule, which keeps the index — including ACLs — synchronized with SharePoint.

---

## Querying

Open **`query-examples.ipynb`** (repo root) for runnable, multimodal query examples — hybrid text search, cross-modal text→image search (with inline image rendering), semantic Q&A, filtered search, and a combined multimodal query. It authenticates via `DefaultAzureCredential` (`az login`) — no admin key needed to read.

```powershell
pip install -r scripts/requirements.txt   # azure-identity, requests (+ ipykernel to run the notebook)
```

Then run the cells in `query-examples.ipynb`. Each `search(...)` call is editable — swap in your own query, toggle text/image vectors, or add an OData `filter`.

Security trimming: the client sends your Entra token as `x-ms-query-source-authorization`, so results are trimmed to documents whose `UserIds` / `GroupIds` you belong to. Querying with an admin key or from the portal sends no user token and returns **0** trimmed results by design.

---

## Teardown

Because everything is in one dedicated resource group, remove the entire project with:

```powershell
az group delete --name spmm-rag-poc --yes
```

---

## Repository layout

```
.env                     Configuration (edit this; git-ignored, contains secrets)
.env.derived             Auto-generated provisioning outputs (do not edit)
query-examples.ipynb     Runnable multimodal query examples (notebook)
iac/
  main.bicep             From-scratch, single-region infrastructure
  main.json              Compiled ARM (generated)
  validate.ps1           az deployment validate helper
scripts/
  _common.ps1            Shared helpers (env loading, error handling)
  01-provision-resources.ps1   Create RG + all Azure resources
  03-deploy-search.ps1         Deploy index / datasource / skillset / indexer
  04-check-status.ps1          Run + monitor the indexer
  requirements.txt             Python dependencies for the query notebook
skillset/
  index.json             Multimodal index schema (text + image, ACL fields)
  datasource.json        SharePoint data source (ACL options enabled)
  skillset.json          CU + embeddings + Vision + conditional routing
  indexer.json           Field mappings + file-type + schedule
```

---

## Notes & limits

- **Content Understanding limits:** ≤ 200 MB and ≤ 300 pages per document; ~480s processing budget per document. Very large PDFs may need splitting upstream.
- **ACL-safe skills only:** custom Web API skills, GenAI prompt skills, knowledge store, enrichment cache, and debug sessions all break SharePoint ACL inheritance and are intentionally **not** used here.
- **Region:** the multimodal Vision embedding skill/vectorizer only runs in Vision-multimodal-supported Search regions. Sweden Central is validated; not all regions qualify.

