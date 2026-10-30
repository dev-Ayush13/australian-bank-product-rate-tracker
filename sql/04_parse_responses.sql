--1. ISO 8601 period (P12M, P1Y, P90D, P2W) to months or days; combined periods such as P1Y6M return nothing
CREATE OR ALTER FUNCTION stg.period (@v nvarchar(max)) RETURNS TABLE AS RETURN
SELECT CASE u WHEN 'Y' THEN n * 12 WHEN 'M' THEN n END AS months, CASE u WHEN 'W' THEN n * 7 WHEN 'D' THEN n END AS days
FROM (SELECT TRY_CAST(SUBSTRING(@v, 2, IIF(LEN(@v) > 2, LEN(@v) - 2, 0)) AS int) AS n, RIGHT(@v, 1) AS u) AS x
WHERE @v LIKE 'P[0-9]%[YMWD]';
GO

--2. Parse Register and product detail responses not yet in staging, all or nothing
CREATE OR ALTER PROCEDURE stg.parse_new_responses AS
SET NOCOUNT, XACT_ABORT ON;

CREATE TABLE #doc (response_hash binary(32) PRIMARY KEY, j varchar(max) COLLATE Latin1_General_100_CI_AS_SC_UTF8);  -- UTF-8 keeps ’ – ≥ intact
INSERT #doc
SELECT r.response_hash, DECOMPRESS(r.body_gzip) FROM raw.response AS r
WHERE EXISTS (SELECT 1 FROM raw.fetch_log AS f WHERE f.response_hash = r.response_hash AND f.request_key LIKE 'detail/%' AND f.error IS NULL)
  AND NOT EXISTS (SELECT 1 FROM stg.product AS p WHERE p.response_hash = r.response_hash)
  AND NOT EXISTS (SELECT 1 FROM stg.reject AS x WHERE x.response_hash = r.response_hash AND x.area = 'product');

CREATE TABLE #reg (response_hash binary(32) PRIMARY KEY, j varchar(max) COLLATE Latin1_General_100_CI_AS_SC_UTF8);
INSERT #reg
SELECT r.response_hash, DECOMPRESS(r.body_gzip) FROM raw.response AS r
WHERE EXISTS (SELECT 1 FROM raw.fetch_log AS f WHERE f.response_hash = r.response_hash AND f.source_id = 'cdr_register')
  AND NOT EXISTS (SELECT 1 FROM stg.brand AS b WHERE b.response_hash = r.response_hash);

BEGIN TRAN;

--2a. Register brands; the key is dataHolderBrandId, else interimId
INSERT stg.brand
SELECT g.response_hash, COALESCE(b.dataHolderBrandId, b.interimId), b.brandName, IIF(b.dataHolderBrandId IS NULL, 1, 0), b.publicBaseUri,
       TRY_CAST(b.lastUpdated AS datetimeoffset(0))
FROM #reg AS g CROSS APPLY OPENJSON(g.j, '$.data') WITH (dataHolderBrandId varchar(64), interimId varchar(64), brandName nvarchar(200),
    publicBaseUri nvarchar(400), lastUpdated varchar(40)) AS b;

--2b. Products; a response without id, category or name is rejected whole
INSERT stg.product
SELECT d.response_hash, p.productId, p.productCategory, p.name, p.description, p.brand, TRY_CAST(p.lastUpdated AS datetimeoffset(0)),
       TRY_CAST(p.effectiveFrom AS datetimeoffset(0)), TRY_CAST(p.effectiveTo AS datetimeoffset(0)), p.isTailored
FROM #doc AS d CROSS APPLY OPENJSON(d.j, '$.data') WITH (productId nvarchar(300), productCategory varchar(50), name nvarchar(400),
    description nvarchar(max), brand nvarchar(200), lastUpdated varchar(40), effectiveFrom varchar(40), effectiveTo varchar(40), isTailored bit) AS p
WHERE p.productId IS NOT NULL AND p.productCategory IS NOT NULL AND p.name IS NOT NULL;

INSERT stg.reject (response_hash, area, reason)
SELECT response_hash, 'product', 'missing productId, productCategory or name' FROM #doc AS d
WHERE NOT EXISTS (SELECT 1 FROM stg.product AS p WHERE p.response_hash = d.response_hash);
DELETE d FROM #doc AS d WHERE NOT EXISTS (SELECT 1 FROM stg.product AS p WHERE p.response_hash = d.response_hash);

--2c. Lending and deposit rates with their term, and the reason when a rate is held back
SELECT d.response_hash, k.kind, CAST(a.[key] AS smallint) AS rate_seq, COALESCE(r.lendingRateType, r.depositRateType) AS rate_type,
       TRY_CAST(r.rate AS decimal(12, 8)) AS rate, r.rate AS raw_rate, TRY_CAST(r.comparisonRate AS decimal(12, 8)) AS comparison_rate,
       r.loanPurpose, r.repaymentType, t.months, t.days, r.calculationFrequency, r.applicationType, r.applicationFrequency,
       r.interestPaymentDue, r.additionalValue, r.additionalInfo, r.tiers, r.applicabilityConditions AS conditions,
       CASE WHEN COALESCE(r.lendingRateType, r.depositRateType) IS NULL THEN 'missing rate type'
            WHEN TRY_CAST(r.rate AS decimal(12, 8)) IS NULL THEN 'rate is not a number'
            WHEN TRY_CAST(r.rate AS decimal(12, 8)) > 1 THEN 'rate above 1: looks like a percentage, not a fraction'
            WHEN r.depositRateType = 'FIXED' AND p.product_category = 'TERM_DEPOSITS' AND t.months IS NULL AND t.days IS NULL
                 THEN 'term deposit rate without a term' END AS reason
INTO #rate
FROM #doc AS d JOIN stg.product AS p ON p.response_hash = d.response_hash
CROSS APPLY (VALUES ('L', JSON_QUERY(d.j, '$.data.lendingRates')), ('D', JSON_QUERY(d.j, '$.data.depositRates'))) AS k (kind, arr)
CROSS APPLY OPENJSON(k.arr) AS a
CROSS APPLY OPENJSON(a.value) WITH (lendingRateType varchar(40), depositRateType varchar(40), rate varchar(40), comparisonRate varchar(40),
    loanPurpose varchar(30), repaymentType varchar(30), calculationFrequency varchar(20), applicationType varchar(20), applicationFrequency varchar(20),
    interestPaymentDue varchar(20), additionalValue nvarchar(max), additionalInfo nvarchar(max), tiers nvarchar(max) AS JSON,
    applicabilityConditions nvarchar(max) AS JSON) AS r
OUTER APPLY stg.period(IIF(COALESCE(r.lendingRateType, r.depositRateType) IN ('FIXED', 'INTRODUCTORY'), r.additionalValue, NULL)) AS t;

UPDATE r SET reason = 'product writes rates as percentages' FROM #rate AS r  -- its values of 1 or below would be misread
WHERE reason IS NULL AND EXISTS (SELECT 1 FROM #rate AS x WHERE x.response_hash = r.response_hash AND x.reason LIKE 'rate above 1%');

INSERT stg.lending_rate
SELECT response_hash, rate_seq, rate_type, rate, comparison_rate, loanPurpose, repaymentType, months, days, calculationFrequency,
       applicationType, applicationFrequency, interestPaymentDue, additionalValue, additionalInfo
FROM #rate WHERE kind = 'L' AND reason IS NULL;

INSERT stg.deposit_rate
SELECT response_hash, rate_seq, rate_type, rate, months, days, calculationFrequency, applicationType, applicationFrequency, additionalValue, additionalInfo
FROM #rate WHERE kind = 'D' AND reason IS NULL;

INSERT stg.reject (response_hash, area, item_seq, field, raw_value, reason)
SELECT response_hash, IIF(kind = 'L', 'lending_rate', 'deposit_rate'), rate_seq, IIF(reason LIKE 'term%', 'additionalValue', 'rate'),
       LEFT(IIF(reason LIKE 'term%', additionalValue, raw_rate), 400), reason
FROM #rate WHERE reason IS NOT NULL;

--2d. Tiers and coded conditions of accepted rates; PERCENT tier values above 1 (80 rather than 0.8) are divided by 100
INSERT stg.rate_tier
SELECT r.response_hash, r.kind, r.rate_seq, a.[key], t.unitOfMeasure, v.mn / IIF(v.s = 1, 100, 1), v.mx / IIF(v.s = 1, 100, 1), v.s,
       t.rateApplicationMethod, t.name, t.additionalInfo
FROM #rate AS r CROSS APPLY OPENJSON(r.tiers) AS a
CROSS APPLY OPENJSON(a.value) WITH (name nvarchar(200), unitOfMeasure varchar(20), minimumValue varchar(40), maximumValue varchar(40),
    rateApplicationMethod varchar(20), additionalInfo nvarchar(max)) AS t
CROSS APPLY (SELECT mn, mx, IIF(t.unitOfMeasure = 'PERCENT' AND (mn > 1 OR mx > 1), 1, 0) AS s
             FROM (SELECT TRY_CAST(t.minimumValue AS decimal(20, 6)) AS mn, TRY_CAST(t.maximumValue AS decimal(20, 6)) AS mx) AS x) AS v
WHERE r.reason IS NULL;

INSERT stg.rate_condition
SELECT r.response_hash, r.kind, r.rate_seq, a.[key], c.rateApplicabilityType, c.additionalValue, c.additionalInfo
FROM #rate AS r CROSS APPLY OPENJSON(r.conditions) AS a
CROSS APPLY OPENJSON(a.value) WITH (rateApplicabilityType varchar(40), additionalValue nvarchar(max), additionalInfo nvarchar(max)) AS c
WHERE r.reason IS NULL;

--2e. Fees and their discounts; newer versions use fixedAmount / rateBased / variable, older ones amount and balance/transaction/accrued rates
INSERT stg.fee
SELECT d.response_hash, a.[key], f.name, f.feeType,
       COALESCE(f.feeMethodUType, IIF(f.amount IS NOT NULL, 'fixedAmount', IIF(COALESCE(f.balanceRate, f.transactionRate, f.accruedRate) IS NOT NULL, 'rateBased', NULL))),
       TRY_CAST(COALESCE(f.fixedAmount, f.amount) AS decimal(18, 4)),
       TRY_CAST(COALESCE(f.rbRate, f.balanceRate, f.transactionRate, f.accruedRate) AS decimal(12, 8)),
       COALESCE(f.rbRateType, CASE WHEN f.balanceRate IS NOT NULL THEN 'BALANCE' WHEN f.transactionRate IS NOT NULL THEN 'TRANSACTION'
                                   WHEN f.accruedRate IS NOT NULL THEN 'ACCRUED' END),
       TRY_CAST(COALESCE(f.varMin, f.rbMin) AS decimal(18, 4)), TRY_CAST(COALESCE(f.varMax, f.rbMax) AS decimal(18, 4)),
       COALESCE(f.rbAccrual, f.accrualFrequency), f.currency, f.additionalValue, f.additionalInfo
FROM #doc AS d CROSS APPLY OPENJSON(d.j, '$.data.fees') AS a
CROSS APPLY OPENJSON(a.value) WITH (name nvarchar(400), feeType varchar(30), feeMethodUType varchar(20), fixedAmount varchar(40) '$.fixedAmount.amount',
    amount varchar(40), rbRate varchar(40) '$.rateBased.rate', rbRateType varchar(20) '$.rateBased.rateType',
    rbAccrual varchar(20) '$.rateBased.accrualFrequency', rbMin varchar(40) '$.rateBased.amountRange.feeMinimum',
    rbMax varchar(40) '$.rateBased.amountRange.feeMaximum', varMin varchar(40) '$.variable.feeMinimum', varMax varchar(40) '$.variable.feeMaximum',
    balanceRate varchar(40), transactionRate varchar(40), accruedRate varchar(40), accrualFrequency varchar(20), currency char(3),
    additionalValue nvarchar(max), additionalInfo nvarchar(max)) AS f;

INSERT stg.fee_discount
SELECT d.response_hash, a.[key], b.[key], x.discountType, x.description, TRY_CAST(COALESCE(x.fixedAmount, x.amount) AS decimal(18, 4)),
       TRY_CAST(COALESCE(x.rbRate, x.balanceRate, x.transactionRate, x.accruedRate, x.feeRate) AS decimal(12, 8)),
       COALESCE(x.rbRateType, CASE WHEN x.balanceRate IS NOT NULL THEN 'BALANCE' WHEN x.transactionRate IS NOT NULL THEN 'TRANSACTION'
                                   WHEN x.accruedRate IS NOT NULL THEN 'ACCRUED' WHEN x.feeRate IS NOT NULL THEN 'FEE' END),
       x.additionalValue, x.additionalInfo
FROM #doc AS d CROSS APPLY OPENJSON(d.j, '$.data.fees') AS a CROSS APPLY OPENJSON(a.value, '$.discounts') AS b
CROSS APPLY OPENJSON(b.value) WITH (discountType varchar(30), description nvarchar(max), fixedAmount varchar(40) '$.fixedAmount.amount',
    amount varchar(40), rbRate varchar(40) '$.rateBased.rate', rbRateType varchar(20) '$.rateBased.rateType', balanceRate varchar(40),
    transactionRate varchar(40), accruedRate varchar(40), feeRate varchar(40), additionalValue nvarchar(max), additionalInfo nvarchar(max)) AS x;

--2f. Constraints (max LVR, minimum balance, limits)
INSERT stg.product_constraint
SELECT d.response_hash, a.[key], c.constraintType, TRY_CAST(c.additionalValue AS decimal(20, 6)), c.additionalValue, c.additionalInfo
FROM #doc AS d CROSS APPLY OPENJSON(d.j, '$.data.constraints') AS a
CROSS APPLY OPENJSON(a.value) WITH (constraintType varchar(30), additionalValue nvarchar(max), additionalInfo nvarchar(max)) AS c;

COMMIT;

SELECT (SELECT COUNT(*) FROM #doc) AS products, (SELECT COUNT(*) FROM #rate WHERE reason IS NULL) AS rates,
       (SELECT COUNT(*) FROM #rate WHERE reason IS NOT NULL) AS rates_rejected;
GO

--3. Index for finding detail responses by hash; the loader may run the procedure
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_fetch_log_response_hash')
    CREATE INDEX ix_fetch_log_response_hash ON raw.fetch_log (response_hash) INCLUDE (request_key, error);
GRANT EXECUTE ON stg.parse_new_responses TO loader;
