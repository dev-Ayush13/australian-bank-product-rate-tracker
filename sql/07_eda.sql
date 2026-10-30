-- Exploratory data analysis on the reporting views. Read-only; each query runs on its own; "latest day" is the most recent collection.
-- Rates are fractions (x 100 = %). Comparisons of best rates use fact_segment_rate, which already excludes restricted rates.

-- A. Structure and integrity

--1. Grain: rows and duplicate keys per view (duplicates expected: 0)
SELECT 'dim_bank' AS view_name, COUNT(*) AS row_count, COUNT(*) - COUNT(DISTINCT brand_id) AS duplicate_keys FROM mart.dim_bank
UNION ALL SELECT 'dim_product', COUNT(*), COUNT(*) - COUNT(DISTINCT product_key) FROM mart.dim_product
UNION ALL SELECT 'dim_date', COUNT(*), COUNT(*) - COUNT(DISTINCT [date]) FROM mart.dim_date
UNION ALL SELECT 'fact_product_day', COUNT(*), COUNT(*) - COUNT(DISTINCT CONCAT([date], '|', product_key)) FROM mart.fact_product_day
UNION ALL SELECT 'fact_lending_rate', COUNT(*), COUNT(*) - COUNT(DISTINCT CONCAT([date], '|', product_key, '|', rate_seq)) FROM mart.fact_lending_rate
UNION ALL SELECT 'fact_deposit_rate', COUNT(*), COUNT(*) - COUNT(DISTINCT CONCAT([date], '|', product_key, '|', rate_seq)) FROM mart.fact_deposit_rate
UNION ALL SELECT 'fact_segment_rate', COUNT(*), COUNT(*) - COUNT(DISTINCT CONCAT([date], '|', product_key, '|', kind, '|', rate_type, '|', loan_purpose, '|',
                 repayment_type, '|', term_months, '|', term_days, '|', lvr_point)) FROM mart.fact_segment_rate
UNION ALL SELECT 'fact_account_fee', COUNT(*), COUNT(*) - COUNT(DISTINCT CONCAT([date], '|', product_key, '|', fee_seq)) FROM mart.fact_account_fee
UNION ALL SELECT 'fact_collection', COUNT(*), COUNT(*) - COUNT(DISTINCT CONCAT([date], '|', brand_id)) FROM mart.fact_collection
UNION ALL SELECT 'fact_cash_rate', COUNT(*), COUNT(*) - COUNT(DISTINCT [date]) FROM mart.fact_cash_rate;

--2. Referential integrity: fact rows whose key is missing from its dimension (expected: 0)
SELECT 'fact_product_day -> dim_product' AS relationship, COUNT(*) AS orphan_rows FROM mart.fact_product_day AS f WHERE NOT EXISTS (SELECT 1 FROM mart.dim_product AS d WHERE d.product_key = f.product_key)
UNION ALL SELECT 'fact_product_day -> dim_bank', COUNT(*) FROM mart.fact_product_day AS f WHERE NOT EXISTS (SELECT 1 FROM mart.dim_bank AS d WHERE d.brand_id = f.brand_id)
UNION ALL SELECT 'fact_product_day -> dim_date', COUNT(*) FROM mart.fact_product_day AS f WHERE NOT EXISTS (SELECT 1 FROM mart.dim_date AS d WHERE d.[date] = f.[date])
UNION ALL SELECT 'fact_lending_rate -> dim_product', COUNT(*) FROM mart.fact_lending_rate AS f WHERE NOT EXISTS (SELECT 1 FROM mart.dim_product AS d WHERE d.product_key = f.product_key)
UNION ALL SELECT 'fact_deposit_rate -> dim_product', COUNT(*) FROM mart.fact_deposit_rate AS f WHERE NOT EXISTS (SELECT 1 FROM mart.dim_product AS d WHERE d.product_key = f.product_key)
UNION ALL SELECT 'fact_collection -> dim_bank', COUNT(*) FROM mart.fact_collection AS f WHERE NOT EXISTS (SELECT 1 FROM mart.dim_bank AS d WHERE d.brand_id = f.brand_id);

--3. Reconciliation per day: product detail requests in the raw log -> parsed in staging -> rows in the reporting layer
SELECT f.fetch_date AS [date], COUNT(*) AS detail_requests, SUM(IIF(f.error IS NULL, 1, 0)) AS detail_ok, SUM(IIF(f.error IS NOT NULL, 1, 0)) AS detail_errors,
       SUM(IIF(f.error IS NULL AND p.response_hash IS NOT NULL, 1, 0)) AS parsed_products,
       SUM(IIF(f.error IS NULL AND x.response_hash IS NOT NULL, 1, 0)) AS rejected_whole,
       (SELECT COUNT(*) FROM mart.fact_product_day AS d WHERE d.[date] = f.fetch_date) AS reporting_rows
FROM raw.fetch_log AS f LEFT JOIN stg.product AS p ON p.response_hash = f.response_hash
LEFT JOIN (SELECT DISTINCT response_hash FROM stg.reject WHERE area = 'product') AS x ON x.response_hash = f.response_hash
WHERE f.request_key LIKE 'detail/%' GROUP BY f.fetch_date ORDER BY f.fetch_date;

-- B. Coverage and market structure

--4. Coverage: banks and products per day by collection outcome
SELECT [date], status, COUNT(*) AS banks, SUM(products) AS products FROM mart.fact_collection GROUP BY [date], status ORDER BY [date], status;

--5. Coverage: in-scope products per day by category
SELECT [date], product_category, COUNT(*) AS products FROM mart.fact_product_day GROUP BY [date], product_category ORDER BY [date], product_category;

--6. Coverage continuity: banks without products on every collected day
SELECT b.brand_name, b.segment, COUNT(*) AS days_collected, SUM(IIF(c.status IN ('ok', 'detail_errors', 'count_mismatch'), 1, 0)) AS days_with_products,
       (SELECT COUNT(*) FROM mart.dim_date) AS days_in_range, STRING_AGG(IIF(c.status IN ('failed', 'empty'), CONCAT(c.[date], ' ', c.status), NULL), '; ') AS gaps
FROM mart.fact_collection AS c JOIN mart.dim_bank AS b ON b.brand_id = c.brand_id
GROUP BY b.brand_name, b.segment
HAVING SUM(IIF(c.status IN ('ok', 'detail_errors', 'count_mismatch'), 1, 0)) < (SELECT COUNT(*) FROM mart.dim_date)
ORDER BY days_with_products, b.brand_name;

--7. Market structure: share of each category's products by segment, latest day
SELECT b.segment, d.product_category, COUNT(*) AS products,
       CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY d.product_category) AS decimal(5, 1)) AS pct_of_category
FROM mart.fact_product_day AS d JOIN mart.dim_bank AS b ON b.brand_id = d.brand_id
WHERE d.[date] = (SELECT MAX([date]) FROM mart.fact_product_day)
GROUP BY b.segment, d.product_category ORDER BY d.product_category, products DESC;

--8. Market structure: the 10 largest product ranges, latest day
SELECT TOP 10 b.brand_name, b.segment, COUNT(*) AS products
FROM mart.fact_product_day AS d JOIN mart.dim_bank AS b ON b.brand_id = d.brand_id
WHERE d.[date] = (SELECT MAX([date]) FROM mart.fact_product_day) GROUP BY b.brand_name, b.segment ORDER BY products DESC;

--9. Market structure: home loan offering mix, products by purpose, repayment and rate type (generally available rates), latest day
SELECT loan_purpose, repayment_type, COUNT(DISTINCT IIF(lending_rate_type = 'VARIABLE', product_key, NULL)) AS variable_products,
       COUNT(DISTINCT IIF(lending_rate_type = 'FIXED', product_key, NULL)) AS fixed_products, COUNT(DISTINCT product_key) AS any_products
FROM mart.fact_lending_rate WHERE is_restricted = 0 AND [date] = (SELECT MAX([date]) FROM mart.fact_lending_rate)
GROUP BY loan_purpose, repayment_type ORDER BY any_products DESC;

--10. Market structure: the same product name sold under several brands of one group (white-label duplication), latest day
SELECT TOP 20 b.bank_group, p.name AS product, p.product_category, COUNT(DISTINCT p.brand_id) AS brands, STRING_AGG(b.brand_name, ', ') AS brand_names
FROM mart.dim_product AS p JOIN mart.dim_bank AS b ON b.brand_id = p.brand_id
WHERE p.last_seen = (SELECT MAX([date]) FROM mart.fact_product_day)
GROUP BY b.bank_group, p.name, p.product_category HAVING COUNT(DISTINCT p.brand_id) > 1 ORDER BY brands DESC, b.bank_group;

-- C. Completeness, validity and data quality

--11. Completeness: home loan rate fields that are missing or restricted, latest day (%)
SELECT COUNT(*) AS rates, CAST(100.0 * SUM(IIF(comparison_rate IS NULL, 1, 0)) / COUNT(*) AS decimal(5, 1)) AS pct_no_comparison_rate,
       CAST(100.0 * SUM(IIF(lvr_range = 'Any', 1, 0)) / COUNT(*) AS decimal(5, 1)) AS pct_no_lvr_tier,
       CAST(100.0 * SUM(IIF(lending_rate_type = 'FIXED' AND term_months IS NULL, 1, 0)) / NULLIF(SUM(IIF(lending_rate_type = 'FIXED', 1, 0)), 0) AS decimal(5, 1)) AS pct_fixed_no_term,
       CAST(100.0 * SUM(CAST(is_restricted AS int)) / COUNT(*) AS decimal(5, 1)) AS pct_restricted
FROM mart.fact_lending_rate WHERE [date] = (SELECT MAX([date]) FROM mart.fact_lending_rate);

--12. Validity: business rule checks, with the number of violations for each rule (latest day unless noted)
SELECT 'lending rate outside 0-25%' AS rule_check, COUNT(*) AS violations FROM mart.fact_lending_rate WHERE (rate < 0 OR rate > 0.25) AND [date] = (SELECT MAX([date]) FROM mart.fact_lending_rate)
UNION ALL SELECT 'deposit rate outside 0-15%', COUNT(*) FROM mart.fact_deposit_rate WHERE (rate < 0 OR rate > 0.15) AND [date] = (SELECT MAX([date]) FROM mart.fact_deposit_rate)
UNION ALL SELECT 'comparison rate more than 3 points above the rate', COUNT(*) FROM mart.fact_lending_rate WHERE comparison_rate - rate > 0.03 AND [date] = (SELECT MAX([date]) FROM mart.fact_lending_rate)
UNION ALL SELECT 'LVR bound outside 0-1', COUNT(*) FROM mart.fact_lending_rate WHERE (lvr_min < 0 OR lvr_max > 1) AND [date] = (SELECT MAX([date]) FROM mart.fact_lending_rate)
UNION ALL SELECT 'fixed home loan term over 30 years', COUNT(*) FROM mart.fact_lending_rate WHERE term_months > 360 AND [date] = (SELECT MAX([date]) FROM mart.fact_lending_rate)
UNION ALL SELECT 'tier minimum above maximum (all parsed replies)', COUNT(*) FROM stg.rate_tier WHERE minimum_value > maximum_value
UNION ALL SELECT 'negative fee amount (all parsed replies)', COUNT(*) FROM stg.fee WHERE amount < 0 OR amount_min < 0
UNION ALL SELECT 'fee minimum above maximum (all parsed replies)', COUNT(*) FROM stg.fee WHERE amount_min > amount_max;

--13. Data quality: values held back in staging, by reason, with the banks involved
SELECT x.area, x.reason, COUNT(*) AS values_held_back, COUNT(DISTINCT f.source_id) AS banks, MIN(b.brand_name) AS example_bank
FROM stg.reject AS x
CROSS APPLY (SELECT TOP 1 source_id FROM raw.fetch_log AS l WHERE l.response_hash = x.response_hash) AS f
JOIN mart.dim_bank AS b ON b.brand_id = f.source_id
GROUP BY x.area, x.reason ORDER BY values_held_back DESC;

--14. Data quality: how long since banks last updated each product, latest day (negative = a date in the future)
SELECT CASE WHEN days_since_update < 0 THEN 'future date' WHEN days_since_update <= 7 THEN '0-7 days' WHEN days_since_update <= 30 THEN '8-30 days'
            WHEN days_since_update <= 90 THEN '31-90 days' WHEN days_since_update <= 365 THEN '91-365 days' ELSE 'over a year' END AS last_updated,
       COUNT(*) AS products, MIN(days_since_update) AS min_days, MAX(days_since_update) AS max_days
FROM mart.fact_product_day WHERE [date] = (SELECT MAX([date]) FROM mart.fact_product_day)
GROUP BY CASE WHEN days_since_update < 0 THEN 'future date' WHEN days_since_update <= 7 THEN '0-7 days' WHEN days_since_update <= 30 THEN '8-30 days'
              WHEN days_since_update <= 90 THEN '31-90 days' WHEN days_since_update <= 365 THEN '91-365 days' ELSE 'over a year' END
ORDER BY MIN(days_since_update);

--15. Data quality scorecard per bank: collection outcomes over all days; values held back, missing comparison rates and stale products on the latest day (worst first)
WITH c AS (SELECT brand_id, COUNT(*) AS days, SUM(IIF(status = 'ok', 1, 0)) AS ok_days, SUM(COALESCE(detail_failed, 0)) AS failed_details,
                  SUM(IIF([date] = m.last_day, rejects, 0)) AS rejects
           FROM mart.fact_collection CROSS JOIN (SELECT MAX([date]) AS last_day FROM mart.fact_collection) AS m GROUP BY brand_id),
     l AS (SELECT brand_id, AVG(IIF(comparison_rate IS NULL, 1.0, 0)) AS no_comparison FROM mart.fact_lending_rate
           WHERE [date] = (SELECT MAX([date]) FROM mart.fact_lending_rate) GROUP BY brand_id),
     d AS (SELECT brand_id, AVG(IIF(days_since_update > 365, 1.0, 0)) AS stale FROM mart.fact_product_day
           WHERE [date] = (SELECT MAX([date]) FROM mart.fact_product_day) GROUP BY brand_id)
SELECT b.brand_name, b.segment, c.days, c.ok_days, c.failed_details, c.rejects,
       CAST(100 * l.no_comparison AS decimal(5, 1)) AS pct_home_loan_rates_no_comparison, CAST(100 * d.stale AS decimal(5, 1)) AS pct_products_not_updated_in_a_year
FROM c JOIN mart.dim_bank AS b ON b.brand_id = c.brand_id LEFT JOIN l ON l.brand_id = c.brand_id LEFT JOIN d ON d.brand_id = c.brand_id
ORDER BY c.days - c.ok_days DESC, c.failed_details + c.rejects DESC, l.no_comparison DESC, d.stale DESC;

-- D. Distributions

--16. Every numeric column: count, missing, min, mean, median, max, standard deviation, skewness and excess kurtosis
--    (population moments: skewness = mean of z^3, excess kurtosis = mean of z^4 - 3; daily snapshot views on the latest day, collection and cash rate on all days)
WITH v AS (
    SELECT 'fact_lending_rate' AS dataset, c.column_name, c.x FROM mart.fact_lending_rate AS t
    CROSS APPLY (VALUES ('rate', CAST(t.rate AS float)), ('comparison_rate', t.comparison_rate), ('term_months', t.term_months), ('lvr_min', t.lvr_min),
                        ('lvr_max', t.lvr_max), ('amount_min', t.amount_min), ('amount_max', t.amount_max)) AS c (column_name, x)
    WHERE t.[date] = (SELECT MAX([date]) FROM mart.fact_lending_rate)
    UNION ALL
    SELECT 'fact_deposit_rate', c.column_name, c.x FROM mart.fact_deposit_rate AS t
    CROSS APPLY (VALUES ('rate', CAST(t.rate AS float)), ('term_months', t.term_months), ('term_days', t.term_days), ('balance_min', t.balance_min),
                        ('balance_max', t.balance_max)) AS c (column_name, x)
    WHERE t.[date] = (SELECT MAX([date]) FROM mart.fact_deposit_rate)
    UNION ALL
    SELECT 'fact_segment_rate', 'rate', rate FROM mart.fact_segment_rate WHERE [date] = (SELECT MAX([date]) FROM mart.fact_segment_rate)
    UNION ALL
    SELECT 'fact_segment_rate', 'change (non-zero, all days)', change FROM mart.fact_segment_rate WHERE change <> 0
    UNION ALL
    SELECT 'fact_account_fee', 'amount', amount FROM mart.fact_account_fee WHERE [date] = (SELECT MAX([date]) FROM mart.fact_account_fee)
    UNION ALL
    SELECT 'fact_product_day', 'days_since_update', days_since_update FROM mart.fact_product_day WHERE [date] = (SELECT MAX([date]) FROM mart.fact_product_day)
    UNION ALL
    SELECT 'fact_collection', c.column_name, c.x FROM mart.fact_collection AS t
    CROSS APPLY (VALUES ('products', CAST(t.products AS float)), ('total_records', t.total_records), ('in_scope', t.in_scope), ('detail_failed', t.detail_failed),
                        ('list_attempts', t.list_attempts), ('seconds', t.seconds), ('rejects', t.rejects)) AS c (column_name, x)
    UNION ALL
    SELECT 'fact_cash_rate', c.column_name, c.x FROM mart.fact_cash_rate AS t
    CROSS APPLY (VALUES ('change', CAST(t.change AS float)), ('cash_rate_target', t.cash_rate_target)) AS c (column_name, x)),
     m AS (
    SELECT dataset, column_name, CAST(x AS float) AS x, AVG(CAST(x AS float)) OVER (PARTITION BY dataset, column_name) AS mean_x,
           STDEVP(CAST(x AS float)) OVER (PARTITION BY dataset, column_name) AS sd_x,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY CAST(x AS float)) OVER (PARTITION BY dataset, column_name) AS median_x
    FROM v)
SELECT dataset, column_name, COUNT(x) AS n, SUM(IIF(x IS NULL, 1, 0)) AS missing, ROUND(MIN(x), 4) AS min_value, ROUND(MAX(mean_x), 4) AS mean,
       ROUND(MAX(median_x), 4) AS median, ROUND(MAX(x), 4) AS max_value, ROUND(MAX(sd_x), 4) AS std_dev,
       ROUND(AVG(POWER((x - mean_x) / NULLIF(sd_x, 0), 3)), 3) AS skewness, ROUND(AVG(POWER((x - mean_x) / NULLIF(sd_x, 0), 4)) - 3, 3) AS excess_kurtosis
FROM m GROUP BY dataset, column_name ORDER BY dataset, column_name;

--17. Every categorical column: rows, missing, distinct values, the most common value and its share (latest day; collection status on all days)
WITH v AS (
    SELECT 'fact_lending_rate' AS dataset, c.column_name, c.val FROM mart.fact_lending_rate AS t
    CROSS APPLY (VALUES ('lending_rate_type', CAST(t.lending_rate_type AS nvarchar(400))), ('loan_purpose', t.loan_purpose), ('repayment_type', t.repayment_type),
                        ('lvr_range', t.lvr_range), ('condition_codes', t.condition_codes)) AS c (column_name, val)
    WHERE t.[date] = (SELECT MAX([date]) FROM mart.fact_lending_rate)
    UNION ALL
    SELECT 'fact_deposit_rate', c.column_name, c.val FROM mart.fact_deposit_rate AS t
    CROSS APPLY (VALUES ('deposit_rate_type', CAST(t.deposit_rate_type AS nvarchar(400))), ('product_category', t.product_category),
                        ('condition_codes', t.condition_codes)) AS c (column_name, val)
    WHERE t.[date] = (SELECT MAX([date]) FROM mart.fact_deposit_rate)
    UNION ALL
    SELECT 'fact_account_fee', 'frequency', CAST(frequency AS nvarchar(400)) FROM mart.fact_account_fee WHERE [date] = (SELECT MAX([date]) FROM mart.fact_account_fee)
    UNION ALL
    SELECT 'fact_product_day', 'product_category', product_category FROM mart.fact_product_day WHERE [date] = (SELECT MAX([date]) FROM mart.fact_product_day)
    UNION ALL
    SELECT 'fact_collection', 'status', status FROM mart.fact_collection
    UNION ALL
    SELECT 'dim_bank', 'segment', segment FROM mart.dim_bank),
     f AS (SELECT dataset, column_name, val, COUNT(*) AS n FROM v GROUP BY dataset, column_name, val),
     r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY dataset, column_name ORDER BY IIF(val IS NULL, 1, 0), n DESC) AS rn,
                  SUM(n) OVER (PARTITION BY dataset, column_name) AS total FROM f)
SELECT dataset, column_name, MAX(total) AS row_count, SUM(IIF(val IS NULL, n, 0)) AS missing, COUNT(val) AS distinct_values,
       MAX(IIF(rn = 1, val, NULL)) AS most_common_value, MAX(IIF(rn = 1, CAST(100.0 * n / total AS decimal(5, 1)), NULL)) AS most_common_pct
FROM r GROUP BY dataset, column_name ORDER BY dataset, column_name;

--18. Generally available rates by rate type: min, quartiles, max, latest day (%)
WITH r AS (
    SELECT 'Lending' AS kind, lending_rate_type AS rate_type, rate FROM mart.fact_lending_rate
    WHERE is_restricted = 0 AND [date] = (SELECT MAX([date]) FROM mart.fact_lending_rate)
    UNION ALL
    SELECT 'Deposit', deposit_rate_type, rate FROM mart.fact_deposit_rate
    WHERE is_restricted = 0 AND [date] = (SELECT MAX([date]) FROM mart.fact_deposit_rate))
SELECT DISTINCT kind, rate_type, COUNT(*) OVER (PARTITION BY kind, rate_type) AS rates,
       MIN(rate) OVER (PARTITION BY kind, rate_type) * 100 AS min_pct,
       PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY rate) OVER (PARTITION BY kind, rate_type) * 100 AS p25_pct,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY rate) OVER (PARTITION BY kind, rate_type) * 100 AS median_pct,
       PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY rate) OVER (PARTITION BY kind, rate_type) * 100 AS p75_pct,
       MAX(rate) OVER (PARTITION BY kind, rate_type) * 100 AS max_pct
FROM r ORDER BY kind, rates DESC;

--19. Dispersion: how spread out best rates are in key segments (range and coefficient of variation), latest day
WITH s AS (
    SELECT CASE WHEN kind = 'L' AND rate_type = 'VARIABLE' THEN 'Home loan variable, OO P&I, 80% LVR'
                WHEN kind = 'L' AND rate_type = 'FIXED' AND term_months = 24 THEN 'Home loan 2-year fixed, OO P&I, 80% LVR'
                WHEN kind = 'D' AND rate_type = 'FIXED' AND term_months = 12 THEN 'Term deposit 12 months'
                WHEN kind = 'D' AND rate_type = 'VARIABLE' THEN 'Deposit variable (base) rate' END AS segment_name, rate
    FROM mart.fact_segment_rate
    WHERE [date] = (SELECT MAX([date]) FROM mart.fact_segment_rate)
      AND (kind = 'D' OR (loan_purpose = 'OWNER_OCCUPIED' AND repayment_type = 'PRINCIPAL_AND_INTEREST' AND lvr_point = 0.8)))
SELECT segment_name, COUNT(*) AS products, MIN(rate) * 100 AS min_pct, AVG(rate) * 100 AS mean_pct, MAX(rate) * 100 AS max_pct,
       (MAX(rate) - MIN(rate)) * 100 AS range_pp, CAST(STDEV(rate) / NULLIF(AVG(rate), 0) AS decimal(5, 3)) AS coefficient_of_variation
FROM s WHERE segment_name IS NOT NULL GROUP BY segment_name ORDER BY segment_name;

--20. Pricing pattern: last digit of advertised rates in basis points (e.g. 6.49% ends in 9), latest day
WITH r AS (
    SELECT 'Lending' AS kind, CAST(ROUND(rate * 10000, 0) AS int) % 10 AS last_digit FROM mart.fact_lending_rate WHERE [date] = (SELECT MAX([date]) FROM mart.fact_lending_rate)
    UNION ALL
    SELECT 'Deposit', CAST(ROUND(rate * 10000, 0) AS int) % 10 FROM mart.fact_deposit_rate WHERE rate > 0 AND [date] = (SELECT MAX([date]) FROM mart.fact_deposit_rate))
SELECT kind, last_digit, COUNT(*) AS rates, CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY kind) AS decimal(5, 1)) AS pct
FROM r GROUP BY kind, last_digit ORDER BY kind, last_digit;

--21. Fees: every fee type on products offered on the latest day: count, share charged as a fixed amount or a rate, median and highest amount
WITH f AS (
    SELECT f.fee_type, d.product_key, f.amount, f.rate, PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY f.amount) OVER (PARTITION BY f.fee_type) AS median_amount
    FROM mart.fact_product_day AS d JOIN stg.fee AS f ON f.response_hash = d.response_hash
    WHERE d.[date] = (SELECT MAX([date]) FROM mart.fact_product_day))
SELECT fee_type, COUNT(*) AS fees, COUNT(DISTINCT product_key) AS products, CAST(100 * AVG(IIF(amount IS NOT NULL, 1.0, 0)) AS decimal(5, 1)) AS pct_fixed_amount,
       CAST(100 * AVG(IIF(rate IS NOT NULL, 1.0, 0)) AS decimal(5, 1)) AS pct_rate_based, MAX(median_amount) AS median_amount, MAX(amount) AS max_amount
FROM f GROUP BY fee_type ORDER BY fees DESC;

-- E. Anomalies

--22. Banks re-stamping "last updated" on days when none of the product's best rates changed
WITH d AS (SELECT brand_id, product_key, [date], last_updated, LAG(last_updated) OVER (PARTITION BY product_key ORDER BY [date]) AS previous_update
           FROM mart.fact_product_day),
     c AS (SELECT DISTINCT product_key, [date] FROM mart.fact_segment_rate WHERE change <> 0)
SELECT TOP 10 b.brand_name, COUNT(d.previous_update) AS product_days_compared, SUM(IIF(d.last_updated <> d.previous_update, 1, 0)) AS restamped,
       SUM(IIF(d.last_updated <> d.previous_update AND c.product_key IS NULL, 1, 0)) AS restamped_without_rate_change
FROM d LEFT JOIN c ON c.product_key = d.product_key AND c.[date] = d.[date] JOIN mart.dim_bank AS b ON b.brand_id = d.brand_id
GROUP BY b.brand_name ORDER BY restamped_without_rate_change DESC, restamped DESC;

--23. Variable rates with a comparison rate below the advertised rate, latest day (fixed rates are left out: their comparison rate includes
--    the usually lower revert rate). "Product has discounts" means the bank publishes a standard rate plus separate DISCOUNT rates
SELECT b.brand_name, p.name AS product, l.rate * 100 AS rate_pct, l.comparison_rate * 100 AS comparison_pct,
       IIF(EXISTS (SELECT 1 FROM mart.fact_lending_rate AS x WHERE x.product_key = l.product_key AND x.[date] = l.[date] AND x.lending_rate_type = 'DISCOUNT'),
           'product has discounts', 'no published discount') AS explanation
FROM mart.fact_lending_rate AS l JOIN mart.dim_bank AS b ON b.brand_id = l.brand_id JOIN mart.dim_product AS p ON p.product_key = l.product_key
WHERE l.[date] = (SELECT MAX([date]) FROM mart.fact_lending_rate) AND l.lending_rate_type = 'VARIABLE' AND l.comparison_rate < l.rate
ORDER BY explanation, l.rate - l.comparison_rate DESC;

--24. Within a product, a lower best rate at a higher LVR point (risk pricing usually rises with LVR), latest day
WITH s AS (SELECT brand_id, product_key, rate_type, loan_purpose, repayment_type, term_months, lvr_point, rate,
                  LAG(rate) OVER (PARTITION BY product_key, rate_type, loan_purpose, repayment_type, term_months, term_days ORDER BY lvr_point) AS rate_at_lower_lvr
           FROM mart.fact_segment_rate WHERE kind = 'L' AND [date] = (SELECT MAX([date]) FROM mart.fact_segment_rate))
SELECT b.brand_name, p.name AS product, s.rate_type, s.loan_purpose, s.repayment_type, s.term_months, s.lvr_point,
       s.rate_at_lower_lvr * 100 AS rate_at_lower_lvr_pct, s.rate * 100 AS rate_pct
FROM s JOIN mart.dim_bank AS b ON b.brand_id = s.brand_id JOIN mart.dim_product AS p ON p.product_key = s.product_key
WHERE s.rate < s.rate_at_lower_lvr ORDER BY s.rate_at_lower_lvr - s.rate DESC;

--25. Home loan rates outside 1.5 x the interquartile range of their rate type, latest day
WITH r AS (
    SELECT l.brand_id, l.product_key, l.lending_rate_type, l.rate,
           PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY l.rate) OVER (PARTITION BY l.lending_rate_type) AS q1,
           PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY l.rate) OVER (PARTITION BY l.lending_rate_type) AS q3
    FROM mart.fact_lending_rate AS l WHERE l.is_restricted = 0 AND l.[date] = (SELECT MAX([date]) FROM mart.fact_lending_rate))
SELECT b.brand_name, p.name AS product, r.lending_rate_type, r.rate * 100 AS rate_pct, r.q1 * 100 AS q1_pct, r.q3 * 100 AS q3_pct
FROM r JOIN mart.dim_bank AS b ON b.brand_id = r.brand_id JOIN mart.dim_product AS p ON p.product_key = r.product_key
WHERE r.rate < r.q1 - 1.5 * (r.q3 - r.q1) OR r.rate > r.q3 + 1.5 * (r.q3 - r.q1)
ORDER BY r.lending_rate_type, r.rate;

--26. Deposit rates more than 3 standard deviations from the mean of their rate type (z-score), latest day
WITH r AS (
    SELECT d.brand_id, d.product_key, d.deposit_rate_type, d.rate,
           AVG(d.rate) OVER (PARTITION BY d.deposit_rate_type) AS mean_rate, STDEV(d.rate) OVER (PARTITION BY d.deposit_rate_type) AS sd_rate
    FROM mart.fact_deposit_rate AS d WHERE d.is_restricted = 0 AND d.[date] = (SELECT MAX([date]) FROM mart.fact_deposit_rate))
SELECT TOP 20 b.brand_name, p.name AS product, r.deposit_rate_type, r.rate * 100 AS rate_pct, r.mean_rate * 100 AS mean_pct,
       CAST((r.rate - r.mean_rate) / NULLIF(r.sd_rate, 0) AS decimal(6, 2)) AS z_score
FROM r JOIN mart.dim_bank AS b ON b.brand_id = r.brand_id JOIN mart.dim_product AS p ON p.product_key = r.product_key
WHERE ABS((r.rate - r.mean_rate) / NULLIF(r.sd_rate, 0)) > 3 ORDER BY ABS((r.rate - r.mean_rate) / NULLIF(r.sd_rate, 0)) DESC;

-- F. Relationships and correlations

--27. Correlation (Pearson r): advertised vs comparison rate, rate vs LVR, fixed rate vs term, term deposit rate vs term, latest day
WITH l AS (SELECT * FROM mart.fact_lending_rate WHERE is_restricted = 0 AND [date] = (SELECT MAX([date]) FROM mart.fact_lending_rate)),
     p AS (
    SELECT 'Home loan rate vs comparison rate' AS pair, CAST(rate AS float) AS x, CAST(comparison_rate AS float) AS y FROM l WHERE comparison_rate IS NOT NULL
    UNION ALL SELECT 'Home loan rate vs LVR maximum', CAST(rate AS float), CAST(lvr_max AS float) FROM l WHERE lvr_max IS NOT NULL
    UNION ALL SELECT 'Fixed home loan rate vs term (months)', CAST(rate AS float), CAST(term_months AS float) FROM l WHERE lending_rate_type = 'FIXED' AND term_months IS NOT NULL
    UNION ALL SELECT 'Term deposit rate vs term (months)', CAST(rate AS float), CAST(term_months AS float) FROM mart.fact_deposit_rate
    WHERE is_restricted = 0 AND product_category = 'TERM_DEPOSITS' AND term_months IS NOT NULL AND [date] = (SELECT MAX([date]) FROM mart.fact_deposit_rate))
SELECT pair, COUNT(*) AS n,
       CAST((COUNT(*) * SUM(x * y) - SUM(x) * SUM(y)) / NULLIF(SQRT((COUNT(*) * SUM(x * x) - SQUARE(SUM(x))) * (COUNT(*) * SUM(y * y) - SQUARE(SUM(y)))), 0) AS decimal(5, 3)) AS pearson_r
FROM p GROUP BY pair ORDER BY pair;

--28. Median best variable owner-occupier P&I rate at each LVR point, latest day (%)
SELECT DISTINCT lvr_point, COUNT(*) OVER (PARTITION BY lvr_point) AS products,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY rate) OVER (PARTITION BY lvr_point) * 100 AS median_pct
FROM mart.fact_segment_rate
WHERE [date] = (SELECT MAX([date]) FROM mart.fact_segment_rate) AND kind = 'L' AND rate_type = 'VARIABLE'
  AND loan_purpose = 'OWNER_OCCUPIED' AND repayment_type = 'PRINCIPAL_AND_INTEREST'
ORDER BY lvr_point;

--29. Investor and interest-only premiums: median best variable rate at 80% LVR, latest day (%)
SELECT DISTINCT loan_purpose, repayment_type, COUNT(*) OVER (PARTITION BY loan_purpose, repayment_type) AS products,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY rate) OVER (PARTITION BY loan_purpose, repayment_type) * 100 AS median_pct
FROM mart.fact_segment_rate
WHERE [date] = (SELECT MAX([date]) FROM mart.fact_segment_rate) AND kind = 'L' AND rate_type = 'VARIABLE' AND lvr_point = 0.8
  AND loan_purpose IN ('OWNER_OCCUPIED', 'INVESTMENT') AND repayment_type IN ('PRINCIPAL_AND_INTEREST', 'INTEREST_ONLY')
ORDER BY loan_purpose, repayment_type;

--30. Investor premium by big four and peer group, best variable P&I rate at 80% LVR, latest day (percentage points)
SELECT b.segment, b.bank_group, MIN(IIF(s.loan_purpose = 'OWNER_OCCUPIED', s.rate, NULL)) * 100 AS owner_occupier_pct,
       MIN(IIF(s.loan_purpose = 'INVESTMENT', s.rate, NULL)) * 100 AS investor_pct,
       (MIN(IIF(s.loan_purpose = 'INVESTMENT', s.rate, NULL)) - MIN(IIF(s.loan_purpose = 'OWNER_OCCUPIED', s.rate, NULL))) * 100 AS investor_premium_pp
FROM mart.fact_segment_rate AS s JOIN mart.dim_bank AS b ON b.brand_id = s.brand_id
WHERE s.[date] = (SELECT MAX([date]) FROM mart.fact_segment_rate) AND b.segment <> 'Rest of market' AND s.kind = 'L' AND s.rate_type = 'VARIABLE'
  AND s.repayment_type = 'PRINCIPAL_AND_INTEREST' AND s.lvr_point = 0.8
GROUP BY b.segment, b.bank_group ORDER BY investor_premium_pp DESC;

--31. Gap between comparison and advertised rate (fees and charges), variable owner-occupier P&I, latest day, 0.25 point buckets
SELECT FLOOR((comparison_rate - rate) * 400) / 4 AS gap_from_pp, COUNT(*) AS rates
FROM mart.fact_lending_rate
WHERE [date] = (SELECT MAX([date]) FROM mart.fact_lending_rate) AND is_restricted = 0 AND comparison_rate IS NOT NULL
  AND lending_rate_type = 'VARIABLE' AND loan_purpose = 'OWNER_OCCUPIED' AND repayment_type = 'PRINCIPAL_AND_INTEREST'
GROUP BY FLOOR((comparison_rate - rate) * 400) / 4 ORDER BY gap_from_pp;

--32. Fixed rate curve by segment: median best owner-occupier P&I rate at 80% LVR for 1-5 years, latest day (%)
SELECT DISTINCT b.segment, s.term_months / 12 AS years, COUNT(*) OVER (PARTITION BY b.segment, s.term_months) AS products,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY s.rate) OVER (PARTITION BY b.segment, s.term_months) * 100 AS median_pct
FROM mart.fact_segment_rate AS s JOIN mart.dim_bank AS b ON b.brand_id = s.brand_id
WHERE s.[date] = (SELECT MAX([date]) FROM mart.fact_segment_rate) AND s.kind = 'L' AND s.rate_type = 'FIXED' AND s.lvr_point = 0.8
  AND s.loan_purpose = 'OWNER_OCCUPIED' AND s.repayment_type = 'PRINCIPAL_AND_INTEREST' AND s.term_months IN (12, 24, 36, 48, 60)
ORDER BY b.segment, years;

--33. Banks paying less for a 3-year than a 1-year term deposit (an inverted curve suggests expected rate cuts), latest day
WITH t AS (
    SELECT brand_id, MAX(IIF(term_months = 12, rate, NULL)) AS rate_12m, MAX(IIF(term_months = 36, rate, NULL)) AS rate_36m
    FROM mart.fact_segment_rate WHERE kind = 'D' AND rate_type = 'FIXED' AND [date] = (SELECT MAX([date]) FROM mart.fact_segment_rate)
    GROUP BY brand_id)
SELECT COUNT(*) AS banks_with_both_terms, SUM(IIF(rate_36m < rate_12m, 1, 0)) AS inverted, SUM(IIF(rate_36m > rate_12m, 1, 0)) AS upward,
       CAST(AVG(rate_36m - rate_12m) * 100 AS decimal(6, 3)) AS avg_3y_minus_1y_pp
FROM t WHERE rate_12m IS NOT NULL AND rate_36m IS NOT NULL;

-- G. Product design and fees

--34. Fixed home loan terms and term deposit terms offered, latest day
SELECT 'Home loan fixed' AS kind, term_months, NULL AS term_days, COUNT(*) AS rates FROM mart.fact_lending_rate
WHERE [date] = (SELECT MAX([date]) FROM mart.fact_lending_rate) AND lending_rate_type = 'FIXED' GROUP BY term_months
UNION ALL
SELECT 'Term deposit', term_months, term_days, COUNT(*) FROM mart.fact_deposit_rate
WHERE [date] = (SELECT MAX([date]) FROM mart.fact_deposit_rate) AND product_category = 'TERM_DEPOSITS' GROUP BY term_months, term_days
ORDER BY kind, term_months, term_days;

--35. Savings and transaction accounts offering a bonus rate, and their median top bonus, by segment, latest day
WITH p AS (
    SELECT b.segment, d.product_key, MAX(IIF(d.deposit_rate_type = 'BONUS', d.rate, NULL)) AS top_bonus
    FROM mart.fact_deposit_rate AS d JOIN mart.dim_bank AS b ON b.brand_id = d.brand_id
    WHERE d.[date] = (SELECT MAX([date]) FROM mart.fact_deposit_rate) AND d.product_category = 'TRANS_AND_SAVINGS_ACCOUNTS' AND d.is_restricted = 0
    GROUP BY b.segment, d.product_key)
SELECT DISTINCT segment, COUNT(*) OVER (PARTITION BY segment) AS products, COUNT(top_bonus) OVER (PARTITION BY segment) AS with_bonus,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY top_bonus) OVER (PARTITION BY segment) * 100 AS median_top_bonus_pct
FROM p ORDER BY segment;

--36. The most common coded conditions attached to bonus rates, latest day
SELECT TOP 10 COALESCE(condition_codes, '(no coded condition)') AS condition_codes, COUNT(*) AS bonus_rates, COUNT(DISTINCT brand_id) AS banks
FROM mart.fact_deposit_rate WHERE deposit_rate_type = 'BONUS' AND [date] = (SELECT MAX([date]) FROM mart.fact_deposit_rate)
GROUP BY condition_codes ORDER BY bonus_rates DESC;

--37. How savings base and bonus rates depend on balance tiers (informs the balance assumed for "base + bonus"), latest day
WITH x AS (
    SELECT d.deposit_rate_type, t.tier_shape, d.product_key,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY d.balance_max) OVER (PARTITION BY d.deposit_rate_type, t.tier_shape) AS median_balance_cap,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY d.rate) OVER (PARTITION BY d.deposit_rate_type, t.tier_shape) AS median_rate
    FROM mart.fact_deposit_rate AS d
    CROSS APPLY (SELECT CASE WHEN d.balance_min IS NULL AND d.balance_max IS NULL THEN 'no balance tier' WHEN d.balance_max IS NULL THEN 'minimum balance only'
                             ELSE 'balance band with a cap' END AS tier_shape) AS t
    WHERE d.[date] = (SELECT MAX([date]) FROM mart.fact_deposit_rate) AND d.product_category = 'TRANS_AND_SAVINGS_ACCOUNTS' AND d.is_restricted = 0
      AND d.deposit_rate_type IN ('VARIABLE', 'BONUS'))
SELECT deposit_rate_type, tier_shape, COUNT(*) AS rates, COUNT(DISTINCT product_key) AS products, MAX(median_balance_cap) AS median_balance_cap,
       MAX(median_rate) * 100 AS median_rate_pct
FROM x GROUP BY deposit_rate_type, tier_shape ORDER BY deposit_rate_type, rates DESC;

--38. Transaction and savings accounts charging a periodic fee, waivers, and the average fee, by segment, latest day
WITH p AS (
    SELECT b.segment, d.product_key, MAX(IIF(f.amount > 0, f.amount, NULL)) AS fee, MAX(IIF(f.amount > 0, f.has_waiver, NULL)) AS has_waiver
    FROM mart.fact_product_day AS d JOIN mart.dim_bank AS b ON b.brand_id = d.brand_id
    LEFT JOIN mart.fact_account_fee AS f ON f.product_key = d.product_key AND f.[date] = d.[date]
    WHERE d.[date] = (SELECT MAX([date]) FROM mart.fact_product_day) AND d.product_category = 'TRANS_AND_SAVINGS_ACCOUNTS'
    GROUP BY b.segment, d.product_key)
SELECT segment, COUNT(*) AS products, COUNT(fee) AS with_fee, CAST(100.0 * COUNT(fee) / COUNT(*) AS decimal(5, 1)) AS pct_with_fee,
       SUM(has_waiver) AS fees_with_waiver, CAST(AVG(fee) AS decimal(8, 2)) AS avg_fee
FROM p GROUP BY segment ORDER BY segment;

-- H. Competitive position and statistical tests

--39. Big four and peer medians against the market median in key segments, latest day (%; positive gap = dearer for borrowers, better for savers)
WITH s AS (
    SELECT b.segment AS bank_segment, s.rate,
           CASE WHEN s.kind = 'L' AND s.rate_type = 'VARIABLE' THEN 'Home loan variable, OO P&I, 80% LVR'
                WHEN s.kind = 'L' AND s.rate_type = 'FIXED' AND s.term_months = 24 THEN 'Home loan 2-year fixed, OO P&I, 80% LVR'
                WHEN s.kind = 'D' AND s.rate_type = 'FIXED' AND s.term_months = 12 THEN 'Term deposit 12 months'
                WHEN s.kind = 'D' AND s.rate_type = 'VARIABLE' THEN 'Deposit variable (base) rate' END AS segment_name
    FROM mart.fact_segment_rate AS s JOIN mart.dim_bank AS b ON b.brand_id = s.brand_id
    WHERE s.[date] = (SELECT MAX([date]) FROM mart.fact_segment_rate)
      AND (s.kind = 'D' OR (s.loan_purpose = 'OWNER_OCCUPIED' AND s.repayment_type = 'PRINCIPAL_AND_INTEREST' AND s.lvr_point = 0.8))),
     m AS (
    SELECT DISTINCT segment_name,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY rate) OVER (PARTITION BY segment_name) * 100 AS market_median_pct,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY IIF(bank_segment = 'Big four', rate, NULL)) OVER (PARTITION BY segment_name) * 100 AS big_four_median_pct,
           PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY IIF(bank_segment = 'Peer', rate, NULL)) OVER (PARTITION BY segment_name) * 100 AS peer_median_pct
    FROM s WHERE segment_name IS NOT NULL)
SELECT segment_name, market_median_pct, big_four_median_pct, big_four_median_pct - market_median_pct AS big_four_gap_pp,
       peer_median_pct, peer_median_pct - market_median_pct AS peer_gap_pp
FROM m ORDER BY segment_name;

--40. Price rank of each big four and peer group's best variable owner-occupier P&I rate (80% LVR) among all groups, latest day
WITH best AS (
    SELECT b.bank_group, b.segment, MIN(s.rate) AS rate
    FROM mart.fact_segment_rate AS s JOIN mart.dim_bank AS b ON b.brand_id = s.brand_id
    WHERE s.[date] = (SELECT MAX([date]) FROM mart.fact_segment_rate) AND s.kind = 'L' AND s.rate_type = 'VARIABLE' AND s.lvr_point = 0.8
      AND s.loan_purpose = 'OWNER_OCCUPIED' AND s.repayment_type = 'PRINCIPAL_AND_INTEREST'
    GROUP BY b.bank_group, b.segment),
     ranked AS (SELECT *, RANK() OVER (ORDER BY rate) AS price_rank, COUNT(*) OVER () AS groups_compared,
                       CAST(100 * PERCENT_RANK() OVER (ORDER BY rate) AS decimal(5, 1)) AS pct_of_groups_cheaper FROM best)
SELECT segment, bank_group, rate * 100 AS best_rate_pct, price_rank, groups_compared, pct_of_groups_cheaper
FROM ranked WHERE segment <> 'Rest of market' ORDER BY price_rank;

--41. Welch's t-test: are big four and peer variable owner-occupier P&I rates (80% LVR) different from the rest of the market? Latest day
--    (|t| above about 2 suggests a real difference at 95%; products are the observations, and several come from the same bank, so treat it as indicative)
WITH r AS (
    SELECT b.segment, CAST(s.rate AS float) AS rate FROM mart.fact_segment_rate AS s JOIN mart.dim_bank AS b ON b.brand_id = s.brand_id
    WHERE s.[date] = (SELECT MAX([date]) FROM mart.fact_segment_rate) AND s.kind = 'L' AND s.rate_type = 'VARIABLE' AND s.lvr_point = 0.8
      AND s.loan_purpose = 'OWNER_OCCUPIED' AND s.repayment_type = 'PRINCIPAL_AND_INTEREST'),
     g AS (SELECT segment, COUNT(*) AS n, AVG(rate) AS mean_rate, VAR(rate) AS var_rate FROM r GROUP BY segment)
SELECT a.segment AS tested_group, a.n AS n_group, z.n AS n_rest_of_market, ROUND((a.mean_rate - z.mean_rate) * 100, 3) AS mean_difference_pp,
       ROUND((a.mean_rate - z.mean_rate) / NULLIF(SQRT(a.var_rate / a.n + z.var_rate / z.n), 0), 2) AS welch_t,
       ROUND(SQUARE(a.var_rate / a.n + z.var_rate / z.n) / NULLIF(SQUARE(a.var_rate / a.n) / (a.n - 1) + SQUARE(z.var_rate / z.n) / (z.n - 1), 0), 1) AS degrees_of_freedom
FROM g AS a JOIN g AS z ON z.segment = 'Rest of market' WHERE a.segment <> 'Rest of market';

--42. Margin proxy per big four and peer group: best variable owner-occupier P&I rate (80% LVR) minus best 12-month term deposit rate, latest day
WITH g AS (
    SELECT b.segment, b.bank_group,
           MIN(IIF(s.kind = 'L' AND s.rate_type = 'VARIABLE' AND s.loan_purpose = 'OWNER_OCCUPIED' AND s.repayment_type = 'PRINCIPAL_AND_INTEREST'
                   AND s.lvr_point = 0.8, s.rate, NULL)) AS mortgage_rate,
           MAX(IIF(s.kind = 'D' AND s.rate_type = 'FIXED' AND s.term_months = 12, s.rate, NULL)) AS td_12m_rate
    FROM mart.fact_segment_rate AS s JOIN mart.dim_bank AS b ON b.brand_id = s.brand_id
    WHERE s.[date] = (SELECT MAX([date]) FROM mart.fact_segment_rate) AND b.segment <> 'Rest of market'
    GROUP BY b.segment, b.bank_group)
SELECT segment, bank_group, mortgage_rate * 100 AS mortgage_pct, td_12m_rate * 100 AS td_12m_pct, (mortgage_rate - td_12m_rate) * 100 AS spread_pp
FROM g WHERE mortgage_rate IS NOT NULL AND td_12m_rate IS NOT NULL ORDER BY spread_pp DESC;

-- I. Change over time and context

--43. Churn: share of products whose published content changed since the previous collected day, by segment
WITH d AS (SELECT brand_id, [date], response_hash, LAG(response_hash) OVER (PARTITION BY product_key ORDER BY [date]) AS previous_hash FROM mart.fact_product_day)
SELECT d.[date], b.segment, COUNT(*) AS compared, SUM(IIF(d.response_hash <> d.previous_hash, 1, 0)) AS changed,
       CAST(100.0 * SUM(IIF(d.response_hash <> d.previous_hash, 1, 0)) / COUNT(*) AS decimal(5, 1)) AS pct_changed
FROM d JOIN mart.dim_bank AS b ON b.brand_id = d.brand_id WHERE d.previous_hash IS NOT NULL
GROUP BY d.[date], b.segment ORDER BY d.[date], b.segment;

--44. Rate moves per day by direction (percentage points)
SELECT [date], kind, SUM(IIF(change > 0, 1, 0)) AS rises, SUM(IIF(change < 0, 1, 0)) AS cuts, CAST(AVG(change) * 100 AS decimal(6, 3)) AS avg_change_pp
FROM mart.fact_segment_rate WHERE change <> 0 GROUP BY [date], kind ORDER BY [date], kind;

--45. Which banks move rates most: changes, direction and products affected over all days
SELECT TOP 15 b.brand_name, b.segment, COUNT(*) AS changes, SUM(IIF(s.change > 0, 1, 0)) AS rises, SUM(IIF(s.change < 0, 1, 0)) AS cuts,
       COUNT(DISTINCT s.product_key) AS products_changed, CAST(AVG(s.change) * 100 AS decimal(6, 3)) AS avg_change_pp
FROM mart.fact_segment_rate AS s JOIN mart.dim_bank AS b ON b.brand_id = s.brand_id
WHERE s.change <> 0 GROUP BY b.brand_name, b.segment ORDER BY changes DESC;

--46. Spread of the median best variable owner-occupier P&I rate (80% LVR) over the current RBA cash rate target, by segment (percentage points)
SELECT DISTINCT b.segment, c.cash_rate_target,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY s.rate) OVER (PARTITION BY b.segment) * 100 AS median_rate_pct,
       PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY s.rate) OVER (PARTITION BY b.segment) * 100 - c.cash_rate_target AS spread_pp
FROM mart.fact_segment_rate AS s JOIN mart.dim_bank AS b ON b.brand_id = s.brand_id
CROSS JOIN (SELECT TOP 1 cash_rate_target FROM mart.fact_cash_rate ORDER BY [date] DESC) AS c
WHERE s.[date] = (SELECT MAX([date]) FROM mart.fact_segment_rate) AND s.kind = 'L' AND s.rate_type = 'VARIABLE' AND s.lvr_point = 0.8
  AND s.loan_purpose = 'OWNER_OCCUPIED' AND s.repayment_type = 'PRINCIPAL_AND_INTEREST'
ORDER BY spread_pp;

--47. The RBA cash rate cycle: rises and cuts per year since 2019
SELECT YEAR([date]) AS [year], SUM(IIF(change > 0, 1, 0)) AS rises, SUM(IIF(change < 0, 1, 0)) AS cuts, SUM(change) AS net_change_pp,
       MAX(cash_rate_target) AS highest_target, MIN(cash_rate_target) AS lowest_target
FROM mart.fact_cash_rate WHERE [date] >= '2019-01-01' GROUP BY YEAR([date]) ORDER BY [year];
