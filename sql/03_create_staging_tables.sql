--1. Schema; drop existing staging tables (children first), as staging is rebuilt from raw
IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg');
DROP TABLE IF EXISTS stg.fee_discount, stg.rate_tier, stg.lending_rate, stg.deposit_rate, stg.fee, stg.product_constraint, stg.reject, stg.product;
GO

--2. Tables: one row per distinct product detail response, and its rates, tiers, fees and constraints. Rates are fractions (0.0619 = 6.19%)
CREATE TABLE stg.product (
    response_hash binary(32) PRIMARY KEY, product_id nvarchar(300) NOT NULL, product_category varchar(50) NOT NULL,
    name nvarchar(400) NOT NULL, description nvarchar(max), brand nvarchar(200),
    last_updated datetimeoffset(0), effective_from datetimeoffset(0), effective_to datetimeoffset(0), is_tailored bit);

CREATE TABLE stg.lending_rate (
    response_hash binary(32) REFERENCES stg.product, rate_seq smallint, lending_rate_type varchar(40) NOT NULL,
    rate decimal(12, 8) NOT NULL, comparison_rate decimal(12, 8), loan_purpose varchar(30), repayment_type varchar(30),
    term_months smallint, term_days smallint, calculation_frequency varchar(20), application_type varchar(20),
    application_frequency varchar(20), interest_payment_due varchar(20), additional_value nvarchar(max), additional_info nvarchar(max),
    PRIMARY KEY (response_hash, rate_seq));

CREATE TABLE stg.deposit_rate (
    response_hash binary(32) REFERENCES stg.product, rate_seq smallint, deposit_rate_type varchar(40) NOT NULL,
    rate decimal(12, 8) NOT NULL, term_months smallint, term_days smallint, calculation_frequency varchar(20),
    application_type varchar(20), application_frequency varchar(20), additional_value nvarchar(max), additional_info nvarchar(max),
    PRIMARY KEY (response_hash, rate_seq));

CREATE TABLE stg.rate_tier (
    response_hash binary(32), rate_kind char(1) CHECK (rate_kind IN ('L', 'D')), rate_seq smallint, tier_seq smallint,
    unit_of_measure varchar(20), minimum_value decimal(20, 6), maximum_value decimal(20, 6), scaled_from_percent bit NOT NULL,
    rate_application_method varchar(20), tier_name nvarchar(200), additional_info nvarchar(max),
    PRIMARY KEY (response_hash, rate_kind, rate_seq, tier_seq));

CREATE TABLE stg.fee (
    response_hash binary(32) REFERENCES stg.product, fee_seq smallint, name nvarchar(400) NOT NULL, fee_type varchar(30) NOT NULL,
    fee_method varchar(20), amount decimal(18, 4), rate decimal(12, 8), rate_type varchar(20), amount_min decimal(18, 4),
    amount_max decimal(18, 4), accrual_frequency varchar(20), currency char(3), additional_value nvarchar(max), additional_info nvarchar(max),
    PRIMARY KEY (response_hash, fee_seq));

CREATE TABLE stg.fee_discount (
    response_hash binary(32), fee_seq smallint, discount_seq smallint, discount_type varchar(30) NOT NULL, description nvarchar(max),
    amount decimal(18, 4), rate decimal(12, 8), rate_type varchar(20), additional_value nvarchar(max), additional_info nvarchar(max),
    PRIMARY KEY (response_hash, fee_seq, discount_seq), FOREIGN KEY (response_hash, fee_seq) REFERENCES stg.fee);

CREATE TABLE stg.product_constraint (
    response_hash binary(32) REFERENCES stg.product, constraint_seq smallint, constraint_type varchar(30) NOT NULL,
    value_numeric decimal(20, 6), additional_value nvarchar(max), additional_info nvarchar(max),
    PRIMARY KEY (response_hash, constraint_seq));

CREATE TABLE stg.reject (
    reject_id int IDENTITY PRIMARY KEY, response_hash binary(32) NOT NULL, area varchar(30) NOT NULL, item_seq smallint,
    field varchar(50), raw_value nvarchar(400), reason nvarchar(200) NOT NULL);
GO

--3. Check
SELECT t.name, COUNT(*) AS columns FROM sys.tables AS t JOIN sys.columns AS c ON c.object_id = t.object_id
WHERE t.schema_id = SCHEMA_ID('stg') GROUP BY t.name ORDER BY t.name;
