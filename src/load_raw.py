import gzip
import hashlib
import json
import os
import sys
import time
from datetime import date, datetime, timezone
from pathlib import Path

import pyodbc
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[1]
RAW_DIR = ROOT / "data" / "raw"

run_date = sys.argv[1] if len(sys.argv) > 1 else f"{date.today():%Y-%m-%d}"
day_dir = RAW_DIR / "products" / run_date
summary = json.loads((day_dir / "_run_summary.json").read_text(encoding="utf-8"))
log = json.loads((day_dir / "_fetch_log.json").read_text(encoding="utf-8"))
for source_id, request_key, file, api_version in [("cdr_register", "brands/summary", RAW_DIR / "register" / f"{run_date}.json", "2"),
                                                  ("rba_a2", "a2-data.csv", RAW_DIR / "rba" / f"{run_date}.csv", None)]:
    if file.exists():  # the RBA file is collected from 30 Oct 2026
        log.append({"source_id": source_id, "request_key": request_key, "http_status": 200, "api_version": api_version, "file": file,
                    "fetched_at": f"{datetime.fromtimestamp(file.stat().st_mtime, timezone.utc):%Y-%m-%dT%H:%M:%SZ}"})


def version(v):
    return int(v) if v else None


responses, fetch_rows = {}, []
for e in log:
    response_hash = None
    if e.get("file"):
        body = (day_dir / e["file"]).read_bytes()
        response_hash = hashlib.sha256(body).digest()
        if response_hash not in responses:
            responses[response_hash] = (gzip.compress(body), len(body))
    fetch_rows.append((run_date, e["source_id"], e["request_key"], e.get("http_status"), version(e.get("api_version")),
                       response_hash, e.get("error"), datetime.strptime(e["fetched_at"], "%Y-%m-%dT%H:%M:%SZ")))

run_rows = [(run_date, r["brand_id"], r["brand_name"], r["status"], r.get("list_attempts"), version(r.get("list_version")),
             version(r.get("detail_version")), r.get("products"), r.get("total_records"), r.get("in_scope"),
             r.get("detail_failed"), (r.get("error") or None) and r["error"][:400], r["seconds"]) for r in summary]

load_dotenv(ROOT / ".env")
conn_str = (
    "Driver={ODBC Driver 18 for SQL Server};"
    f"Server=tcp:{os.environ['AZURE_SQL_SERVER']},1433;"
    f"Database={os.environ['AZURE_SQL_DATABASE']};"
    f"Uid={os.environ['AZURE_SQL_USER']};"
    "Pwd={" + os.environ["AZURE_SQL_PASSWORD"].replace("}", "}}") + "};"
    "Encrypt=yes;TrustServerCertificate=no;Connection Timeout=90;"
)
for attempt in range(1, 4):  # the first connection wakes a paused database and can time out
    try:
        conn = pyodbc.connect(conn_str, autocommit=False)
        break
    except pyodbc.OperationalError as e:
        if attempt == 3:
            raise
        print(f"Connection attempt {attempt} failed ({str(e)[:60]}...), retrying in 30 s", flush=True)
        time.sleep(30)
cur = conn.cursor()
cur.fast_executemany = True
try:
    cur.execute("CREATE TABLE #response (response_hash binary(32) PRIMARY KEY, body_gzip varbinary(max) NOT NULL, bytes_raw int NOT NULL)")
    cur.setinputsizes([(pyodbc.SQL_BINARY, 32, 0), (pyodbc.SQL_VARBINARY, 0, 0), (pyodbc.SQL_INTEGER, 0, 0)])  # temp table columns can't be looked up
    cur.executemany("INSERT INTO #response VALUES (?, ?, ?)", [(h, gz, n) for h, (gz, n) in responses.items()])
    cur.setinputsizes(None)
    cur.execute("""INSERT INTO raw.response (response_hash, body_gzip, bytes_raw, first_seen_date)
                   SELECT t.response_hash, t.body_gzip, t.bytes_raw, ? FROM #response AS t
                   WHERE NOT EXISTS (SELECT 1 FROM raw.response AS r WHERE r.response_hash = t.response_hash)""", run_date)
    new_responses = cur.rowcount
    cur.execute("DELETE FROM raw.fetch_log WHERE fetch_date = ?", run_date)
    cur.execute("DELETE FROM raw.collection_run WHERE run_date = ?", run_date)
    cur.executemany("INSERT INTO raw.fetch_log VALUES (?, ?, ?, ?, ?, ?, ?, ?)", fetch_rows)
    cur.executemany("INSERT INTO raw.collection_run VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", run_rows)
    conn.commit()  # raw is saved before parsing, so a parsing failure cannot lose the day
    print(f"{run_date}: responses {len(responses)} distinct, {new_responses} new, {len(responses) - new_responses} already stored "
          f"({sum(n for _, n in responses.values()) / 1e6:.1f} MB raw, {sum(len(gz) for gz, _ in responses.values()) / 1e6:.1f} MB compressed) "
          f"| fetch log {len(fetch_rows)} rows, {sum(r[6] is not None for r in fetch_rows)} errors | brands {len(run_rows)}", flush=True)
    products, rates, rejected = cur.execute("EXEC stg.parse_new_responses").fetchone()
    conn.commit()
    print(f"staging: {products} new products parsed, {rates} rates, {rejected} rates held back")
finally:
    conn.close()
