--1. User for the scheduled loader: exists only in this database, no server-level login.
--   Run this statement separately in an unsaved query tab with a real password. Never save the password in this file.
--   CREATE USER loader WITH PASSWORD = '<strong password>';

--2. Read and add raw data; delete only the per-day rows the loader replaces. Stored responses cannot be deleted or changed.
GRANT SELECT, INSERT ON SCHEMA::raw TO loader;
GRANT DELETE ON raw.fetch_log TO loader;
GRANT DELETE ON raw.collection_run TO loader;

--3. Check
SELECT p.permission_name,
       CASE p.class WHEN 0 THEN 'database' WHEN 3 THEN SCHEMA_NAME(p.major_id)
            ELSE OBJECT_SCHEMA_NAME(p.major_id) + '.' + OBJECT_NAME(p.major_id) END AS applies_to
FROM sys.database_permissions AS p
JOIN sys.database_principals AS u ON u.principal_id = p.grantee_principal_id
WHERE u.name = 'loader'
ORDER BY applies_to, p.permission_name;
