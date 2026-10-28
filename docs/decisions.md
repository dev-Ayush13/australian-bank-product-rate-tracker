# Decision Records

Each significant design decision and data-source check, newest first.

## DR-003 — Request settings for bank product APIs

**Date:** 2026-10-28 · **Status:** Accepted

**Context:** A first collection from the big four returned complete data for CommBank, NAB and ANZ, but Westpac returned HTTP 200 with zero products and `totalRecords: 0`, with no error. Testing showed two separate triggers, each producing the same silent empty response from Westpac:

| Request | Westpac result |
|---|---|
| `page-size=99` or less, `Accept: application/json` | 65 products |
| `page-size=100` (any headers) | 0 products |
| `Accept: */*` with `Accept-Encoding: gzip` (Python `requests` defaults) | 0 products |

The product list and product detail endpoints also use different versions (list v5, detail v7 at CommBank, NAB, ANZ and Westpac on 2026-10-28), and banks reject unsupported versions with HTTP 406.

**Decision:**
- Send `Accept: application/json` on every request.
- Use `page-size=25`, the standard's default, which every bank must support.
- Send a version range (`x-min-v: 1`, `x-v: 10`) and let each bank answer with its highest supported version; record the version returned in the `x-v` response header.
- Flag any bank whose collected product count is zero or differs from its `totalRecords`.

**Alternatives considered:** A hard-coded version per bank and endpoint (breaks whenever a bank upgrades); a larger page size to reduce requests (fails silently at Westpac).

**Consequences:** A few more page requests per bank. Silent empty responses are caught instead of being loaded as "bank has no products". Responses may arrive in different versions across banks, so flattening must handle each version recorded.

## DR-002 — Business questions the data can support

**Date:** 2026-10-28 · **Status:** Accepted

**Context:** Before modelling, each business question was checked against the published fields of the big four (CommBank, Westpac, NAB, ANZ), using product details collected on 2026-10-28.

**Field coverage (home loan rates, savings products, term deposit rates):**

| Field | CommBank | Westpac | NAB | ANZ |
|---|---|---|---|---|
| Home loan rate entries | 75 | 190 | 184 | 131 |
| …with loan purpose and repayment type | 75 | 190 | 184 | 131 |
| …with LVR tier | 46 | 183 | 172 | 94 |
| …with comparison rate | 66 | 185 | 183 | 131 |
| Fixed terms published | 1–5 yrs | 1–5 yrs (as months) | 1–5 yrs | 1–5, 7, 10 yrs |
| Savings products with a bonus rate | 2 | 3 | 2 | 1 |
| Savings products with a periodic fee | 18 | 18 | 4 | 4 |
| Fee waiver entries | 22 | 15 | 0 | 1 |
| Term deposit rates with a term | 509 of 509 | 126 of 126 | 102 of 102 | 156 of 156 |

**Decision:** Keep all 11 questions, with these conditions:
- Q1–Q2 use only RBA decisions made after collection starts.
- Q3 compares rates within the LVR band they state; rates published without an LVR tier are kept and labelled as such, not assigned a band.
- Q4 excludes rates without a comparison rate and reports how many were excluded.
- Q5 standardises term formats (Westpac publishes `P12M`, others `P1Y`) and compares only terms all banks publish (1–5 years).
- Q7 separates existing-customer and holding-period rates from new-deposit rates.
- Q9's waiver analysis is limited where banks publish no structured waivers (NAB: none); fee amounts remain comparable.

**Alternatives considered:** Dropping Q9 waivers or Q4; not needed, as coverage is sufficient with stated exclusions.

**Consequences:** Exclusions and gaps are reported in the validation results and feed Q11 (data completeness by bank).

## DR-001 — Use public CDR Product Reference Data as the data source

**Date:** 2026-10-28 · **Status:** Accepted

**Context:** The project needs current rates, fees and product details for all Australian banks, collected daily.

**Decision:** Use the public, unauthenticated Consumer Data Right Product Reference Data APIs, with each bank's API address taken from the CDR Register at run time.

**Alternatives considered:** Scraping bank websites (inconsistent layouts, unclear permission, fragile); third-party comparison sites (terms restrict reuse, coverage unknown).

**Consequences:** One standard format across all banks and clear permission to access. Rate history starts only on the first collection day. Each bank may support different API versions, which the collector must handle.
