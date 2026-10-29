"""One-off: rebuild _fetch_log.json for days collected before the collector logged each request (28-29 Oct 2026).

Saved files become status 200 rows (version from the run summary, time from the file); errors come from the run summary.
On 28 Oct the retest summary is merged into the full-run summary (the original is kept as _run_summary_full_run.json),
and a brand that failed in the full run but was later collected by a retest (Revolut) is rebuilt from its files.
"""
import json
import re
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import unquote

RAW_DIR = Path(__file__).resolve().parents[1] / "data" / "raw"
IN_SCOPE = {"RESIDENTIAL_MORTGAGES", "TRANS_AND_SAVINGS_ACCOUNTS", "TERM_DEPOSITS"}

day_dir = RAW_DIR / "products" / sys.argv[1]
summary_file, full_run_file, retest_file = (day_dir / n for n in ("_run_summary.json", "_run_summary_full_run.json", "_run_summary_partial.json"))
if (day_dir / "_fetch_log.json").exists():
    sys.exit(f"{day_dir.name} already has a fetch log")


def utc(ts):
    return f"{datetime.fromtimestamp(ts, timezone.utc):%Y-%m-%dT%H:%M:%SZ}"


def status_code(error):
    found = re.search(r"(\d{3}) (?:Client|Server) Error", error)
    return int(found[1]) if found else None


def list_files(brand_dir):
    return sorted(brand_dir.glob("list_p*.json"), key=lambda f: int(f.stem[6:]))


summary = json.loads(summary_file.read_text(encoding="utf-8"))
if retest_file.exists():
    if not full_run_file.exists():
        shutil.copy2(summary_file, full_run_file)
    summary = json.loads(full_run_file.read_text(encoding="utf-8"))
    full_run_time = full_run_file.stat().st_mtime
    retest = {r["brand_id"]: r for r in json.loads(retest_file.read_text(encoding="utf-8"))}
    summary = [retest.get(r["brand_id"], r) for r in summary]
    for row in summary:
        lists = list_files(day_dir / row["brand_id"])
        if row["status"] == "failed" and lists and lists[0].stat().st_mtime > full_run_time:
            pages = [json.loads(f.read_text(encoding="utf-8")) for f in lists]
            products = [p for page in pages for p in page["data"]["products"]]
            in_scope = sum(p["productCategory"] in IN_SCOPE for p in products)
            details = len(list((day_dir / row["brand_id"] / "detail").glob("*.json")))
            total = pages[0]["meta"].get("totalRecords")
            status = "count_mismatch" if len(products) != total else "detail_errors" if details < in_scope else "ok"
            row.update(status=status, error=None, list_version=None, detail_version=None, list_attempts=None,
                       products=len(products), total_records=total, in_scope=in_scope, detail_failed=in_scope - details, detail_errors=[])
            print(f"Rebuilt from retest files: {row['brand_name']} {status} {len(products)}/{total} in-scope {in_scope}")
    summary_file.write_text(json.dumps(summary, indent=1), encoding="utf-8")

run_time = utc((full_run_file if full_run_file.exists() else summary_file).stat().st_mtime)  # the merged summary is rewritten above
log = []
for row in summary:
    brand_id, brand_dir = row["brand_id"], day_dir / row["brand_id"]
    lists = list_files(brand_dir)
    entries = {}
    for f in lists:
        entries[f.stem] = (f, row.get("list_version"))
    for f in (brand_dir / "detail").glob("*.json"):
        entries[f"detail/{unquote(f.stem)}"] = (f, row.get("detail_version"))
    files = [f for f, _ in entries.values()]
    brand_time = utc(max(f.stat().st_mtime for f in files)) if files else run_time
    for key, (f, version) in entries.items():
        log.append({"source_id": brand_id, "request_key": key, "fetched_at": utc(f.stat().st_mtime), "http_status": 200,
                    "api_version": version, "file": f.relative_to(day_dir).as_posix()})
    errors = [e.partition(": ") for e in row.get("detail_errors") or []]
    if len(errors) != (row.get("detail_failed") or 0):
        print(f"WARNING {row['brand_name']}: {row['detail_failed']} detail failures but {len(errors)} recorded")
    for pid, _, error in errors:
        log = [e for e in log if not (e["source_id"] == brand_id and e["request_key"] == f"detail/{pid}")]
        log.append({"source_id": brand_id, "request_key": f"detail/{pid}", "fetched_at": brand_time,
                    "http_status": status_code(error), "api_version": None, "error": error})
    if row["status"] == "failed":
        log.append({"source_id": brand_id, "request_key": f"list_p{len(lists) + 1}", "fetched_at": brand_time,
                    "http_status": status_code(row["error"]), "api_version": None, "error": row["error"]})

(day_dir / "_fetch_log.json").write_text(json.dumps(log, indent=0), encoding="utf-8")
print(f"{day_dir.name}: {len(summary)} brands, {len(log)} requests, {sum('error' in e for e in log)} errors")
