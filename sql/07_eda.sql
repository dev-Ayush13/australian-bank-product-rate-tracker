-- Exploratory data analysis of the reporting views (read-only). Run the setup (query 0) first, then any query in the same connection.
-- Rates are in % and changes in percentage points (pp). "Latest day" is the last collection day. Compared rates follow the report's rules (in_comparison).

--0. Setup: each view read once. in_comparison = generally available, not a discount adjustment, plausible and, for home loans, a Standard loan
SET NOCOUNT ON;
DROP TABLE IF EXISTS #b, #p, #pd, #l, #d, #s, #h, #f, #e;
DECLARE @day date = (SELECT MAX([date]) FROM mart.fact_product_day);
SELECT * INTO #b FROM mart.dim_bank;
SELECT * INTO #p FROM mart.dim_product;
SELECT f.*, b.brand_name, b.bank_group, b.segment, p.name, p.loan_type INTO #pd
FROM mart.fact_product_day AS f JOIN #b AS b ON b.brand_id = f.brand_id JOIN #p AS p ON p.product_key = f.product_key WHERE f.[date] = @day;
SELECT r.*, d.brand_name, d.bank_group, d.segment, CAST(r.rate * 100 AS float) AS pct, CAST(r.comparison_rate * 100 AS float) AS comparison_pct,
       IIF(r.is_restricted = 0 AND r.is_adjustment = 0 AND r.is_implausible = 0 AND d.loan_type = 'Standard', 1, 0) AS in_comparison
INTO #l FROM mart.fact_lending_rate AS r JOIN #pd AS d ON d.product_key = r.product_key WHERE r.[date] = @day;
SELECT r.*, d.brand_name, d.bank_group, d.segment, CAST(r.rate * 100 AS float) AS pct, IIF(r.is_restricted = 0 AND r.is_implausible = 0, 1, 0) AS in_comparison
INTO #d FROM mart.fact_deposit_rate AS r JOIN #pd AS d ON d.product_key = r.product_key WHERE r.[date] = @day;
SELECT s.*, b.brand_name, b.bank_group, b.segment, p.product_category, CAST(s.rate * 100 AS float) AS pct, CAST(s.change * 100 AS float) AS change_pp,
       IIF(s.[date] = @day, 1, 0) AS is_latest,
       CONCAT(CASE WHEN s.kind = 'L' THEN 'Home loan' WHEN p.product_category = 'TERM_DEPOSITS' THEN 'Term deposit' ELSE 'Savings' END, ' ', LOWER(s.rate_type)) AS product_type
INTO #s FROM mart.fact_segment_rate AS s JOIN #b AS b ON b.brand_id = s.brand_id JOIN #p AS p ON p.product_key = s.product_key
WHERE (s.kind = 'D' OR p.loan_type = 'Standard') AND (s.[date] = @day OR s.change <> 0);
SELECT h.*, d.brand_name, d.bank_group, d.segment, CAST(h.headline_rate * 100 AS float) AS headline_pct, CAST(h.base_rate * 100 AS float) AS base_pct,
       CAST(h.bonus_rate * 100 AS float) AS bonus_pct
INTO #h FROM mart.fact_savings_headline AS h JOIN #pd AS d ON d.product_key = h.product_key WHERE h.[date] = @day;
SELECT f.*, d.segment INTO #f FROM mart.fact_account_fee AS f JOIN #pd AS d ON d.product_key = f.product_key WHERE f.[date] = @day;
SELECT e.*, b.brand_name, b.segment, IIF(e.[date] = @day, 1, 0) AS is_latest INTO #e FROM mart.fact_data_exception AS e JOIN #b AS b ON b.brand_id = e.brand_id;

-- A. Integrity

--1. Keys and links that can break (expected 0 each; the other keys and links follow from these, the primary keys or the GROUP BY in the views)
SELECT 'dim_bank: brand listed twice' AS check_name, COUNT(*) - COUNT(DISTINCT brand_id) AS failures FROM #b
UNION ALL SELECT 'fact_product_day: product listed twice on a day', COUNT(*) - COUNT(DISTINCT CONCAT([date], '|', product_key)) FROM mart.fact_product_day
UNION ALL SELECT 'fact_cash_rate: date listed twice', COUNT(*) - COUNT(DISTINCT [date]) FROM mart.fact_cash_rate
UNION ALL SELECT 'fact_product_day: bank missing from dim_bank', COUNT(*) FROM mart.fact_product_day AS f WHERE NOT EXISTS (SELECT 1 FROM #b AS b WHERE b.brand_id = f.brand_id)
UNION ALL SELECT 'fact_collection: bank missing from dim_bank', COUNT(*) FROM mart.fact_collection AS f WHERE NOT EXISTS (SELECT 1 FROM #b AS b WHERE b.brand_id = f.brand_id);

--2. Reconciliation: each successful product detail reply is parsed into staging (and so reaches the views) or rejected whole. Total row, then any day with unaccounted replies (expected none)
SELECT f.fetch_date AS [date], COUNT(DISTINCT f.fetch_date) AS days, COUNT(*) AS detail_replies, COUNT(f.error) AS errors,
       COUNT(IIF(f.error IS NULL, p.response_hash, NULL)) AS parsed, COUNT(IIF(f.error IS NULL, x.response_hash, NULL)) AS rejected_whole,
       SUM(IIF(f.error IS NULL AND p.response_hash IS NULL AND x.response_hash IS NULL, 1, 0)) AS unaccounted
FROM raw.fetch_log AS f LEFT JOIN stg.product AS p ON p.response_hash = f.response_hash
LEFT JOIN (SELECT DISTINCT response_hash FROM stg.reject WHERE area = 'product') AS x ON x.response_hash = f.response_hash
WHERE f.request_key LIKE 'detail/%'
GROUP BY GROUPING SETS ((f.fetch_date), ())
HAVING GROUPING(f.fetch_date) = 1 OR SUM(IIF(f.error IS NULL AND p.response_hash IS NULL AND x.response_hash IS NULL, 1, 0)) > 0
ORDER BY GROUPING(f.fetch_date) DESC, [date];

-- B. Coverage and market structure

--3. Coverage per day: banks by collection outcome and products by category (a day without a collection shows blanks)
SELECT t.[date], c.banks, c.ok, c.partly_collected, c.no_products, p.home_loans, p.savings_accounts, p.term_deposits
FROM mart.dim_date AS t
LEFT JOIN (SELECT [date], COUNT(*) AS banks, SUM(IIF(status = 'ok', 1, 0)) AS ok, SUM(IIF(status IN ('detail_errors', 'count_mismatch'), 1, 0)) AS partly_collected,
                  SUM(IIF(status IN ('failed', 'empty'), 1, 0)) AS no_products FROM mart.fact_collection GROUP BY [date]) AS c ON c.[date] = t.[date]
LEFT JOIN (SELECT [date], SUM(IIF(product_category = 'RESIDENTIAL_MORTGAGES', 1, 0)) AS home_loans, SUM(IIF(product_category = 'TRANS_AND_SAVINGS_ACCOUNTS', 1, 0)) AS savings_accounts,
                  SUM(IIF(product_category = 'TERM_DEPOSITS', 1, 0)) AS term_deposits FROM mart.fact_product_day GROUP BY [date]) AS p ON p.[date] = t.[date]
ORDER BY t.[date];

--4. Market structure, latest day: products and banks by category and segment, with the segment's share of the category's products
SELECT product_category, segment, COUNT(*) AS products, COUNT(DISTINCT brand_id) AS banks,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY product_category) AS decimal(5, 1)) AS pct_of_products
FROM #pd GROUP BY product_category, segment ORDER BY product_category, segment;

--5. White labels, latest day: products sold under the same name by several brands of one group (each copy counts in segment medians)
WITH n AS (SELECT bank_group, name, product_category, COUNT(DISTINCT brand_id) AS brands, COUNT(*) AS products FROM #pd GROUP BY bank_group, name, product_category)
SELECT bank_group, SUM(products) AS products, SUM(IIF(brands > 1, products, 0)) AS products_sharing_a_name, SUM(IIF(brands > 1, 1, 0)) AS shared_names, MAX(brands) AS most_brands
FROM n GROUP BY bank_group HAVING MAX(brands) > 1 ORDER BY products_sharing_a_name DESC;

-- C. Data quality (Q11)

--6. Data exceptions by rule (catalogue in docs/validation.md; rules without rows are not listed): rows and banks on the latest day, days seen, focus brands on the latest day
SELECT e.rule_id, SUM(e.is_latest) AS rows_latest_day, COUNT(DISTINCT IIF(e.is_latest = 1, e.brand_id, NULL)) AS banks_latest_day, COUNT(DISTINCT e.[date]) AS days_seen,
       (SELECT STRING_AGG(x.brand_name, ', ') WITHIN GROUP (ORDER BY x.brand_name)
        FROM (SELECT DISTINCT brand_name FROM #e AS y WHERE y.rule_id = e.rule_id AND y.is_latest = 1 AND y.segment <> 'Rest of market') AS x) AS focus_brands_latest_day
FROM #e AS e GROUP BY e.rule_id ORDER BY e.rule_id;

--7. Completeness of home loan rates, latest day (% of rates; discount adjustments left out)
SELECT COUNT(*) AS rates, CAST(100 * AVG(IIF(comparison_rate IS NULL, 1.0, 0)) AS decimal(5, 1)) AS pct_no_comparison_rate,
       CAST(100 * AVG(IIF(lvr_range = 'Any', 1.0, 0)) AS decimal(5, 1)) AS pct_no_lvr_tier,
       CAST(100 * AVG(IIF(analysis_type = 'FIXED', IIF(term_months IS NULL, 1.0, 0), NULL)) AS decimal(5, 1)) AS pct_fixed_without_term,
       CAST(100 * AVG(1.0 * is_restricted) AS decimal(5, 1)) AS pct_restricted, CAST(100 * AVG(1.0 * in_comparison) AS decimal(5, 1)) AS pct_compared
FROM #l WHERE is_adjustment = 0;

--8. Validity checks the exception rules don't cover, latest day: violations and banks
SELECT 'negative rate' AS rule_check, COUNT(*) AS violations, COUNT(DISTINCT brand_id) AS banks
FROM (SELECT brand_id FROM #l WHERE rate < 0 UNION ALL SELECT brand_id FROM #d WHERE rate < 0) AS v
UNION ALL SELECT 'comparison rate more than 3 points above the rate', COUNT(*), COUNT(DISTINCT brand_id) FROM #l WHERE comparison_pct - pct > 3
UNION ALL SELECT 'LVR bound outside 0-100%', COUNT(*), COUNT(DISTINCT brand_id) FROM #l WHERE lvr_min < 0 OR lvr_max > 1
UNION ALL SELECT 'fixed home loan term over 30 years', COUNT(*), COUNT(DISTINCT brand_id) FROM #l WHERE term_months > 360
UNION ALL SELECT 'rate tier minimum above maximum', COUNT(*), COUNT(DISTINCT d.brand_id) FROM stg.rate_tier AS t JOIN #pd AS d ON d.response_hash = t.response_hash
          WHERE t.minimum_value > t.maximum_value
UNION ALL SELECT 'negative fee', COUNT(*), COUNT(DISTINCT d.brand_id) FROM stg.fee AS f JOIN #pd AS d ON d.response_hash = f.response_hash WHERE f.amount < 0 OR f.amount_min < 0
UNION ALL SELECT 'fee minimum above maximum', COUNT(*), COUNT(DISTINCT d.brand_id) FROM stg.fee AS f JOIN #pd AS d ON d.response_hash = f.response_hash WHERE f.amount_min > f.amount_max;

--9. Products with compared rates that never reach a comparison, latest day: home loans at no LVR point (60-90%), savings accounts with no base rate at any
--   standard balance. Likely reason: a rate published with several tiers of one unit (the views read them as one band), a band with its minimum above its
--   maximum, else bands outside the points. Big four and peer brands listed one by one
WITH m AS (
    SELECT 'Home loan' AS kind, 'L' AS rate_kind, brand_name, segment, product_key, MAX(IIF(lvr_min > lvr_max, 1, 0)) AS inverted FROM #l AS l
    WHERE in_comparison = 1 AND NOT EXISTS (SELECT 1 FROM #s AS s WHERE s.is_latest = 1 AND s.product_key = l.product_key) GROUP BY brand_name, segment, product_key
    UNION ALL
    SELECT 'Savings', 'D', brand_name, segment, product_key, MAX(IIF(balance_min > balance_max, 1, 0)) FROM #d AS d
    WHERE in_comparison = 1 AND analysis_type = 'VARIABLE' AND product_category = 'TRANS_AND_SAVINGS_ACCOUNTS'
      AND NOT EXISTS (SELECT 1 FROM #h AS h WHERE h.product_key = d.product_key AND h.base_rate IS NOT NULL) GROUP BY brand_name, segment, product_key),
r AS (SELECT m.*, CASE WHEN EXISTS (SELECT 1 FROM stg.rate_tier AS t JOIN #pd AS p ON p.response_hash = t.response_hash WHERE p.product_key = m.product_key
                                    AND t.rate_kind = m.rate_kind GROUP BY t.rate_seq, t.unit_of_measure HAVING COUNT(*) > 1) THEN 'a rate with several tiers of one unit'
                       WHEN m.inverted = 1 THEN 'band minimum above maximum' ELSE 'bands outside the points' END AS reason
      FROM m)
SELECT kind, reason, segment, IIF(segment = 'Rest of market', segment, brand_name) AS bank, COUNT(*) AS products, COUNT(DISTINCT brand_name) AS banks
FROM r GROUP BY kind, reason, segment, IIF(segment = 'Rest of market', segment, brand_name) ORDER BY kind, reason, segment, products DESC;

--10. Days since banks last updated each product, latest day
SELECT a.age, COUNT(*) AS products, MIN(p.days_since_update) AS min_days, MAX(p.days_since_update) AS max_days
FROM #pd AS p
CROSS APPLY (SELECT CASE WHEN p.days_since_update IS NULL THEN 'not published' WHEN p.days_since_update < 0 THEN 'date in the future'
                         WHEN p.days_since_update <= 7 THEN '0-7 days' WHEN p.days_since_update <= 30 THEN '8-30 days' WHEN p.days_since_update <= 90 THEN '31-90 days'
                         WHEN p.days_since_update <= 365 THEN '91-365 days' ELSE 'over a year' END AS age) AS a
GROUP BY a.age ORDER BY MIN(p.days_since_update);

--11. Data quality scorecard per bank, worst first (banks with any issue): collection over all days; exceptions, home loan rates without a comparison rate
--    and products not updated in a year on the latest day
WITH c AS (SELECT brand_id, COUNT(*) AS days_listed, SUM(IIF(status IN ('failed', 'empty'), 1, 0)) AS days_no_products,
                  SUM(IIF(status IN ('detail_errors', 'count_mismatch'), 1, 0)) AS days_partly_collected, SUM(COALESCE(detail_failed, 0)) AS failed_details,
                  MAX(IIF(status <> 'ok', [date], NULL)) AS last_issue FROM mart.fact_collection GROUP BY brand_id),
     e AS (SELECT brand_id, COUNT(*) AS exceptions FROM #e WHERE is_latest = 1 AND rule_id <> 'C1' GROUP BY brand_id),
     l AS (SELECT brand_id, AVG(IIF(comparison_rate IS NULL, 1.0, 0)) AS no_comparison FROM #l WHERE is_adjustment = 0 GROUP BY brand_id),
     p AS (SELECT brand_id, AVG(IIF(days_since_update > 365, 1.0, 0)) AS stale FROM #pd GROUP BY brand_id)
SELECT b.brand_name, b.segment, n.days - c.days_listed AS days_not_listed, c.days_no_products, c.days_partly_collected, c.failed_details, c.last_issue,
       COALESCE(e.exceptions, 0) AS exceptions_latest_day, CAST(100 * l.no_comparison AS decimal(5, 1)) AS pct_home_loan_rates_no_comparison,
       CAST(100 * p.stale AS decimal(5, 1)) AS pct_products_not_updated_in_a_year
FROM #b AS b JOIN c ON c.brand_id = b.brand_id CROSS JOIN (SELECT COUNT(*) AS days FROM mart.dim_date) AS n
LEFT JOIN e ON e.brand_id = b.brand_id LEFT JOIN l ON l.brand_id = b.brand_id LEFT JOIN p ON p.brand_id = b.brand_id
WHERE c.days_listed < n.days OR c.days_no_products + c.days_partly_collected > 0 OR e.exceptions > 0 OR l.no_comparison > 0 OR p.stale > 0
ORDER BY c.days_no_products DESC, c.days_partly_collected DESC, exceptions_latest_day DESC, l.no_comparison DESC, p.stale DESC;

-- D. Distributions and anomalies

--12. Profile of the compared rates by product and rate type, latest day (best rate changes: all days): count, missing, quartiles, mean, standard deviation,
--    skewness and excess kurtosis (population moments)
WITH v AS (
    SELECT 'Home loan rate' AS measure, analysis_type AS rate_type, pct AS x FROM #l WHERE in_comparison = 1
    UNION ALL SELECT 'Home loan comparison rate', analysis_type, comparison_pct FROM #l WHERE in_comparison = 1
    UNION ALL SELECT IIF(product_category = 'TERM_DEPOSITS', 'Term deposit rate', 'Savings rate'), analysis_type, pct FROM #d WHERE in_comparison = 1
    UNION ALL SELECT 'Savings headline', 'at $10,000', headline_pct FROM #h WHERE is_default_balance = 1
    UNION ALL SELECT 'Best rate change (pp)', product_type, change_pp FROM #s WHERE change <> 0),
m AS (SELECT *, AVG(x) OVER (PARTITION BY measure, rate_type) AS mean_x, STDEVP(x) OVER (PARTITION BY measure, rate_type) AS sd_x,
             PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY x) OVER (PARTITION BY measure, rate_type) AS p25,
             PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY x) OVER (PARTITION BY measure, rate_type) AS p50,
             PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY x) OVER (PARTITION BY measure, rate_type) AS p75 FROM v)
SELECT measure, rate_type, COUNT(x) AS n, COUNT(*) - COUNT(x) AS missing, ROUND(MIN(x), 2) AS min_value, ROUND(MAX(p25), 2) AS p25, ROUND(MAX(p50), 2) AS median,
       ROUND(MAX(p75), 2) AS p75, ROUND(MAX(x), 2) AS max_value, ROUND(MAX(mean_x), 2) AS mean, ROUND(MAX(sd_x), 2) AS std_dev,
       ROUND(AVG(POWER((x - mean_x) / NULLIF(sd_x, 0), 3)), 2) AS skewness, ROUND(AVG(POWER((x - mean_x) / NULLIF(sd_x, 0), 4)) - 3, 2) AS excess_kurtosis
FROM m GROUP BY measure, rate_type ORDER BY measure, n DESC;

--13. Outliers that could top a best-rate list, latest day: compared home loan rates below, and deposit rates above, 1.5 x the interquartile range of their type
--    (types with at least 30 rates), by bank
WITH r AS (
    SELECT 'Home loan' AS product, analysis_type, brand_name, segment, pct FROM #l WHERE in_comparison = 1
    UNION ALL SELECT IIF(product_category = 'TERM_DEPOSITS', 'Term deposit', 'Savings'), analysis_type, brand_name, segment, pct FROM #d WHERE in_comparison = 1),
q AS (SELECT *, COUNT(*) OVER (PARTITION BY product, analysis_type) AS n, PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY pct) OVER (PARTITION BY product, analysis_type) AS q1,
             PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY pct) OVER (PARTITION BY product, analysis_type) AS q3 FROM r)
SELECT product, analysis_type, brand_name, segment, COUNT(*) AS rates, ROUND(MIN(pct), 2) AS min_pct, ROUND(MAX(pct), 2) AS max_pct,
       ROUND(MAX(IIF(product = 'Home loan', q1 - 1.5 * (q3 - q1), q3 + 1.5 * (q3 - q1))), 2) AS fence_pct
FROM q WHERE n >= 30 AND IIF(product = 'Home loan', q1 - 1.5 * (q3 - q1) - pct, pct - q3 - 1.5 * (q3 - q1)) > 0
GROUP BY product, analysis_type, brand_name, segment ORDER BY product, analysis_type, rates DESC;

--14. Products with a lower best rate at a higher LVR point, latest day, by bank (risk pricing usually rises with LVR)
WITH s AS (SELECT s.brand_name, s.segment, s.product_key, p.name, s.product_type, s.loan_purpose, s.repayment_type, s.term_months, s.lvr_point, s.pct,
                  LAG(s.pct) OVER (PARTITION BY s.product_key, s.rate_type, s.loan_purpose, s.repayment_type, s.term_months, s.term_days ORDER BY s.lvr_point) AS pct_lower_lvr
           FROM #s AS s JOIN #p AS p ON p.product_key = s.product_key WHERE s.is_latest = 1 AND s.kind = 'L')
SELECT brand_name, segment, COUNT(*) AS cases, COUNT(DISTINCT product_key) AS products, ROUND(MAX(pct_lower_lvr - pct), 2) AS largest_drop_pp,
       MIN(CONCAT(name, ': ', product_type, ' ', loan_purpose, ' ', repayment_type, IIF(term_months IS NULL, '', CONCAT(' ', term_months, ' months')),
                  ' at ', CAST(lvr_point * 100 AS int), '% LVR')) AS example
FROM s WHERE pct < pct_lower_lvr GROUP BY brand_name, segment ORDER BY cases DESC;

--15. Compared variable P&I home loan rates with a comparison rate below the rate, latest day, by bank, and how many of those products publish a margin discount
--    (fixed and interest-only rates are left out: their comparison rate includes a later, usually lower, rate)
SELECT COALESCE(l.brand_name, 'All banks') AS bank, l.segment, COUNT(*) AS rates, COUNT(DISTINCT l.product_key) AS products,
       COUNT(DISTINCT x.product_key) AS products_with_discount, ROUND(AVG(l.pct - l.comparison_pct), 2) AS avg_gap_pp
FROM #l AS l LEFT JOIN (SELECT DISTINCT product_key FROM #l WHERE is_adjustment = 1) AS x ON x.product_key = l.product_key
WHERE l.in_comparison = 1 AND l.analysis_type = 'VARIABLE' AND l.repayment_type = 'PRINCIPAL_AND_INTEREST' AND l.comparison_pct < l.pct
GROUP BY GROUPING SETS ((l.brand_name, l.segment), ()) ORDER BY GROUPING(l.brand_name) DESC, rates DESC;

-- E. Home loans (Q3-Q5)

--16. Median best variable rate by loan purpose and repayment type at each LVR point, latest day (%), with the products compared at 80%
WITH s AS (SELECT loan_purpose, repayment_type, lvr_point, PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY pct) OVER (PARTITION BY loan_purpose, repayment_type, lvr_point) AS median_pct
           FROM #s WHERE is_latest = 1 AND kind = 'L' AND rate_type = 'VARIABLE')
SELECT loan_purpose, repayment_type, SUM(IIF(lvr_point = 0.8, 1, 0)) AS products_at_80, ROUND(MAX(IIF(lvr_point = 0.6, median_pct, NULL)), 2) AS lvr_60_pct,
       ROUND(MAX(IIF(lvr_point = 0.7, median_pct, NULL)), 2) AS lvr_70_pct, ROUND(MAX(IIF(lvr_point = 0.8, median_pct, NULL)), 2) AS lvr_80_pct,
       ROUND(MAX(IIF(lvr_point = 0.9, median_pct, NULL)), 2) AS lvr_90_pct
FROM s GROUP BY loan_purpose, repayment_type ORDER BY products_at_80 DESC;

--17. Fixed rate curve: median best owner-occupier P&I rate at 80% LVR for 1 to 5 years, by segment and market, latest day (%)
WITH s AS (SELECT g.grp, s.term_months, PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY s.pct) OVER (PARTITION BY g.grp, s.term_months) AS median_pct
           FROM #s AS s CROSS APPLY (VALUES (s.segment), ('Market')) AS g (grp)
           WHERE s.is_latest = 1 AND s.kind = 'L' AND s.rate_type = 'FIXED' AND s.lvr_point = 0.8 AND s.loan_purpose = 'OWNER_OCCUPIED'
             AND s.repayment_type = 'PRINCIPAL_AND_INTEREST' AND s.term_months IN (12, 24, 36, 48, 60))
SELECT grp AS segment, SUM(IIF(term_months = 12, 1, 0)) AS products_1y, ROUND(MAX(IIF(term_months = 12, median_pct, NULL)), 2) AS year_1_pct,
       ROUND(MAX(IIF(term_months = 24, median_pct, NULL)), 2) AS year_2_pct, ROUND(MAX(IIF(term_months = 36, median_pct, NULL)), 2) AS year_3_pct,
       ROUND(MAX(IIF(term_months = 48, median_pct, NULL)), 2) AS year_4_pct, ROUND(MAX(IIF(term_months = 60, median_pct, NULL)), 2) AS year_5_pct
FROM s GROUP BY grp ORDER BY grp;

--18. Comparison rate minus advertised rate (the cost of fees and charges), compared variable owner-occupier P&I rates, latest day, by segment and market (pp)
WITH g AS (SELECT v.grp, l.comparison_pct - l.pct AS gap FROM #l AS l CROSS APPLY (VALUES (l.segment), ('Market')) AS v (grp)
           WHERE l.in_comparison = 1 AND l.comparison_pct IS NOT NULL AND l.analysis_type = 'VARIABLE' AND l.loan_purpose = 'OWNER_OCCUPIED'
             AND l.repayment_type = 'PRINCIPAL_AND_INTEREST'),
m AS (SELECT *, PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY gap) OVER (PARTITION BY grp) AS p25, PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY gap) OVER (PARTITION BY grp) AS p50,
             PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY gap) OVER (PARTITION BY grp) AS p75 FROM g)
SELECT grp AS segment, COUNT(*) AS rates, ROUND(MAX(p25), 2) AS p25_pp, ROUND(MAX(p50), 2) AS median_pp, ROUND(MAX(p75), 2) AS p75_pp, SUM(IIF(gap < 0, 1, 0)) AS rates_below_rate
FROM m GROUP BY grp ORDER BY grp;

-- F. Deposits and fees (Q6, Q7, Q9)

--19. Term deposit curve, latest day: products, banks, best rate and median best rate for each term offered by at least 10 banks, by segment and market (%)
WITH t AS (SELECT IIF(s.term_months IS NULL, CONCAT(s.term_days, IIF(s.term_days = 1, ' day', ' days')), CONCAT(s.term_months, IIF(s.term_months = 1, ' month', ' months'))) AS term,
                  COALESCE(s.term_months * 30.44, s.term_days) AS term_order,
                  s.brand_id, g.grp, s.pct
           FROM #s AS s CROSS APPLY (VALUES (s.segment), ('Market')) AS g (grp)
           WHERE s.is_latest = 1 AND s.product_type = 'Term deposit fixed' AND COALESCE(s.term_months, s.term_days) IS NOT NULL),
m AS (SELECT *, PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY pct) OVER (PARTITION BY term, grp) AS median_pct FROM t)
SELECT term, SUM(IIF(grp = 'Market', 1, 0)) AS products, COUNT(DISTINCT IIF(grp = 'Market', brand_id, NULL)) AS banks, ROUND(MAX(pct), 2) AS best_pct,
       ROUND(MAX(IIF(grp = 'Market', median_pct, NULL)), 2) AS market_median_pct, ROUND(MAX(IIF(grp = 'Big four', median_pct, NULL)), 2) AS big_four_median_pct,
       ROUND(MAX(IIF(grp = 'Peer', median_pct, NULL)), 2) AS peer_median_pct
FROM m GROUP BY term, term_order HAVING COUNT(DISTINCT brand_id) >= 10 ORDER BY term_order;

--20. Savings headline at each standard balance, latest day, by segment and market: accounts, accounts with a bonus and median headline; for accounts with a bonus,
--    median base rate, median headline and the average share of the headline that comes from the bonus (%)
WITH h AS (SELECT g.grp, h.balance, h.bonus_pct, h.headline_pct, IIF(h.bonus_pct IS NULL, NULL, COALESCE(h.base_pct, 0)) AS bonus_base,
                  IIF(h.bonus_pct IS NULL, NULL, h.headline_pct) AS bonus_headline
           FROM #h AS h CROSS APPLY (VALUES (h.segment), ('Market')) AS g (grp)),
m AS (SELECT *, PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY headline_pct) OVER (PARTITION BY grp, balance) AS median_headline,
             PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY bonus_base) OVER (PARTITION BY grp, balance) AS median_bonus_base,
             PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY bonus_headline) OVER (PARTITION BY grp, balance) AS median_bonus_headline FROM h)
SELECT grp AS segment, balance, COUNT(*) AS accounts, COUNT(bonus_pct) AS with_bonus, ROUND(MAX(median_headline), 2) AS median_headline_pct,
       ROUND(MAX(median_bonus_base), 2) AS bonus_accounts_median_base_pct, ROUND(MAX(median_bonus_headline), 2) AS bonus_accounts_median_headline_pct,
       ROUND(100 * AVG((bonus_headline - bonus_base) / NULLIF(bonus_headline, 0)), 1) AS bonus_share_of_headline_pct
FROM m GROUP BY grp, balance ORDER BY grp, balance;

--21. The most common coded conditions on savings bonus rates, latest day (bonuses without a coded condition state their conditions only in text)
SELECT TOP 10 COALESCE(condition_codes, '(none coded)') AS condition_codes, COUNT(*) AS bonus_rates, COUNT(DISTINCT product_key) AS accounts, COUNT(DISTINCT brand_id) AS banks
FROM #d WHERE in_comparison = 1 AND product_category = 'TRANS_AND_SAVINGS_ACCOUNTS' AND analysis_type IN ('BONUS', 'BUNDLE_BONUS')
GROUP BY condition_codes ORDER BY bonus_rates DESC;

--22. Periodic fees on transaction and savings accounts, latest day, by segment and market: accounts, accounts charging a fee, those with a waiver,
--    accounts charging monthly and the median monthly fee ($)
WITH a AS (SELECT d.segment, d.product_key, MAX(IIF(f.amount > 0, 1, 0)) AS charges, MAX(IIF(f.amount > 0, f.has_waiver, 0)) AS waiver,
                  MAX(IIF(f.amount > 0 AND (f.frequency = 'P1M' OR f.frequency LIKE 'month%'), f.amount, NULL)) AS monthly_fee
           FROM #pd AS d LEFT JOIN #f AS f ON f.product_key = d.product_key WHERE d.product_category = 'TRANS_AND_SAVINGS_ACCOUNTS' GROUP BY d.segment, d.product_key),
m AS (SELECT g.grp, a.*, PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY a.monthly_fee) OVER (PARTITION BY g.grp) AS median_fee
      FROM a CROSS APPLY (VALUES (a.segment), ('Market')) AS g (grp))
SELECT grp AS segment, COUNT(*) AS accounts, SUM(charges) AS charging_a_fee, SUM(waiver) AS with_a_waiver, COUNT(monthly_fee) AS charging_monthly,
       ROUND(MAX(median_fee), 2) AS median_monthly_fee
FROM m GROUP BY grp ORDER BY grp;

-- G. Competitive position (Q3, Q10)

--23. Key segments, latest day: spread of the best rate per product, and big four and peer group medians against the market (%; a positive gap is dearer for
--    borrowers and better for savers)
WITH k AS (
    SELECT CASE WHEN kind = 'L' AND rate_type = 'VARIABLE' THEN 'Home loan variable, OO P&I, 80% LVR'
                WHEN kind = 'L' AND rate_type = 'FIXED' AND term_months = 24 THEN 'Home loan 2-year fixed, OO P&I, 80% LVR'
                WHEN product_type = 'Term deposit fixed' AND term_months = 12 THEN 'Term deposit 12 months' END AS key_segment, segment, pct
    FROM #s WHERE is_latest = 1 AND (kind = 'D' OR (loan_purpose = 'OWNER_OCCUPIED' AND repayment_type = 'PRINCIPAL_AND_INTEREST' AND lvr_point = 0.8))
    UNION ALL SELECT 'Savings headline at $10,000', segment, headline_pct FROM #h WHERE is_default_balance = 1),
m AS (SELECT k.key_segment, k.pct, g.grp, PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY k.pct) OVER (PARTITION BY k.key_segment, g.grp) AS median_pct
      FROM k CROSS APPLY (VALUES (k.segment), ('Market')) AS g (grp) WHERE k.key_segment IS NOT NULL),
p AS (SELECT key_segment, SUM(IIF(grp = 'Market', 1, 0)) AS products, MIN(pct) AS min_pct, MAX(pct) AS max_pct,
             STDEV(IIF(grp = 'Market', pct, NULL)) / AVG(IIF(grp = 'Market', pct, NULL)) AS cv, MAX(IIF(grp = 'Market', median_pct, NULL)) AS market,
             MAX(IIF(grp = 'Big four', median_pct, NULL)) AS big_four, MAX(IIF(grp = 'Peer', median_pct, NULL)) AS peer FROM m GROUP BY key_segment)
SELECT key_segment, products, ROUND(min_pct, 2) AS min_pct, ROUND(max_pct, 2) AS max_pct, ROUND(cv, 3) AS coefficient_of_variation, ROUND(market, 2) AS market_median_pct,
       ROUND(big_four, 2) AS big_four_median_pct, ROUND(big_four - market, 2) AS big_four_gap_pp, ROUND(peer, 2) AS peer_median_pct, ROUND(peer - market, 2) AS peer_gap_pp
FROM p ORDER BY key_segment;

--24. Position of each big four and peer group, latest day: best variable OO P&I rate at 80% LVR and its rank among all groups, investor premium, spread over
--    the cash rate target, best 12-month term deposit and its rank, and the home loan rate minus the term deposit rate (%, pp)
WITH g AS (
    SELECT bank_group, segment,
           MIN(IIF(kind = 'L' AND rate_type = 'VARIABLE' AND loan_purpose = 'OWNER_OCCUPIED' AND repayment_type = 'PRINCIPAL_AND_INTEREST' AND lvr_point = 0.8, pct, NULL)) AS oo_pct,
           MIN(IIF(kind = 'L' AND rate_type = 'VARIABLE' AND loan_purpose = 'INVESTMENT' AND repayment_type = 'PRINCIPAL_AND_INTEREST' AND lvr_point = 0.8, pct, NULL)) AS investor_pct,
           MAX(IIF(product_type = 'Term deposit fixed' AND term_months = 12, pct, NULL)) AS td_pct
    FROM #s WHERE is_latest = 1 GROUP BY bank_group, segment),
r AS (SELECT *, IIF(oo_pct IS NULL, NULL, RANK() OVER (ORDER BY COALESCE(oo_pct, 100))) AS oo_rank, COUNT(oo_pct) OVER () AS groups_ranked_oo,
             IIF(td_pct IS NULL, NULL, RANK() OVER (ORDER BY COALESCE(td_pct, 0) DESC)) AS td_rank, COUNT(td_pct) OVER () AS groups_ranked_td FROM g)
SELECT r.segment, r.bank_group, ROUND(r.oo_pct, 2) AS best_variable_pct, r.oo_rank, r.groups_ranked_oo, ROUND(r.investor_pct - r.oo_pct, 2) AS investor_premium_pp,
       ROUND(r.oo_pct - c.cash_rate_target, 2) AS spread_over_cash_rate_pp, ROUND(r.td_pct, 2) AS best_td_12m_pct, r.td_rank, r.groups_ranked_td,
       ROUND(r.oo_pct - r.td_pct, 2) AS home_loan_minus_td_pp
FROM r CROSS JOIN (SELECT TOP 1 cash_rate_target FROM mart.fact_cash_rate WHERE [date] <= (SELECT MAX([date]) FROM #pd) ORDER BY [date] DESC) AS c
WHERE r.segment <> 'Rest of market' ORDER BY r.oo_rank;

--25. Mann-Whitney U test, latest day: are big four and peer group best variable OO P&I rates at 80% LVR dearer than the rest of the market's? Rank-based, so the
--    long tail of high rates doesn't drive it. p_dearer = chance a group product is dearer than a rest-of-market product (0.5 = no difference); |z| above 1.96
--    suggests a real difference at 95% (products from one bank are not independent, so the result is indicative)
WITH r AS (SELECT g.grp, s.segment, s.pct FROM #s AS s CROSS APPLY (VALUES ('Big four'), ('Peer')) AS g (grp)
           WHERE s.is_latest = 1 AND s.kind = 'L' AND s.rate_type = 'VARIABLE' AND s.lvr_point = 0.8 AND s.loan_purpose = 'OWNER_OCCUPIED'
             AND s.repayment_type = 'PRINCIPAL_AND_INTEREST' AND s.segment IN (g.grp, 'Rest of market')),
k AS (SELECT *, RANK() OVER (PARTITION BY grp ORDER BY pct) + (COUNT(*) OVER (PARTITION BY grp, pct) - 1) / 2.0 AS avg_rank, COUNT(*) OVER (PARTITION BY grp, pct) AS ties,
             PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY pct) OVER (PARTITION BY grp, segment) AS median_pct FROM r),
u AS (SELECT grp, SUM(IIF(segment = grp, 1.0, 0)) AS n1, SUM(IIF(segment = grp, 0, 1.0)) AS n2, SUM(IIF(segment = grp, avg_rank, 0)) AS rank_sum,
             SUM(1.0 * ties * ties - 1) AS tie_term, MAX(IIF(segment = grp, median_pct, NULL)) AS median_group, MAX(IIF(segment = grp, NULL, median_pct)) AS median_rest
      FROM k GROUP BY grp)
SELECT grp AS tested_group, CAST(n1 AS int) AS n_group, CAST(n2 AS int) AS n_rest_of_market, ROUND(median_group, 2) AS median_group_pct, ROUND(median_rest, 2) AS median_rest_pct,
       ROUND((rank_sum - n1 * (n1 + 1) / 2) / NULLIF(n1 * n2, 0), 3) AS p_dearer,
       ROUND((rank_sum - n1 * (n1 + 1) / 2 - n1 * n2 / 2) / NULLIF(SQRT(n1 * n2 / 12 * (n1 + n2 + 1 - tie_term / NULLIF((n1 + n2) * (n1 + n2 - 1), 0))), 0), 2) AS z
FROM u ORDER BY grp;

-- H. Change over time (Q1, Q2, Q8, Q10)

--26. Best rate moves per week (Monday start) by product type: product moves up and down, banks, and the median move (pp)
WITH p AS (SELECT t.week_start, s.product_type, s.brand_id, s.product_key, s.[date], AVG(s.change_pp) AS move
           FROM #s AS s JOIN mart.dim_date AS t ON t.[date] = s.[date] WHERE s.change <> 0 GROUP BY t.week_start, s.product_type, s.brand_id, s.product_key, s.[date]),
m AS (SELECT *, PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY move) OVER (PARTITION BY week_start, product_type) AS median_move FROM p)
SELECT week_start, product_type, SUM(IIF(move > 0, 1, 0)) AS moves_up, SUM(IIF(move < 0, 1, 0)) AS moves_down, COUNT(DISTINCT brand_id) AS banks,
       ROUND(MAX(median_move), 3) AS median_move_pp
FROM m GROUP BY week_start, product_type ORDER BY week_start, product_type;

--27. Change signals per bank over all days, top 20 by "last updated" re-stamps without a best rate change: product-days compared, content changed,
--    re-stamped, best rate changed (products in comparison scope)
WITH d AS (SELECT f.brand_id, f.product_key, f.[date], f.response_hash, f.last_updated, LAG(f.response_hash) OVER w AS previous_hash, LAG(f.last_updated) OVER w AS previous_update
           FROM mart.fact_product_day AS f JOIN #p AS p ON p.product_key = f.product_key WHERE COALESCE(p.loan_type, 'Standard') = 'Standard'
           WINDOW w AS (PARTITION BY f.product_key ORDER BY f.[date])),
r AS (SELECT DISTINCT product_key, [date] FROM #s WHERE change <> 0)
SELECT TOP 20 b.brand_name, b.segment, COUNT(*) AS product_days_compared, SUM(IIF(d.response_hash <> d.previous_hash, 1, 0)) AS content_changed,
       SUM(IIF(d.last_updated <> d.previous_update, 1, 0)) AS restamped, COUNT(r.product_key) AS best_rate_changed,
       SUM(IIF(d.last_updated <> d.previous_update AND r.product_key IS NULL, 1, 0)) AS restamped_without_rate_change
FROM d JOIN #b AS b ON b.brand_id = d.brand_id LEFT JOIN r ON r.product_key = d.product_key AND r.[date] = d.[date]
WHERE d.previous_hash IS NOT NULL GROUP BY b.brand_name, b.segment ORDER BY restamped_without_rate_change DESC, content_changed DESC;

--28. Response to the latest cash rate change, from its effective date, by big four and peer group (rest of market together) and product type: products offered,
--    products moved, days to the first move, median first move (pp) and that move as a share of the cash rate change
WITH c AS (SELECT TOP 1 [date] AS effective_date, change FROM mart.fact_cash_rate WHERE change <> 0 AND [date] <= (SELECT MAX([date]) FROM #pd) ORDER BY [date] DESC),
s AS (SELECT IIF(segment = 'Rest of market', segment, bank_group) AS grp, product_type, product_key, [date], change_pp, is_latest FROM #s
      WHERE product_type IN ('Home loan variable', 'Savings variable', 'Savings bonus', 'Term deposit fixed')),
f AS (SELECT grp, product_type, product_key, [date], AVG(change_pp) AS move, RANK() OVER (PARTITION BY product_key, product_type ORDER BY [date]) AS n
      FROM s WHERE change_pp <> 0 AND [date] >= (SELECT effective_date FROM c) GROUP BY grp, product_type, product_key, [date]),
m AS (SELECT *, PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY move) OVER (PARTITION BY grp, product_type) AS median_move FROM f WHERE n = 1),
o AS (SELECT grp, product_type, COUNT(DISTINCT product_key) AS products FROM s WHERE is_latest = 1 GROUP BY grp, product_type)
SELECT o.product_type, o.grp AS bank_group, o.products, COUNT(m.product_key) AS products_moved, DATEDIFF(day, c.effective_date, MIN(m.[date])) AS days_to_first_move,
       ROUND(MAX(m.median_move), 3) AS median_first_move_pp, ROUND(MAX(m.median_move) / c.change, 2) AS share_of_cash_rate_change
FROM o CROSS JOIN c LEFT JOIN m ON m.grp = o.grp AND m.product_type = o.product_type
GROUP BY o.product_type, o.grp, o.products, c.effective_date, c.change ORDER BY o.product_type, o.grp;

--29. RBA cash rate target since 2019: rises, cuts, net change and the lowest and highest target set in each year (%, pp)
SELECT YEAR([date]) AS [year], SUM(IIF(change > 0, 1, 0)) AS rises, SUM(IIF(change < 0, 1, 0)) AS cuts, SUM(change) AS net_change_pp,
       MIN(cash_rate_target) AS lowest_target_pct, MAX(cash_rate_target) AS highest_target_pct
FROM mart.fact_cash_rate WHERE [date] >= '2019-01-01' GROUP BY YEAR([date]) ORDER BY [year];
