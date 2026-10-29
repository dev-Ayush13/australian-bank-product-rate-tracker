import json
import sys
import time
from collections import Counter
from datetime import date, datetime, timezone
from pathlib import Path
from urllib.parse import quote

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

RAW_DIR = Path(__file__).resolve().parents[1] / "data" / "raw"
IN_SCOPE = {"RESIDENTIAL_MORTGAGES", "TRANS_AND_SAVINGS_ACCOUNTS", "TERM_DEPOSITS"}
VERSION_RANGE = {"x-v": "10", "x-min-v": "1"}
LIST_PAGE_SIZES = (25, 24, 23, 22)  # each size is a separate CDN cache entry, so a retry reaches the bank's server

register_file = max((RAW_DIR / "register").glob("*.json"))
brands = json.loads(register_file.read_text(encoding="utf-8"))["data"]
only = set(sys.argv[1:])
if only:
    brands = [b for b in brands if b["brandName"] in only]

session = requests.Session()
session.headers.update({"Accept": "application/json", "User-Agent": "australian-bank-product-rate-tracker (portfolio project; github.com/dev-Ayush13)"})
session.mount("https://", HTTPAdapter(max_retries=Retry(total=3, backoff_factor=2, status_forcelist=[429, 500, 502, 503, 504])))

out_dir = RAW_DIR / "products" / f"{date.today():%Y-%m-%d}"
fetch_log = {}  # (brand_id, request_key) -> final outcome of that request


def get(url, versions):
    resp = session.get(url, headers=versions, timeout=(10, 30))
    time.sleep(1)
    return resp


def fetch(url, save_to, versions, key):
    entry = fetch_log[key] = {"source_id": key[0], "request_key": key[1], "fetched_at": f"{datetime.now(timezone.utc):%Y-%m-%dT%H:%M:%SZ}"}
    try:
        resp = get(url, versions)
        if resp.status_code == 406 and versions == VERSION_RANGE:
            for v in range(9, 0, -1):
                exact = {"x-v": str(v), "x-min-v": None}
                resp = get(url, exact)
                if resp.status_code != 406:
                    versions.update(exact)
                    break
        entry.update(http_status=resp.status_code, api_version=resp.headers.get("x-v"))
        resp.raise_for_status()
        save_to.write_bytes(resp.content)
        entry["file"] = save_to.relative_to(out_dir).as_posix()
        return resp.json(), entry["api_version"]
    except (requests.RequestException, ValueError) as e:
        entry["error"] = describe(e)[:400]
        raise


def fetch_list(base, brand_dir, versions):
    for attempt, size in enumerate(LIST_PAGE_SIZES, 1):
        for old in brand_dir.glob("list_p*.json"):
            old.unlink()
        for key in [k for k in fetch_log if k[0] == brand_dir.name and k[1].startswith("list_")]:
            del fetch_log[key]
        products, url, page = [], f"{base}?page-size={size}", 0
        try:
            while url:
                page += 1
                body, version = fetch(url, brand_dir / f"list_p{page}.json", versions, (brand_dir.name, f"list_p{page}"))
                products += body["data"]["products"]
                next_url = body["links"].get("next")
                if next_url == url:
                    raise ValueError("next link repeats the current page")
                url = next_url
        except requests.HTTPError:
            if page == 1 or attempt == len(LIST_PAGE_SIZES):
                raise
            continue
        total = body["meta"].get("totalRecords")
        if (products and len(products) == total) or attempt == len(LIST_PAGE_SIZES):
            return products, total, version, attempt


def describe(e):
    code = getattr(getattr(e, "response", None), "status_code", None)
    return f"{type(e).__name__}{f' {code}' if code else ''}: {e}"


summary = []
run_start = time.monotonic()
print(f"Register file: {register_file.name} | brands: {len(brands)}", flush=True)

for brand in brands:
    brand_id = brand.get("dataHolderBrandId") or brand["interimId"]
    base = f"{brand['publicBaseUri'].rstrip('/')}/cds-au/v1/banking/products"
    brand_dir = out_dir / brand_id
    (brand_dir / "detail").mkdir(parents=True, exist_ok=True)
    row = {"brand_id": brand_id, "brand_name": brand["brandName"], "status": "ok"}
    started = time.monotonic()
    try:
        products, total, row["list_version"], row["list_attempts"] = fetch_list(base, brand_dir, dict(VERSION_RANGE))
        row.update(products=len(products), total_records=total)
        if not products and not total:
            row["status"] = "empty"
        elif len(products) != total:
            row["status"] = "count_mismatch"

        in_scope = [p for p in products if p["productCategory"] in IN_SCOPE]
        detail_versions, failed = dict(VERSION_RANGE), []
        for p in in_scope:
            pid = quote(p["productId"], safe="")
            key = (brand_id, f"detail/{p['productId']}")
            try:
                body, row["detail_version"] = fetch(f"{base}/{pid}", brand_dir / "detail" / f"{pid}.json", detail_versions, key)
                if not (body.get("data") or {}).get("productId"):
                    raise ValueError(f"no product in response: {json.dumps(body)[:100]}")
            except (requests.RequestException, ValueError) as e:
                fetch_log[key].setdefault("error", describe(e)[:400])
                failed.append(f"{p['productId']}: {describe(e)[:120]}")
        row.update(in_scope=len(in_scope), detail_failed=len(failed), detail_errors=failed[:5])
        if failed and row["status"] == "ok":
            row["status"] = "detail_errors"
    except (requests.RequestException, ValueError, KeyError, TypeError) as e:
        row.update(status="failed", error=describe(e)[:300])
    row["seconds"] = round(time.monotonic() - started)
    summary.append(row)
    print(f"{brand['brandName'][:38]:38} {row['status']:14} products {row.get('products', '-')}/{row.get('total_records', '-')} "
          f"in-scope {row.get('in_scope', '-')} failed {row.get('detail_failed', '-')} v{row.get('list_version')}/{row.get('detail_version')} "
          f"list attempts {row.get('list_attempts', '-')} {row['seconds']}s", flush=True)

day_summary, day_log = summary, list(fetch_log.values())
summary_file, log_file = out_dir / "_run_summary.json", out_dir / "_fetch_log.json"
if only:  # a partial re-run replaces only the brands it re-ran in the day's files
    ran = {r["brand_id"] for r in summary}
    if summary_file.exists():
        day_summary = [r for r in json.loads(summary_file.read_text(encoding="utf-8")) if r["brand_id"] not in ran] + summary
    if log_file.exists():
        day_log = [e for e in json.loads(log_file.read_text(encoding="utf-8")) if e["source_id"] not in ran] + day_log
summary_file.write_text(json.dumps(day_summary, indent=1), encoding="utf-8")
log_file.write_text(json.dumps(day_log, indent=0), encoding="utf-8")
print(f"\nDone in {round((time.monotonic() - run_start) / 60)} min | status: {dict(Counter(r['status'] for r in summary))}")
print(f"Products listed: {sum(r.get('products', 0) for r in summary)} | in scope: {sum(r.get('in_scope', 0) for r in summary)} "
      f"| detail failures: {sum(r.get('detail_failed', 0) for r in summary)}")
