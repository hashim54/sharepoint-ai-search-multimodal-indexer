#!/usr/bin/env python3
# ============================================================
# query.py — hybrid (BM25 + vector) search with semantic ranking.
#
# WHY hybrid + semantic: text-only BM25 misses paraphrases; vector-only misses
# exact terms/IDs. Hybrid fuses both, and the semantic ranker re-orders the top
# results using the 'default' config (title=sourceFile, content+imageDescription).
#
# WHY compute globalPage here (not in the index): in Phase 1 the index stores
# chunkStartPage + localPage per page. The human-facing page number is
#     globalPage = chunkStartPage + localPage - 1
# We compute it at display time so we don't depend on an enrichment-time
# arithmetic step (skills can't add numbers).
#
# Auth: uses Azure AD (DefaultAzureCredential) so it works with `az login` and
# the Search service's RBAC. No admin key required to READ.
# ============================================================

import argparse
import os
import sys
from pathlib import Path

import requests

try:
    from azure.identity import DefaultAzureCredential
except ImportError:
    print("Missing dependency. Run: pip install azure-identity requests", file=sys.stderr)
    raise


REPO_ROOT = Path(__file__).resolve().parent.parent


def load_env(path: Path) -> None:
    """Minimal .env loader (avoids a hard dependency on python-dotenv).

    Later files override earlier ones because we set os.environ directly.
    """
    if not path.exists():
        return
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, val = line.split("=", 1)
        key = key.strip()
        val = val.lstrip()
        if val[:1] in ('"', "'"):
            # Quoted value: take up to the matching quote, drop trailing comment.
            quote = val[0]
            end = val.find(quote, 1)
            val = val[1:end] if end >= 1 else val[1:]
        else:
            # Unquoted value: strip an inline comment at the first '#'.
            hash_idx = val.find("#")
            if hash_idx >= 0:
                val = val[:hash_idx]
            val = val.strip()
        os.environ[key] = val


def require_env(name: str) -> str:
    val = os.environ.get(name)
    if not val:
        print(f"Required env var '{name}' is missing. Check .env / .env.derived.", file=sys.stderr)
        sys.exit(2)
    return val


def get_token() -> str:
    """Fetch an AAD token for the Search data-plane audience."""
    cred = DefaultAzureCredential()
    return cred.get_token("https://search.azure.com/.default").token


def run_search(query: str, top: int) -> dict:
    endpoint = require_env("SEARCH_ENDPOINT").rstrip("/")
    index = require_env("INDEX_NAME")
    api_version = os.environ.get("SEARCH_API_VERSION", "2026-05-01-preview")

    # One token for the signed-in user serves two purposes here:
    #  - Authorization: RBAC access to the index (needs Search Index Data Reader)
    #  - x-ms-query-source-authorization: the identity whose SharePoint ACLs are
    #    evaluated per document, so results are security-trimmed to what THIS
    #    user may see. In a real app this second token is the end user's token
    #    (e.g., via on-behalf-of), not necessarily the same as the app's.
    token = get_token()
    url = f"{endpoint}/indexes/{index}/docs/search?api-version={api_version}"
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {token}",
        "x-ms-query-source-authorization": token,
    }

    # Hybrid: `search` drives BM25; `vectorQueries` with a text kind lets the
    # service vectorize the same query via the index's configured vectorizer
    # (openai-text-vectorizer) so we don't embed client-side.
    payload = {
        "search": query,
        "top": top,
        "select": "id,sourceFile,page,webUrl,content",
        "queryType": "semantic",
        "semanticConfiguration": "default",
        "vectorQueries": [
            {
                "kind": "text",
                "text": query,
                "fields": "contentVector",
                "k": top,
            }
        ],
    }

    resp = requests.post(url, headers=headers, json=payload, timeout=60)
    if resp.status_code >= 400:
        print(f"Search failed ({resp.status_code}): {resp.text}", file=sys.stderr)
        sys.exit(1)
    return resp.json()


def snippet(text: str, width: int = 220) -> str:
    if not text:
        return ""
    text = " ".join(text.split())
    return text if len(text) <= width else text[:width].rstrip() + "..."


def display(results: dict) -> None:
    docs = results.get("value", [])
    if not docs:
        print("No results.")
        return

    for i, doc in enumerate(docs, start=1):
        page = doc.get("page")

        reranker = doc.get("@search.rerankerScore")
        score = doc.get("@search.score")

        print("=" * 78)
        print(f"[{i}] {doc.get('sourceFile', '(unknown file)')}")
        if page is not None:
            print(f"    page: {page}")
        if reranker is not None:
            print(f"    scores: reranker={reranker:.3f}  search={score:.3f}")
        else:
            print(f"    score: {score:.3f}")

        content = snippet(doc.get("content", ""))
        if content:
            print(f"    text: {content}")

        web_url = doc.get("webUrl")
        if web_url:
            print(f"    source: {web_url}")
    print("=" * 78)


def main() -> None:
    parser = argparse.ArgumentParser(description="Query the SharePoint page index (hybrid + semantic).")
    parser.add_argument("query", help="The natural-language query string.")
    parser.add_argument("--top", type=int, default=5, help="Number of results (default 5).")
    args = parser.parse_args()

    # base first, derived overrides (endpoint etc. come from provisioning).
    load_env(REPO_ROOT / ".env")
    load_env(REPO_ROOT / ".env.derived")

    results = run_search(args.query, args.top)
    display(results)


if __name__ == "__main__":
    main()
