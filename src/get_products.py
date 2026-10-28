import json
import time
from collections import Counter
from datetime import date
from pathlib import Path

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

RAW_DIR = Path(__file__).resolve().parents[1] / "data" / "raw"
BRANDS = ["CommBank", "Westpac", "NATIONAL AUSTRALIA BANK", "ANZ"]
IN_SCOPE = {"RESIDENTIAL_MORTGAGES", "TRANS_AND_SAVINGS_ACCOUNTS", "TERM_DEPOSITS"}

register_file = max((RAW_DIR / "register").glob("*.json"))
base_uris = {b["brandName"]: b["publicBaseUri"] for b in json.loads(register_file.read_text(encoding="utf-8"))["data"]}

session = requests.Session()
session.headers.update({"x-v": "10", "x-min-v": "1", "Accept": "application/json", "User-Agent": "australian-bank-product-rate-tracker (portfolio project; github.com/dev-Ayush13)"})
session.mount("https://", HTTPAdapter(max_retries=Retry(total=3, backoff_factor=2, status_forcelist=[429, 500, 502, 503, 504])))

out_dir = RAW_DIR / "products" / f"{date.today():%Y-%m-%d}"
print(f"Register file: {register_file.name}")

for brand in BRANDS:
    base_uri, slug = base_uris[brand], brand.lower().replace(" ", "-")
    detail_dir = out_dir / f"{slug}_detail"
    detail_dir.mkdir(parents=True, exist_ok=True)

    url = f"{base_uri}/cds-au/v1/banking/products?page-size=25"
    products, page = [], 0
    while url:
        page += 1
        resp = session.get(url, timeout=30)
        resp.raise_for_status()
        (out_dir / f"{slug}_p{page}.json").write_bytes(resp.content)
        body = resp.json()
        products += body["data"]["products"]
        url = body["links"].get("next")
        time.sleep(1)
    list_version = resp.headers.get("x-v")
    if not products or len(products) != body["meta"].get("totalRecords"):
        print(f"WARNING: {brand} returned {len(products)} products vs totalRecords {body['meta'].get('totalRecords')}")

    in_scope = [p for p in products if p["productCategory"] in IN_SCOPE]
    for p in in_scope:
        resp = session.get(f"{base_uri}/cds-au/v1/banking/products/{p['productId']}", timeout=30)
        resp.raise_for_status()
        (detail_dir / f"{p['productId']}.json").write_bytes(resp.content)
        time.sleep(1)

    print(f"\n{brand} | {base_uri} | versions: list {list_version}, detail {resp.headers.get('x-v')}")
    print(f"  Pages: {page} | products: {len(products)} | totalRecords: {body['meta'].get('totalRecords')} | unique ids: {len({p['productId'] for p in products})}")
    print(f"  In scope: {dict(Counter(p['productCategory'] for p in in_scope))} | detail files: {len(list(detail_dir.glob('*.json')))}")
    print(f"  Tailored (in scope): {sum(p['isTailored'] for p in in_scope)}")
