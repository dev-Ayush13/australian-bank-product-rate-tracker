# Decision Records

Each significant design decision and data-source check, newest first.

## DR-001 — Use public CDR Product Reference Data as the data source

**Date:** 2026-10-28 · **Status:** Accepted

**Context:** The project needs current rates, fees and product details for all Australian banks, collected daily.

**Decision:** Use the public, unauthenticated Consumer Data Right Product Reference Data APIs, with each bank's API address taken from the CDR Register at run time.

**Alternatives considered:** Scraping bank websites (inconsistent layouts, unclear permission, fragile); third-party comparison sites (terms restrict reuse, coverage unknown).

**Consequences:** One standard format across all banks and clear permission to access. Rate history starts only on the first collection day. Each bank may support different API versions, which the collector must handle.
