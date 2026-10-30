--1. Products offered each day (the base for the other facts)
CREATE OR ALTER VIEW mart.fact_product_day AS
SELECT f.fetch_date AS [date], f.source_id AS brand_id, CONCAT(f.source_id, '|', p.product_id) AS product_key, p.product_category, f.response_hash,
       CAST(p.last_updated AS date) AS last_updated, DATEDIFF(day, CAST(p.last_updated AS date), f.fetch_date) AS days_since_update
FROM raw.fetch_log AS f JOIN stg.product AS p ON p.response_hash = f.response_hash
WHERE f.error IS NULL;
GO

--2. Each parsed rate once: tier bounds, LVR range label, condition codes and whether it is restricted (not generally available)
CREATE OR ALTER VIEW mart.rate_detail AS
SELECT r.response_hash, r.kind, r.rate_seq, r.rate_type, r.rate, r.comparison_rate, r.loan_purpose, r.repayment_type, r.term_months, r.term_days,
       x.lvr_min, x.lvr_max, x.amount_min, x.amount_max, c.condition_codes,
       CASE WHEN r.kind = 'D' THEN NULL WHEN x.lvr_min IS NULL AND x.lvr_max IS NULL THEN 'Any'
            ELSE CONCAT(CAST(ROUND(COALESCE(x.lvr_min, 0) * 100, 0) AS int),
                        IIF(x.lvr_max IS NULL, '%+', CONCAT('-', CAST(ROUND(x.lvr_max * 100, 0) AS int), '%'))) END AS lvr_range,
       IIF(p.is_tailored = 1 OR c.condition_codes LIKE '%EXISTING_CUST%' OR EXISTS (SELECT 1 FROM (VALUES ('%winner%'), ('%competition%'),
           ('%employee%'), ('%selected customer%'), ('%existing customer%')) AS k (w) WHERE r.info LIKE k.w), 1, 0) AS is_restricted
FROM (SELECT response_hash, 'L' AS kind, rate_seq, lending_rate_type AS rate_type, rate, comparison_rate, loan_purpose, repayment_type,
             term_months, term_days, CONCAT(additional_value, ' ', additional_info) AS info FROM stg.lending_rate
      UNION ALL
      SELECT response_hash, 'D', rate_seq, deposit_rate_type, rate, NULL, NULL, NULL, term_months, term_days,
             CONCAT(additional_value, ' ', additional_info) FROM stg.deposit_rate) AS r
JOIN stg.product AS p ON p.response_hash = r.response_hash
OUTER APPLY (SELECT MAX(IIF(unit_of_measure = 'PERCENT', minimum_value, NULL)) AS lvr_min, MAX(IIF(unit_of_measure = 'PERCENT', maximum_value, NULL)) AS lvr_max,
                    MAX(IIF(unit_of_measure = 'DOLLAR', minimum_value, NULL)) AS amount_min, MAX(IIF(unit_of_measure = 'DOLLAR', maximum_value, NULL)) AS amount_max
             FROM stg.rate_tier AS t WHERE t.response_hash = r.response_hash AND t.rate_kind = r.kind AND t.rate_seq = r.rate_seq) AS x
OUTER APPLY (SELECT STRING_AGG(condition_type, ', ') WITHIN GROUP (ORDER BY condition_type) AS condition_codes
             FROM (SELECT DISTINCT condition_type FROM stg.rate_condition AS rc
                   WHERE rc.response_hash = r.response_hash AND rc.rate_kind = r.kind AND rc.rate_seq = r.rate_seq) AS d) AS c;
GO

--3. Home loan rates per day
CREATE OR ALTER VIEW mart.fact_lending_rate AS
SELECT d.[date], d.brand_id, d.product_key, r.rate_seq, r.rate_type AS lending_rate_type, r.rate, r.comparison_rate, r.loan_purpose, r.repayment_type,
       r.term_months, r.lvr_min, r.lvr_max, r.lvr_range, r.amount_min, r.amount_max, r.condition_codes, r.is_restricted
FROM mart.fact_product_day AS d JOIN mart.rate_detail AS r ON r.response_hash = d.response_hash AND r.kind = 'L'
WHERE d.product_category = 'RESIDENTIAL_MORTGAGES';
GO

--4. Savings, transaction account and term deposit rates per day
CREATE OR ALTER VIEW mart.fact_deposit_rate AS
SELECT d.[date], d.brand_id, d.product_key, d.product_category, r.rate_seq, r.rate_type AS deposit_rate_type, r.rate, r.term_months, r.term_days,
       r.amount_min AS balance_min, r.amount_max AS balance_max, r.condition_codes, r.is_restricted
FROM mart.fact_product_day AS d JOIN mart.rate_detail AS r ON r.response_hash = d.response_hash AND r.kind = 'D'
WHERE d.product_category <> 'RESIDENTIAL_MORTGAGES';
GO

--5. Best generally available rate per product and segment per day (lowest for loans, highest for deposits), with the change since the previous
--   collected day. Home loans are compared at standard LVR points: a rate counts at 80% if its LVR range includes 80%
CREATE OR ALTER VIEW mart.fact_segment_rate AS
WITH s AS (
    SELECT d.[date], d.brand_id, d.product_key, r.kind, r.rate_type, r.loan_purpose, r.repayment_type, r.term_months, r.term_days, v.lvr_point,
           IIF(r.kind = 'L', MIN(r.rate), MAX(r.rate)) AS rate
    FROM mart.fact_product_day AS d JOIN mart.rate_detail AS r ON r.response_hash = d.response_hash
    CROSS APPLY (SELECT p AS lvr_point FROM (VALUES (0.6), (0.7), (0.8), (0.9)) AS t (p)
                 WHERE r.kind = 'L' AND (r.lvr_min IS NULL OR r.lvr_min <= p) AND (r.lvr_max IS NULL OR p <= r.lvr_max)
                 UNION ALL SELECT NULL WHERE r.kind = 'D') AS v
    WHERE r.is_restricted = 0 AND IIF(d.product_category = 'RESIDENTIAL_MORTGAGES', 'L', 'D') = r.kind
    GROUP BY d.[date], d.brand_id, d.product_key, r.kind, r.rate_type, r.loan_purpose, r.repayment_type, r.term_months, r.term_days, v.lvr_point)
SELECT *, LAG([date]) OVER w AS previous_date, LAG(rate) OVER w AS previous_rate, rate - LAG(rate) OVER w AS change
FROM s
WINDOW w AS (PARTITION BY product_key, kind, rate_type, loan_purpose, repayment_type, term_months, term_days, lvr_point ORDER BY [date]);
GO

--6. Periodic (account keeping) fees on transaction and savings accounts per day, with their waiver conditions
CREATE OR ALTER VIEW mart.fact_account_fee AS
SELECT d.[date], d.brand_id, d.product_key, f.fee_seq, f.name AS fee_name, f.amount, f.additional_value AS frequency,
       w.waiver_conditions, IIF(w.waiver_conditions IS NULL, 0, 1) AS has_waiver
FROM mart.fact_product_day AS d JOIN stg.fee AS f ON f.response_hash = d.response_hash
OUTER APPLY (SELECT STRING_AGG(COALESCE(x.description, x.discount_type), '; ') AS waiver_conditions
             FROM stg.fee_discount AS x WHERE x.response_hash = f.response_hash AND x.fee_seq = f.fee_seq) AS w
WHERE f.fee_type = 'PERIODIC' AND d.product_category = 'TRANS_AND_SAVINGS_ACCOUNTS';
GO

--7. Collection outcome per bank per day, with the number of values held back in staging
CREATE OR ALTER VIEW mart.fact_collection AS
SELECT c.run_date AS [date], c.brand_id, c.status, c.products, c.total_records, c.in_scope, c.detail_failed, c.list_attempts, c.seconds, x.rejects
FROM raw.collection_run AS c
OUTER APPLY (SELECT COUNT(*) AS rejects FROM raw.fetch_log AS f JOIN stg.reject AS r ON r.response_hash = f.response_hash
             WHERE f.fetch_date = c.run_date AND f.source_id = c.brand_id) AS x;
GO

--8. RBA cash rate target changes, read from the latest stored copy of RBA table A2 (rows look like "30-Sep-2026,+0.25,4.60,...");
--   early-1990s targets given as ranges ("17.00 to 17.50") keep their text and have no numeric value
CREATE OR ALTER VIEW mart.fact_cash_rate AS
SELECT TRY_CONVERT(date, REPLACE(LEFT(l.value, 11), '-', ' '), 106) AS [date], TRY_CAST(c.change_text AS decimal(5, 2)) AS change,
       TRY_CAST(c.target_text AS decimal(5, 2)) AS cash_rate_target, c.target_text
FROM (SELECT TOP 1 CAST(DECOMPRESS(r.body_gzip) AS varchar(max)) AS txt FROM raw.fetch_log AS f JOIN raw.response AS r ON r.response_hash = f.response_hash
      WHERE f.source_id = 'rba_a2' ORDER BY f.fetch_date DESC) AS a
CROSS APPLY STRING_SPLIT(REPLACE(a.txt, CHAR(13), ''), CHAR(10)) AS l
CROSS APPLY (SELECT MAX(IIF(s.ordinal = 2, s.value, NULL)) AS change_text, MAX(IIF(s.ordinal = 3, s.value, NULL)) AS target_text
             FROM STRING_SPLIT(l.value, ',', 1) AS s) AS c
WHERE l.value LIKE '[0-9][0-9]-[A-Z][a-z][a-z]-[0-9][0-9][0-9][0-9],%';
GO

--9. Check: rows per fact view
SELECT 'fact_product_day' AS view_name, COUNT(*) AS row_count FROM mart.fact_product_day UNION ALL SELECT 'fact_lending_rate', COUNT(*) FROM mart.fact_lending_rate
UNION ALL SELECT 'fact_deposit_rate', COUNT(*) FROM mart.fact_deposit_rate UNION ALL SELECT 'fact_segment_rate', COUNT(*) FROM mart.fact_segment_rate
UNION ALL SELECT 'fact_account_fee', COUNT(*) FROM mart.fact_account_fee UNION ALL SELECT 'fact_collection', COUNT(*) FROM mart.fact_collection
UNION ALL SELECT 'fact_cash_rate', COUNT(*) FROM mart.fact_cash_rate;
