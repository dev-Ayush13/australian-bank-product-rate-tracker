--1. Schema
IF SCHEMA_ID('mart') IS NULL EXEC('CREATE SCHEMA mart');
GO

--2. Banks: latest name per brand; group and segment from a fixed list (Big four groups and peers), everyone else is the market benchmark
CREATE OR ALTER VIEW mart.dim_bank AS
WITH b AS (
    SELECT s.brand_id, s.brand_name, s.is_interim_id, ROW_NUMBER() OVER (PARTITION BY s.brand_id ORDER BY f.fetch_date DESC) AS rn
    FROM stg.brand AS s JOIN raw.fetch_log AS f ON f.response_hash = s.response_hash)
SELECT b.brand_id, b.brand_name, COALESCE(g.bank_group, b.brand_name) AS bank_group, COALESCE(g.segment, 'Rest of market') AS segment, b.is_interim_id
FROM b LEFT JOIN (VALUES
    (N'CommBank', 'CBA', 'Big four'), (N'CBA - CommBiz', 'CBA', 'Big four'), (N'Bankwest', 'CBA', 'Big four'), (N'Unloan', 'CBA', 'Big four'),
    (N'Westpac', 'Westpac', 'Big four'), (N'St.George Bank', 'Westpac', 'Big four'), (N'BankSA', 'Westpac', 'Big four'), (N'Bank of Melbourne', 'Westpac', 'Big four'),
    (N'NATIONAL AUSTRALIA BANK', 'NAB', 'Big four'), (N'UBank', 'NAB', 'Big four'),
    (N'ANZ', 'ANZ', 'Big four'), (N'ANZ Plus', 'ANZ', 'Big four'), (N'Suncorp Bank', 'ANZ', 'Big four'),
    (N'Macquarie Bank Limited', 'Macquarie', 'Peer'), (N'ING BANK (Australia) Ltd', 'ING', 'Peer'),
    (N'Bank of Queensland Limited', 'BOQ', 'Peer'), (N'ME Bank - ME Go', 'BOQ', 'Peer'), (N'Virgin Money', 'BOQ', 'Peer'), (N'BOQ Specialist', 'BOQ', 'Peer'),
    (N'Bendigo Bank', 'Bendigo', 'Peer'), (N'Up', 'Bendigo', 'Peer'), (N'AMP - My AMP', 'AMP', 'Peer'), (N'AMP Bank GO', 'AMP', 'Peer'),
    (N'Great Southern Bank', 'Great Southern Bank', 'Peer'), (N'Great Southern Bank Business+', 'Great Southern Bank', 'Peer'),
    (N'HSBC', 'HSBC', 'Peer'), (N'HSBC Bank Australia Limited – Wholesale Banking', 'HSBC', 'Peer')
) AS g (brand_name, bank_group, segment) ON g.brand_name = b.brand_name
WHERE b.rn = 1;
GO

--3. Products: one row per bank and product, with its latest name and the first and last day it was offered
CREATE OR ALTER VIEW mart.dim_product AS
WITH p AS (
    SELECT f.source_id AS brand_id, s.product_id, s.name, s.product_category, s.is_tailored, f.fetch_date,
           ROW_NUMBER() OVER (PARTITION BY f.source_id, s.product_id ORDER BY f.fetch_date DESC) AS rn,
           MIN(f.fetch_date) OVER (PARTITION BY f.source_id, s.product_id) AS first_seen
    FROM raw.fetch_log AS f JOIN stg.product AS s ON s.response_hash = f.response_hash
    WHERE f.error IS NULL)
SELECT CONCAT(brand_id, '|', product_id) AS product_key, brand_id, product_id, name, product_category, is_tailored, first_seen, fetch_date AS last_seen
FROM p WHERE rn = 1;
GO

--4. Dates from the first to the last collection day
CREATE OR ALTER VIEW mart.dim_date AS
SELECT d.[date], YEAR(d.[date]) AS [year], MONTH(d.[date]) AS [month], DATENAME(month, d.[date]) AS month_name,
       DATEADD(day, -(DATEDIFF(day, '19000101', d.[date]) % 7), d.[date]) AS week_start, DATENAME(weekday, d.[date]) AS weekday  -- 1 Jan 1900 was a Monday
FROM (SELECT MIN(fetch_date) AS first_day, MAX(fetch_date) AS last_day FROM raw.fetch_log) AS r
CROSS APPLY (SELECT DATEADD(day, value, r.first_day) AS [date] FROM GENERATE_SERIES(0, DATEDIFF(day, r.first_day, r.last_day))) AS d;
GO

--5. Check: every listed name matches a Register brand when Big four = 13 and Peer = 14
SELECT segment, COUNT(*) AS brands FROM mart.dim_bank GROUP BY segment;
