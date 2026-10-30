from datetime import date
from pathlib import Path

import requests

URL = "https://www.rba.gov.au/statistics/tables/csv/a2-data.csv"  # RBA table A2, changes in the cash rate target (CC BY 4.0)
HEADERS = {"User-Agent": "australian-bank-product-rate-tracker (portfolio project; github.com/dev-Ayush13)"}
OUT_DIR = Path(__file__).resolve().parents[1] / "data" / "raw" / "rba"

resp = requests.get(URL, headers=HEADERS, timeout=30)
resp.raise_for_status()

OUT_DIR.mkdir(parents=True, exist_ok=True)
out_file = OUT_DIR / f"{date.today():%Y-%m-%d}.csv"
out_file.write_bytes(resp.content)
print(f"Saved {out_file.name} ({len(resp.content):,} bytes)")
