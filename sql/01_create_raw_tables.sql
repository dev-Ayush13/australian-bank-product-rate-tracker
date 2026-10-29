--1. Schema
IF SCHEMA_ID('raw') IS NULL EXEC('CREATE SCHEMA raw');
GO

--2. Distinct responses, gzip-compressed, stored once per content hash
CREATE TABLE raw.response (
    response_hash   binary(32)     NOT NULL CONSTRAINT pk_response PRIMARY KEY,
    body_gzip       varbinary(max) NOT NULL,
    bytes_raw       int            NOT NULL,
    first_seen_date date           NOT NULL,
    loaded_at       datetime2(0)   NOT NULL CONSTRAINT df_response_loaded_at DEFAULT SYSUTCDATETIME()
);
GO

--3. Every request made each day, pointing to the response it returned
CREATE TABLE raw.fetch_log (
    fetch_date    date          NOT NULL,
    source_id     varchar(64)   NOT NULL,
    request_key   nvarchar(300) NOT NULL,
    http_status   smallint      NULL,
    api_version   tinyint       NULL,
    response_hash binary(32)    NULL CONSTRAINT fk_fetch_log_response REFERENCES raw.response (response_hash),
    error         nvarchar(400) NULL,
    fetched_at    datetime2(0)  NOT NULL,
    CONSTRAINT pk_fetch_log PRIMARY KEY (fetch_date, source_id, request_key),
    CONSTRAINT ck_fetch_log_outcome CHECK (response_hash IS NOT NULL OR error IS NOT NULL)
);
GO

--4. One outcome per brand per day
CREATE TABLE raw.collection_run (
    run_date       date          NOT NULL,
    brand_id       varchar(64)   NOT NULL,
    brand_name     nvarchar(200) NOT NULL,
    status         varchar(20)   NOT NULL CONSTRAINT ck_collection_run_status CHECK (status IN ('ok', 'empty', 'count_mismatch', 'detail_errors', 'failed')),
    list_attempts  tinyint       NULL,
    list_version   tinyint       NULL,
    detail_version tinyint       NULL,
    products       int           NULL,
    total_records  int           NULL,
    in_scope       int           NULL,
    detail_failed  int           NULL,
    error          nvarchar(400) NULL,
    seconds        int           NOT NULL,
    CONSTRAINT pk_collection_run PRIMARY KEY (run_date, brand_id)
);
GO

--5. Check
SELECT s.name AS schema_name, t.name AS table_name
FROM sys.tables AS t
JOIN sys.schemas AS s ON s.schema_id = t.schema_id
WHERE s.name = 'raw'
ORDER BY t.name;
