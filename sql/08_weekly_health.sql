--Weekly health check, run on Mondays (read-only): the 7 Sydney days up to yesterday. Act only on items that are new and material (DR-010)
SET NOCOUNT ON;
DECLARE @to date = DATEADD(day, -1, CAST(SYSDATETIMEOFFSET() AT TIME ZONE 'AUS Eastern Standard Time' AS date));
DECLARE @from date = DATEADD(day, -6, @to);

SELECT e.*, b.brand_name, b.segment INTO #e
FROM mart.fact_data_exception AS e JOIN mart.dim_bank AS b ON b.brand_id = e.brand_id
WHERE e.[date] BETWEEN DATEADD(day, -28, @from) AND @to;

--1. Days with no collection at all (lost for good: recorded, never filled)
SELECT DATEADD(day, s.value, @from) AS missing_day
FROM GENERATE_SERIES(0, 6) AS s
WHERE NOT EXISTS (SELECT 1 FROM raw.collection_run AS c WHERE c.run_date = DATEADD(day, s.value, @from));

--2. Bank outcomes per day, naming big four and peer group brands not fully collected
SELECT c.run_date, COUNT(*) AS banks, SUM(IIF(c.status = 'ok', 1, 0)) AS ok, SUM(c.products) AS products,
       STRING_AGG(IIF(c.status <> 'ok' AND b.segment <> 'Rest of market', CONCAT(b.brand_name, ' (', c.status, ')'), NULL), ', ') AS focus_not_ok
FROM raw.collection_run AS c JOIN mart.dim_bank AS b ON b.brand_id = c.brand_id
WHERE c.run_date BETWEEN @from AND @to
GROUP BY c.run_date ORDER BY c.run_date;

--3. Exceptions by rule, this week against last week (a jump points to a new problem at a bank already listed)
SELECT rule_id, SUM(IIF([date] >= @from, 1, 0)) AS rows_this_week, SUM(IIF([date] BETWEEN DATEADD(day, -7, @from) AND DATEADD(day, -1, @from), 1, 0)) AS rows_last_week,
       COUNT(DISTINCT IIF([date] >= @from, brand_id, NULL)) AS banks_this_week
FROM #e GROUP BY rule_id ORDER BY rule_id;

--4. New bank-rule pairs (not seen in the 4 weeks before): the only rows that need a decision under the materiality rule
SELECT w.rule_id, w.brand_name, w.segment, COUNT(*) AS rows_this_week, MIN(w.[date]) AS first_seen, LEFT(MIN(w.detail), 100) AS example
FROM #e AS w
WHERE w.[date] BETWEEN @from AND @to
  AND NOT EXISTS (SELECT 1 FROM #e AS p WHERE p.brand_id = w.brand_id AND p.rule_id = w.rule_id AND p.[date] < @from)
GROUP BY w.rule_id, w.brand_name, w.segment ORDER BY w.segment, w.rule_id;
