# Validation

What is checked, when, and the latest results. The policy behind these checks (scope, materiality, fix forward) is in [DR-010](decisions.md#dr-010--data-quality-policy-and-unattended-operation).

## Integrity and reconciliation

Checked with queries 1–3 of `sql/07_eda.sql` on 10 November 2026 (28 October to 10 November):

| Check | Result |
|---|---|
| Duplicate keys and broken links that can occur (bank or cash rate date listed twice, product listed twice on a day, facts pointing to a missing bank) | 0 in all five checks |
| Successful product detail replies that reached staging and the reporting views | 41,528 of 41,528 (109 requests failed; 0 rejected whole; 0 unaccounted) |
| Days without a collection | 0 of 14 |

## Data rules (version 1.1, 10 November 2026)

Every value that breaks a rule is kept in the data, handled as below, and listed in `mart.fact_data_exception` (`sql/06_create_mart_facts.sql`), one row per day, bank, product and rule. That view also answers Q11.

| Rule | Check | Handling | 10 Nov 2026 rows (banks) |
|---|---|---|---|
| C1 | Bank not fully collected: failed, empty, count mismatch or product details failed | Day kept as collected, never filled | 9 (9) |
| S1 | Value held back in staging: unreadable term, rate written as a percentage, missing fields ([DR-006](decisions.md#dr-006--staging-layer-and-cleaning-rules)) | Held back in `stg.reject` with its original value | 114 (6) |
| M1 | Full promotional rate published as a discount (4% or more) | Analysed as `INTRODUCTORY` ([DR-008](decisions.md#dr-008--discounts-and-promotional-rates-in-home-loan-comparisons)) | 13 (5) |
| M2 | Bundle fixed rate without a coded term | Outside comparisons | 64 (1) |
| M3 | Implausible rate: home loan below 3% or above 15%, deposit above 10% | Outside comparisons (`is_implausible`) | 4 (3) |
| M4 | Placeholder dollar maximum ($50 million or more; real caps reach $20 million) | Treated as no cap | 240 (13) |
| M5 | Discount between 3% and 5%, close to the 4% line of M1 | Review | 0 |
| M6 | Margin discount without loan purpose or repayment type, so it cannot be matched to a rate | Not applied; review | 0 |
| M7 | Savings headline taken from a total stated in the bank's bonus text ([DR-011](decisions.md#dr-011--savings-headline-rate)) | Stated total used | 5 (2) |
| M8 | Bonus limited to new accounts or the first months, published as a bonus | Analysed as `INTRODUCTORY`, left out of the headline | 13 (8) |
| M9 | Rate published with several tiers of one unit | Read as one band from the lowest minimum to the highest maximum ([DR-012](decisions.md#dr-012--rates-published-with-several-tiers-of-one-unit)) | 42 (8) |

On 10 November 2026, after these rules: no home loan or deposit rate in the facts carries a dollar maximum of $50 million or more, the three implausible home loan rates (0.00%, 2.79%, 2.79%) are out of best-rate figures, and the cheapest Standard owner-occupied principal-and-interest variable rate at 80% LVR is 5.93%. Savings headlines at $10,000 matched the expected values for the 11 accounts reviewed by hand (including Up 5.60%, NAB iSaver 1.85%, CommBank GoalSaver 5.25%); the highest is 6.01%. After version 1.1, every savings account with a compared base rate has one at a standard balance, except 2 that publish it only outside those balances.

## Weekly health check

Run `sql/08_weekly_health.sql` on Mondays. It is read-only and covers the 7 Sydney days up to yesterday:

1. Days with no collection at all.
2. Bank outcomes per day, naming big four and peer group brands not fully collected.
3. Exceptions by rule, this week against last week.
4. New bank and rule pairs, not seen in the four weeks before.

Only new items that meet the materiality rule of DR-010 lead to a change; everything else stays recorded.

First run, 10 November 2026 (3–9 November): no missing days; 105–106 of 116 brands fully collected each day. Big four and peer group brands not fully collected: HSBC and CBA – CommBiz (publish no products), Bank of Queensland and ME Bank – ME Go (1–2 product details fail daily), and Bank of Melbourne on 6 November (1 product detail), the only new pair. Not material: a single product missing for one day.
