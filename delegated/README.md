# Delegated-permissions variant

This folder is a **self-contained variant** of the pipeline that uses **delegated** SharePoint permissions instead of application permissions. It exists **alongside** the primary (application-permission, ACL-preserving) implementation and does **not** modify or overwrite it — it deploys its own `*-del` artifacts to the same Search service.

> ⚠️ **Delegated permissions cannot ingest SharePoint ACLs.** This variant therefore has **no security trimming** — every user who can query the index sees all indexed content. Use it only where ACL trimming is not required, or for testing/demo. If ACL-synchronized search is a requirement, use the primary application-permission implementation.

## How it differs from the primary implementation

| Aspect | Primary (application) | This variant (delegated) |
|--------|----------------------|--------------------------|
| Graph permissions | `Files.Read.All` + `Sites.FullControl.All`/`Sites.Selected` (application) | `Files.Read.All` + `Sites.Read.All` + `User.Read` (**delegated**) |
| Data source credential | client secret | **none** (secret-less connection string) |
| ACL ingestion / security trimming | ✅ | ❌ (not supported by delegated) |
| Auth at run time | non-interactive | **device-code sign-in** (interactive) |
| Unattended / scheduled runs | ✅ | ❌ token expires ~75 min → manual re-auth; on-demand only |
| Indexes content as | service (all granted content) | **the signed-in user** (their view only) |
| Artifact names | `sharepoint-*` | `sharepoint-*-del` |

## Prerequisites

1. **A new Entra app registration** (separate from the application-permission app) with **Delegated** Microsoft Graph permissions:
   - `Files.Read.All`, `Sites.Read.All`, `User.Read`
   - **Grant admin consent** (locked-down tenants require it even for delegated).
   - **Authentication → "Allow public client flows" = Yes**.
   - **Authentication → Add a platform → Mobile and desktop applications →** add redirect URI
     `https://login.microsoftonline.com/common/oauth2/nativeclient`.
2. **`.env`** additions:
   ```
   SP_DEL_CLIENT_ID="<client id of the delegated app registration>"
   ```
   (`SP_SITE_URL` and `SP_APP_TENANT_ID` are reused from the primary `.env`. `SP_APP_CLIENT_SECRET` is **not** used here.)
3. The shared Azure resources (Search / Foundry) must already exist — run the primary `scripts/01-provision-resources.ps1` first so `.env.derived` holds `SEARCH_ENDPOINT` and `FOUNDRY_ENDPOINT`.

## Deploy

```powershell
.\delegated\scripts\03-deploy-search-delegated.ps1
```

What happens:
1. Creates the `*-del` index, datasource, and skillset.
2. Creates the `*-del` indexer, which triggers the **device-code sign-in**.
3. The script prints a message like *"To sign in, use a web browser to open https://microsoft.com/devicelogin and enter the code XXXXXX"*.
4. **Open that URL, enter the code, sign in as the indexing user, and approve** — within ~10 minutes.
5. The script then polls the indexer to completion.

Optional flags: `-AuthTimeoutMinutes` (default 12), `-IndexTimeoutMinutes` (default 30).

## Re-running / token expiry

Delegated tokens expire ~75 minutes after sign-in. To index again (or after expiry), **re-run the script** — it re-creates the indexer and prints a fresh device code to sign in again. There is intentionally **no schedule** on the delegated indexer.

## Querying

The `query-examples.ipynb` notebook works against this index too — set `INDEX_NAME=sharepoint-page-index-del` in `.env` (or edit the notebook's `INDEX_NAME`). Note there is **no security trimming** here, so results are not filtered by identity.
