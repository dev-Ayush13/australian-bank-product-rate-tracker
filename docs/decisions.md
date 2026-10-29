# Decision Records

Each significant design decision and data-source check, newest first.

## DR-005 — Database firewall access for the scheduled collector

**Date:** 2026-10-28 · **Status:** Accepted

**Context:** The Azure SQL server firewall only admits listed IP addresses. GitHub-hosted runners get a different IP address on every run.

**Decision:** Each workflow run signs in to Azure with OpenID Connect (no stored Azure credential), adds a firewall rule for its own IP address, runs the collection and load, then deletes the rule in a step that runs even if earlier steps fail. The workflow identity trusts only this repository's `main` branch and has rights to manage firewall rules on this one SQL server only. The database login password is held in GitHub Actions secrets.

**Alternatives considered:**
- "Allow Azure services and resources to access this server": admits any Azure customer's resources, and GitHub runners being covered is not guaranteed.
- Allow all IP addresses (`0.0.0.0`–`255.255.255.255`): exposes the login to the whole internet.
- Self-hosted runner: needs a machine left on. Static-IP runners: paid plans only.

**Consequences:** The database is reachable from a runner only for the duration of a run. One-off identity setup in Azure. New firewall rules can take a short time to apply, so the first database connection retries.

**Implementation (2026-10-29):**
- User-assigned managed identity with a federated credential (`infra/setup_github_access.sh`). GitHub's OIDC subject includes the owner and repository IDs (`repo:dev-Ayush13@26853697/australian-bank-product-rate-tracker@1436536342:ref:refs/heads/main`); a subject without the IDs was rejected (AADSTS700213). With the IDs, a recreated repository of the same name is not trusted.
- Custom role with only `Microsoft.Sql/servers/firewallRules/read|write|delete`, assigned on the SQL server.
- The workflow loads as a database user `loader` (`sql/02_create_loader_user.sql`): SELECT and INSERT on schema `raw`, DELETE on `raw.fetch_log` and `raw.collection_run` only. The admin login is not used by the workflow.
- The workflow signs in to Azure after collection, so the firewall rule exists only during the load. Raw files are kept as a workflow artifact for 7 days, so a failed load can be loaded by hand.
- First successful run (2026-10-29): 81 minutes; the first database connection timed out while the database resumed and the retry succeeded; the rule was deleted at the end.

## DR-004 — Raw response storage

**Date:** 2026-10-28 · **Status:** Accepted

**Context:** Every number must be traceable to the response a bank published, but GitHub runners are discarded after each run. A one-day sample of the big four was 2.6 MB uncompressed (0.2 MB gzip). Most products do not change from day to day, and `lastUpdated` cannot be used to detect change: on 2026-10-28, 28 of 42 CommBank and 30 of 33 Westpac in-scope products showed that day's date, while ANZ and NAB showed batch changes on 8–9 October.

**Decision:** Store raw responses in the Azure SQL database, compressed, and only when a response's content differs from the last stored version (compared by hash). Record a fetch log row for every request every day (date, bank, product, status, hash), so each day's response can be traced to the stored version it matched.

**Alternatives considered:**
- Commit raw files to the repository daily: daily automated commits and a growing repository.
- Azure Blob Storage: free for the first 12 months only, and a second service to manage.
- Store every response every day: same traceability at many times the storage.

**Consequences:** Change detection is based on content, not on banks' `lastUpdated`. A day with no fetch log row is a gap. If the database is unavailable (for example, paused at the free monthly limit), that day's responses are not stored, and the run must fail visibly.

**Implementation (2026-10-29):**
- Tables: `raw.response` (SHA-256 of the exact bytes received, gzip body), `raw.fetch_log` (one row per request per day; each row has a response hash, an error, or both), `raw.collection_run` (one outcome per brand per day). Script: `sql/01_create_raw_tables.sql`.
- The collector writes `_fetch_log.json` (status, version, UTC time, file or error per request). A partial re-run replaces only the brands it re-ran in that day's summary and fetch log.
- `src/load_raw.py <date>` loads a day in one transaction: new responses only, then replaces that day's fetch log and run rows, so a day can be reloaded without duplicates.
- A detail response without a product (Tyro's error body) is kept and logged with an error, not discarded.
- 28 and 29 October were collected before the fetch log existed; a one-off script (`src/backfill_fetch_log.py`, removed after use; see commits `5fe0a4f` and `e8bc9a9`) rebuilt it from the saved files and run summaries. For those days: times are file times; versions are per brand; status codes of failed requests are blank where the summary recorded only the error type; failed list attempts before a successful retry are not recorded. On 28 October the summary of the last retest was merged into the full-run summary (original kept), and Revolut, which failed in the full run but was collected by an earlier retest whose summary was overwritten, was rebuilt from its files (11/11 products, 9 in scope).
- First load (2026-10-28): 3,153 distinct responses (33.9 MB raw, 6.1 MB compressed), 3,165 fetch log rows (12 errors), 116 brands. Reloading the same day added no responses.
- Second day (2026-10-29): 476 of 3,111 distinct responses were new; 85% were identical to the previous day.
- The paused database can take longer than the 90-second login timeout to resume, so the loader retries the connection up to three times.

## DR-003 — Request settings for bank product APIs

**Date:** 2026-10-28 · **Status:** Accepted (revised 2026-10-28 after the first full collection)

**Context:** The first full collection (116 brands, 2026-10-28) showed four kinds of unreliable response:

| Behaviour | Example | Evidence |
|---|---|---|
| HTTP 200 with zero products and `totalRecords: 0`, at random | Westpac, St.George | Uncached Westpac requests on page sizes 21–23: two returned 65 products, one returned 0 |
| Empty responses cached by the bank's CDN for several minutes | Westpac (CloudFront) | Repeated requests returned the same empty response with `X-Cache: Hit from cloudfront`, `Age` 314–401 s |
| Version range rejected; exact versions accepted | Revolut | `x-v: 10` + `x-min-v: 1` → HTTP 406; `x-v: 5` → 200 |
| HTTP 200 with an error body instead of a product | Tyro Banking (1 product) | Body `errorCode: ERR_ACCOUNT_PERM_UNAVAILABLE` |

An earlier diagnosis attributed Westpac's empty responses to `page-size=100` and to `Accept: */*` with gzip. Uncached testing disproved it: `page-size=100` returned all 65 products. Those results were random empty responses, some of them served from the CDN cache.

Product list and detail endpoints use different versions (most brands: list v5, detail v7; 8 brands use older versions), and banks reject unsupported versions with HTTP 406.

**Decision:**
- Send `Accept: application/json` and a version range (`x-min-v: 1`, `x-v: 10`); if a bank returns 406, try exact versions from 9 down to 1 and keep the first that works for that bank and endpoint. Record the version returned in the `x-v` response header.
- Request lists with `page-size=25`. If a list is empty, its count differs from `totalRecords`, or paging fails after page 1, retry the whole list with other page sizes (each is a separate CDN cache entry, so the retry reaches the bank's server; sizes revised below). Record the number of attempts.
- Label a bank `empty` only when all four attempts return zero products; `count_mismatch` when counts still differ.
- Reject a detail response that contains no `productId` and log it as a failed product (the response itself is kept; see DR-004).
- One bank's or product's failure is logged with its HTTP status and does not stop the run.

**Revision (2026-10-30): repeated entries hide products.** Some banks' page 2 repeats items from page 1, so the entry count matches `totalRecords` while products are missing. On 28 and 29 October: Defence Bank 14 of 52 products missing (12 in scope: most of its home loan range), St.George 1 of 42 (Incentive Saver), Westpac 2–3 of 65 (none in scope); all repeated entries were identical. A single page (`page-size=100`) returned every product for all three. Changes:
- A list is complete only when the number of distinct `productId`s equals `totalRecords`. Repeated entries are collapsed before details are fetched; the raw list pages keep them as received.
- List retries use page sizes 100, 99 and 98 (one large page avoids the faulty paging; each size is still a separate CDN cache entry).
- Any failed list request, including on page 1, moves on to the next attempt. On 30 October AMP (HTTP 400) and Geelong Bank (HTTP 520) failed on page 1 in the scheduled run and returned their full lists a few hours later.
- The 28 and 29 October snapshots for these brands are incomplete and are not repaired. The 30 October snapshot for Defence Bank, St.George, Westpac, AMP and Geelong Bank comes from a same-day re-run with these changes (Defence Bank 52 of 52 products, St.George 42 of 42).

**Alternatives considered:** A hard-coded version per bank and endpoint (breaks whenever a bank upgrades); cache-busting query parameters (non-standard parameters may be rejected); accepting a single response per bank (randomly drops Westpac-group brands).

**Consequences:** Up to three extra list requests for an unreliable bank. In a test run, Westpac needed 3 attempts and St.George 2. List attempts per bank become a data-quality measure (Q11). Responses arrive in several versions, so flattening must handle each version recorded.

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
