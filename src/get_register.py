from datetime import date
from pathlib import Path

import requests

URL = "https://api.cdr.gov.au/cdr-register/v1/banking/data-holders/brands/summary"
HEADERS = {"x-v": "2", "User-Agent": "australian-bank-product-rate-tracker (portfolio project; github.com/dev-Ayush13)"}
OUT_DIR = Path(__file__).resolve().parents[1] / "data" / "raw" / "register"

resp = requests.get(URL, headers=HEADERS, timeout=30)
resp.raise_for_status()

OUT_DIR.mkdir(parents=True, exist_ok=True)
out_file = OUT_DIR / f"{date.today():%Y-%m-%d}.json"
out_file.write_bytes(resp.content)

body = resp.json()
brands = body["data"]
print(f"Saved {out_file.name} ({len(resp.content):,} bytes)")
print(f"Top-level keys: {list(body)}")
print(f"Banking brands listed: {len(brands)}")
print(f"Fields per brand: {list(brands[0])}")
for name in ["CommBank", "Westpac", "NAB", "ANZ"]:
    matches = [f"{b['brandName']} -> {b['publicBaseUri']}" for b in brands if name.lower() in b["brandName"].lower()]
    print(f"{name}: {matches}")
