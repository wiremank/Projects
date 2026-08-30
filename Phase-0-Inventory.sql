/*==============================================================================
  Phase-0-Inventory.sql

  Run this FIRST, before Script-Database-Schema.sql. It writes no DDL -- it
  sizes the job, so you know what you are about to generate and how far to
  split it.

  Read-only. Catalog views only, under READ UNCOMMITTED. Nothing here locks
  anything a clerk would notice.

  What it reports:
      1  Environment       server, version, edition, compat level, collation
      2  Object census     counts by type, and by schema
      3  Size estimate     estimated output KB per phase + a suggested @PartCount
      4  Alias types       every user-defined type and the base type under it
      5  SyteLine layers   _mst tables vs _all views vs site views
      6  Customizations    uf_ / Uf_ / MMC_ objects, and uf_ columns by table
      7  Largest modules   the definitions that will dominate the output
      8  Encrypted modules the ones that CANNOT be scripted, listed up front

  Export it the same way as the catalog dump:

      sqlcmd -S <server>\<instance> -d MMC_V10 -E -W -s "|" -y 0 -Y 0 -h -1 ^
             -i Phase-0-Inventory.sql -o inventory.txt

  -W trims padding and -y 0 stops long values being truncated. Both matter.
==============================================================================*/

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

DECLARE @TopN int = 25;   -- how many rows in the "largest" / "most" lists

--------------------------------------------------------------------------------
PRINT '=== 1. ENVIRONMENT ===';
--------------------------------------------------------------------------------
SELECT  server_name    = CONVERT(sysname,       SERVERPROPERTY('ServerName')),
        database_name  = DB_NAME(),
        product        = CONVERT(nvarchar(50),  SERVERPROPERTY('ProductVersion')),
        edition        = CONVERT(nvarchar(50),  SERVERPROPERTY('Edition')),
        compat_level   = (SELECT compatibility_level FROM sys.databases WHERE database_id = DB_ID()),
        db_collation   = CONVERT(sysname, DATABASEPROPERTYEX(DB_NAME(), 'Collation')),
        looks_like_syteline =
            CASE WHEN EXISTS (SELECT 1 FROM sys.tables WHERE name LIKE '%[_]mst')
                 THEN 'yes' ELSE 'no' END;

--------------------------------------------------------------------------------
PRINT '';
PRINT '=== 2. OBJECT CENSUS ===';
--------------------------------------------------------------------------------
SELECT object_class = 'tables',              cnt = COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0
UNION ALL SELECT 'views',                    COUNT(*) FROM sys.views  WHERE is_ms_shipped = 0
UNION ALL SELECT 'procedures',               COUNT(*) FROM sys.procedures WHERE is_ms_shipped = 0
UNION ALL SELECT 'scalar functions',         COUNT(*) FROM sys.objects WHERE type = 'FN' AND is_ms_shipped = 0
UNION ALL SELECT 'inline TVFs',              COUNT(*) FROM sys.objects WHERE type = 'IF' AND is_ms_shipped = 0
UNION ALL SELECT 'multi-statement TVFs',     COUNT(*) FROM sys.objects WHERE type = 'TF' AND is_ms_shipped = 0
UNION ALL SELECT 'DML triggers',             COUNT(*) FROM sys.triggers WHERE parent_class = 1 AND is_ms_shipped = 0
UNION ALL SELECT 'DDL triggers (database)',  COUNT(*) FROM sys.triggers WHERE parent_class = 0 AND is_ms_shipped = 0
UNION ALL SELECT 'alias types',              COUNT(*) FROM sys.types WHERE is_user_defined = 1 AND is_table_type = 0
UNION ALL SELECT 'table types',              COUNT(*) FROM sys.table_types WHERE is_user_defined = 1
UNION ALL SELECT 'sequences',                COUNT(*) FROM sys.sequences
UNION ALL SELECT 'synonyms',                 COUNT(*) FROM sys.synonyms
UNION ALL SELECT 'schemas (non-system)',     COUNT(*) FROM sys.schemas
          WHERE schema_id < 16384 AND name NOT IN ('sys','INFORMATION_SCHEMA','guest')
UNION ALL SELECT 'columns',                  COUNT(*) FROM sys.columns c
          JOIN sys.objects o ON o.object_id = c.object_id WHERE o.is_ms_shipped = 0
UNION ALL SELECT 'primary key / unique',     COUNT(*) FROM sys.key_constraints WHERE is_ms_shipped = 0
UNION ALL SELECT 'default constraints',      COUNT(*) FROM sys.default_constraints WHERE is_ms_shipped = 0
UNION ALL SELECT 'check constraints',        COUNT(*) FROM sys.check_constraints WHERE is_ms_shipped = 0
UNION ALL SELECT 'foreign keys',             COUNT(*) FROM sys.foreign_keys WHERE is_ms_shipped = 0
UNION ALL SELECT 'indexes (non-constraint)', COUNT(*) FROM sys.indexes i
          JOIN sys.tables t ON t.object_id = i.object_id
          WHERE i.index_id > 0 AND i.is_primary_key = 0 AND i.is_unique_constraint = 0
            AND i.is_hypothetical = 0 AND i.name IS NOT NULL AND t.is_ms_shipped = 0
UNION ALL SELECT 'extended properties',      COUNT(*) FROM sys.extended_properties WHERE class IN (1,3)
ORDER BY object_class;

SELECT  schema_name = s.name,
        tables      = SUM(CASE WHEN o.type = 'U'  THEN 1 ELSE 0 END),
        views       = SUM(CASE WHEN o.type = 'V'  THEN 1 ELSE 0 END),
        procs       = SUM(CASE WHEN o.type = 'P'  THEN 1 ELSE 0 END),
        funcs       = SUM(CASE WHEN o.type IN ('FN','IF','TF') THEN 1 ELSE 0 END),
        total       = COUNT(*)
FROM    sys.objects o
JOIN    sys.schemas s ON s.schema_id = o.schema_id
WHERE   o.is_ms_shipped = 0
  AND   o.type IN ('U','V','P','FN','IF','TF')
GROUP BY s.name
ORDER BY total DESC;

--------------------------------------------------------------------------------
PRINT '';
PRINT '=== 3. ESTIMATED OUTPUT SIZE PER PHASE ===';
PRINT 'est_kb is a rough forecast of the generated script, not a measurement.';
PRINT 'suggested_parts aims at roughly 20 MB per file; phase 5 is never split.';
--------------------------------------------------------------------------------
DECLARE @est TABLE (phase int, phase_name varchar(40), objects int, est_kb int);

-- module text is measured directly; DDL we synthesise is estimated from shape
INSERT @est (phase, phase_name, objects, est_kb)
SELECT 1, 'FOUNDATION (types, sequences)',
       (SELECT COUNT(*) FROM sys.types WHERE is_user_defined = 1)
     + (SELECT COUNT(*) FROM sys.sequences),
       ((SELECT COUNT(*) FROM sys.types WHERE is_user_defined = 1) * 90
      + (SELECT COUNT(*) FROM sys.sequences) * 150) / 1024 + 1;

INSERT @est (phase, phase_name, objects, est_kb)
SELECT 2, 'TABLES (+ PK / unique)',
       (SELECT COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0),
       (SELECT SUM(CONVERT(bigint, LEN(c.name) + 48)) FROM sys.columns c
        JOIN sys.tables t ON t.object_id = c.object_id WHERE t.is_ms_shipped = 0) / 1024 + 1;

INSERT @est (phase, phase_name, objects, est_kb)
SELECT 3, 'INTEGRITY (defaults, checks, indexes)',
       (SELECT COUNT(*) FROM sys.default_constraints WHERE is_ms_shipped = 0)
     + (SELECT COUNT(*) FROM sys.check_constraints WHERE is_ms_shipped = 0)
     + (SELECT COUNT(*) FROM sys.indexes i JOIN sys.tables t ON t.object_id = i.object_id
        WHERE i.index_id > 0 AND i.is_primary_key = 0 AND i.is_unique_constraint = 0
          AND i.name IS NOT NULL AND t.is_ms_shipped = 0),
       ((SELECT ISNULL(SUM(LEN(definition) + 80), 0) FROM sys.default_constraints WHERE is_ms_shipped = 0)
      + (SELECT ISNULL(SUM(LEN(definition) + 90), 0) FROM sys.check_constraints WHERE is_ms_shipped = 0)
      + (SELECT COUNT(*) * 160 FROM sys.indexes i JOIN sys.tables t ON t.object_id = i.object_id
         WHERE i.index_id > 0 AND i.is_primary_key = 0 AND i.is_unique_constraint = 0
           AND i.name IS NOT NULL AND t.is_ms_shipped = 0)) / 1024 + 1;

INSERT @est (phase, phase_name, objects, est_kb)
SELECT 4, 'RELATIONS (foreign keys)',
       (SELECT COUNT(*) FROM sys.foreign_keys WHERE is_ms_shipped = 0),
       (SELECT COUNT(*) * 220 FROM sys.foreign_keys WHERE is_ms_shipped = 0) / 1024 + 1;

INSERT @est (phase, phase_name, objects, est_kb)
SELECT 5, 'VIEWS + FUNCTIONS (never split)',
       (SELECT COUNT(*) FROM sys.objects WHERE type IN ('V','FN','IF','TF') AND is_ms_shipped = 0),
       (SELECT ISNULL(SUM(CONVERT(bigint, DATALENGTH(m.definition))), 0)
        FROM sys.sql_modules m JOIN sys.objects o ON o.object_id = m.object_id
        WHERE o.type IN ('V','FN','IF','TF') AND o.is_ms_shipped = 0) / 1024 + 1;

INSERT @est (phase, phase_name, objects, est_kb)
SELECT 6, 'PROCEDURES',
       (SELECT COUNT(*) FROM sys.procedures WHERE is_ms_shipped = 0),
       (SELECT ISNULL(SUM(CONVERT(bigint, DATALENGTH(m.definition))), 0)
        FROM sys.sql_modules m JOIN sys.objects o ON o.object_id = m.object_id
        WHERE o.type = 'P' AND o.is_ms_shipped = 0) / 1024 + 1;

INSERT @est (phase, phase_name, objects, est_kb)
SELECT 7, 'TRIGGERS',
       (SELECT COUNT(*) FROM sys.triggers WHERE is_ms_shipped = 0),
       (SELECT ISNULL(SUM(CONVERT(bigint, DATALENGTH(m.definition))), 0)
        FROM sys.sql_modules m JOIN sys.triggers tr ON tr.object_id = m.object_id
        WHERE tr.is_ms_shipped = 0) / 1024 + 1;

INSERT @est (phase, phase_name, objects, est_kb)
SELECT 8, 'EXTRAS (synonyms, ext props, perms)',
       (SELECT COUNT(*) FROM sys.synonyms)
     + (SELECT COUNT(*) FROM sys.extended_properties WHERE class IN (1,3)),
       ((SELECT COUNT(*) * 120 FROM sys.synonyms)
      + (SELECT ISNULL(SUM(DATALENGTH(CONVERT(nvarchar(max), value)) / 2 + 180), 0)
         FROM sys.extended_properties WHERE class IN (1,3))) / 1024 + 1;

SELECT  phase, phase_name, objects, est_kb,
        est_mb = CONVERT(decimal(9,1), est_kb / 1024.0),
        suggested_parts =
            CASE WHEN phase = 5 THEN 1
                 WHEN est_kb <= 20480 THEN 1
                 ELSE (est_kb / 20480) + 1 END
FROM    @est
ORDER BY phase;

SELECT  total_est_mb = CONVERT(decimal(9,1), SUM(est_kb) / 1024.0) FROM @est;

--------------------------------------------------------------------------------
PRINT '';
PRINT '=== 4. ALIAS TYPES (phase 1 must emit these before any table) ===';
--------------------------------------------------------------------------------
SELECT  alias_type = QUOTENAME(s.name) + '.' + QUOTENAME(t.name),
        base_type  =
            CASE
                WHEN bt.name IN ('varchar','char','varbinary','binary')
                     THEN bt.name + '(' + CASE WHEN t.max_length = -1 THEN 'max'
                                               ELSE CONVERT(varchar(10), t.max_length) END + ')'
                WHEN bt.name IN ('nvarchar','nchar')
                     THEN bt.name + '(' + CASE WHEN t.max_length = -1 THEN 'max'
                                               ELSE CONVERT(varchar(10), t.max_length / 2) END + ')'
                WHEN bt.name IN ('decimal','numeric')
                     THEN bt.name + '(' + CONVERT(varchar(10), t.precision) + ',' +
                          CONVERT(varchar(10), t.scale) + ')'
                ELSE bt.name
            END,
        nullable   = CASE WHEN t.is_nullable = 1 THEN 'NULL' ELSE 'NOT NULL' END,
        used_by_columns = (SELECT COUNT(*) FROM sys.columns c WHERE c.user_type_id = t.user_type_id)
FROM    sys.types t
JOIN    sys.schemas s ON s.schema_id = t.schema_id
JOIN    sys.types bt  ON bt.user_type_id = t.system_type_id AND bt.is_user_defined = 0
WHERE   t.is_user_defined = 1
  AND   t.is_table_type = 0
ORDER BY used_by_columns DESC, t.name;

--------------------------------------------------------------------------------
PRINT '';
PRINT '=== 5. SYTELINE LAYERS (_mst table / _all view / site view) ===';
--------------------------------------------------------------------------------
SELECT  layer = '_mst tables',        cnt = COUNT(*) FROM sys.tables
        WHERE is_ms_shipped = 0 AND name LIKE '%[_]mst'
UNION ALL
SELECT  'tables without _mst',        COUNT(*) FROM sys.tables
        WHERE is_ms_shipped = 0 AND name NOT LIKE '%[_]mst'
UNION ALL
SELECT  '_all views',                 COUNT(*) FROM sys.views
        WHERE is_ms_shipped = 0 AND name LIKE '%[_]all'
UNION ALL
SELECT  'site views (has a _mst)',    COUNT(*) FROM sys.views v
        WHERE v.is_ms_shipped = 0 AND v.name NOT LIKE '%[_]all'
          AND EXISTS (SELECT 1 FROM sys.tables t WHERE t.name = v.name + '_mst')
UNION ALL
SELECT  'other views',                COUNT(*) FROM sys.views v
        WHERE v.is_ms_shipped = 0 AND v.name NOT LIKE '%[_]all'
          AND NOT EXISTS (SELECT 1 FROM sys.tables t WHERE t.name = v.name + '_mst');

--------------------------------------------------------------------------------
PRINT '';
PRINT '=== 6. CUSTOMIZATIONS ===';
--------------------------------------------------------------------------------
SELECT  custom_objects_by_type = o.type_desc, cnt = COUNT(*)
FROM    sys.objects o
WHERE   o.is_ms_shipped = 0
  AND   (o.name LIKE 'uf[_]%' OR o.name LIKE 'Uf[_]%' OR o.name LIKE 'MMC[_]%')
GROUP BY o.type_desc
ORDER BY cnt DESC;

-- Custom COLUMNS sit inside stock tables, so no object-name filter finds them.
SELECT TOP (@TopN)
        table_with_custom_columns = QUOTENAME(s.name) + '.' + QUOTENAME(t.name),
        custom_columns = COUNT(*),
        column_list    = STUFF((SELECT ', ' + c2.name
                                FROM   sys.columns c2
                                WHERE  c2.object_id = t.object_id AND c2.name LIKE 'uf[_]%'
                                ORDER  BY c2.column_id
                                FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, '')
FROM    sys.columns c
JOIN    sys.tables  t ON t.object_id = c.object_id
JOIN    sys.schemas s ON s.schema_id = t.schema_id
WHERE   c.name LIKE 'uf[_]%'
  AND   t.is_ms_shipped = 0
GROUP BY s.name, t.name, t.object_id
ORDER BY custom_columns DESC;

--------------------------------------------------------------------------------
PRINT '';
PRINT '=== 7. LARGEST MODULES ===';
--------------------------------------------------------------------------------
SELECT TOP (@TopN)
        object_name = QUOTENAME(s.name) + '.' + QUOTENAME(o.name),
        object_type = o.type_desc,
        definition_kb = DATALENGTH(m.definition) / 2048
FROM    sys.sql_modules m
JOIN    sys.objects o ON o.object_id = m.object_id
JOIN    sys.schemas s ON s.schema_id = o.schema_id
WHERE   o.is_ms_shipped = 0
ORDER BY DATALENGTH(m.definition) DESC;

--------------------------------------------------------------------------------
PRINT '';
PRINT '=== 8. ENCRYPTED MODULES (cannot be scripted -- get these from source) ===';
--------------------------------------------------------------------------------
SELECT  object_name = QUOTENAME(s.name) + '.' + QUOTENAME(o.name),
        object_type = o.type_desc
FROM    sys.sql_modules m
JOIN    sys.objects o ON o.object_id = m.object_id
JOIN    sys.schemas s ON s.schema_id = o.schema_id
WHERE   m.definition IS NULL
  AND   o.is_ms_shipped = 0
ORDER BY s.name, o.name;

PRINT '';
PRINT '=== END OF INVENTORY ===';
