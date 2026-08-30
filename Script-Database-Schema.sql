/*==============================================================================
  Script-Database-Schema.sql

  Scripts out a SQL Server database schema -- tables, views, functions, stored
  procedures, triggers, indexes, constraints, types, everything -- using nothing
  but T-SQL. No SMO, no PowerShell, no SSMS wizard. Run it in the database you
  want to script (USE YourDb first) and capture the output.

  Built for a large ERP schema (SyteLine / CloudSuite Industrial), so it runs in
  PHASES. Start at phase 1, check what comes back, move up. Set @Phase = 99 to
  take the whole thing in one pass on a small database.

      PHASE 1  FOUNDATION        schemas, alias types, table types, sequences
      PHASE 2  TABLES            CREATE TABLE + primary key / unique
      PHASE 3  INTEGRITY         defaults, check constraints, indexes
      PHASE 4  RELATIONS         foreign keys
      PHASE 5  VIEWS + FUNCTIONS dependency-ordered together
      PHASE 6  PROCEDURES
      PHASE 7  TRIGGERS
      PHASE 8  EXTRAS            synonyms, extended properties, permissions

  The phases replay in numeric order on an empty database: types before the
  tables that use them, tables before their indexes, everything before the
  foreign keys that tie them together.

  Phases 2, 3, 4, 6 and 7 can be split further with @PartCount / @PartNumber
  when one phase is still too big to handle in one file. Phase 5 cannot be
  split -- see the note on it below.

  WHY VIEWS AND FUNCTIONS SHARE A PHASE
  CREATE VIEW and CREATE FUNCTION resolve their references at creation time.
  Stored procedures and triggers get deferred name resolution and will compile
  against objects that do not exist yet; views and functions will not. So those
  two are emitted together, in one dependency order (a view over a view, a view
  calling a function, a function selecting from a view), and never split.

  SYTELINE NOTES
    * Every SyteLine column is declared with an alias type -- AmountType,
      VendNumType, DateType -- so phase 1 is not optional. Emit the types first
      or every CREATE TABLE in phase 2 fails.
    * The _mst / _all / site-view layering falls out naturally: _mst tables come
      in phase 2, the _all and site views in phase 5, in the right order.
    * Objects Infor ships are user objects (is_ms_shipped = 0), so they are all
      in scope. @CustomObjectsOnly narrows to the uf_ / Uf_ / MMC_ naming
      convention, but custom COLUMNS live inside stock tables and that switch
      will not find them -- Phase-0-Inventory.sql reports those separately.
    * Read-only: catalog SELECTs under READ UNCOMMITTED. It takes no locks a
      clerk would notice and writes nothing.

  OUTPUT MODES (@OutputMode)
      'PRINT'   Prints the script to the Messages tab, chunked at line
                boundaries so nothing is truncated. This is the one to use with
                sqlcmd -o.
      'ROWS'    One row per statement (schema, object, type, text).
      'SINGLE'  The whole script in one nvarchar(max) cell. In SSMS raise
                Tools > Options > Query Results > SQL Server > Results to Grid >
                Maximum Characters Retrieved first, or it gets clipped.

  RUNNING ONE PHASE FROM THE COMMAND LINE
      sqlcmd -S server -d MMC_V10 -E -b -i Script-Database-Schema.sql -o phase.sql
  Export-SytelineSchema.ps1 in this repo drives all the phases in order and
  writes one numbered file per phase, plus a master file that replays them.

  KNOWN LIMITATIONS (deliberate -- kept out to keep the script readable)
      * Filegroups, partition schemes/functions, FILESTREAM and
        memory-optimized table options are not emitted; everything lands on
        the default filegroup.
      * XML schema collections, CLR assemblies/types, full-text catalogs,
        service broker objects, users/roles/logins are not emitted.
      * Encrypted modules (WITH ENCRYPTION) cannot be read; a comment is
        emitted in their place.
      * Table types get their columns and PK/UNIQUE, not their check or
        default constraints.

  Targets SQL Server 2016+ and avoids syntax newer than 2012 (no STRING_AGG,
  no DROP ... IF EXISTS), so it also runs on older instances.
==============================================================================*/

SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;   -- never block clerks

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------
-- Which slice of the schema to emit. On a small database leave this at 99 and
-- take the lot; on an ERP schema work up through the phases one at a time.
--
--    1  FOUNDATION   schemas, alias types, table types, sequences
--    2  TABLES       CREATE TABLE + primary key / unique constraints
--    3  INTEGRITY    defaults, check constraints, indexes
--    4  RELATIONS    foreign keys
--    5  PROGRAMMABILITY-1  views and functions, dependency-ordered together
--    6  PROCEDURES
--    7  TRIGGERS
--    8  EXTRAS       synonyms, extended properties, permissions
--   99  ALL          every phase in one pass
--
-- Phases replay in numeric order, so 1..8 concatenated == 99.
DECLARE @Phase                      int = 99;

-- Split one phase across several runs. Phase 6 on a SyteLine database is
-- thousands of procedures; @PartCount = 8 with @PartNumber 1..8 gives eight
-- files you can generate and review separately. Bucketing is by object name,
-- so a given table lands in the same part in every phase, and part 1 is the
-- only part that carries the small one-off sections.
--
-- Phase 5 ignores @PartCount: views and functions bind at creation time, so
-- they have to be emitted whole, in one dependency order.
DECLARE @PartCount                  int = 1;
DECLARE @PartNumber                 int = 1;

DECLARE @SchemaFilter               nvarchar(4000) = NULL;   -- N'dbo,sales'  NULL = every schema
DECLARE @NameFilter                 nvarchar(4000) = NULL;   -- LIKE pattern, e.g. N'usp[_]%'  NULL = every object
DECLARE @ExcludeNameLike            nvarchar(4000) = NULL;   -- comma-separated LIKE patterns to drop,
                                                             -- e.g. N'%_all,%_wa,tmp[_]%'
DECLARE @CustomObjectsOnly          bit = 0;   -- keep only objects named per Infor's custom-object
                                               -- convention: uf_%, Uf_%, MMC_%. Note that custom
                                               -- COLUMNS (uf_...) live inside stock tables, so this
                                               -- switch will not find them -- Phase-0-Inventory.sql
                                               -- reports those separately.

DECLARE @IncludeSchemas             bit = 1;
DECLARE @IncludeUserDefinedTypes    bit = 1;
DECLARE @IncludeSequences           bit = 1;
DECLARE @IncludeTables              bit = 1;
DECLARE @IncludeKeyConstraints      bit = 1;   -- primary key / unique
DECLARE @IncludeDefaults            bit = 1;
DECLARE @IncludeCheckConstraints    bit = 1;
DECLARE @IncludeIndexes             bit = 1;
DECLARE @IncludeViews               bit = 1;
DECLARE @IncludeFunctions           bit = 1;
DECLARE @IncludeProcedures          bit = 1;
DECLARE @IncludeTriggers            bit = 1;
DECLARE @IncludeForeignKeys         bit = 1;
DECLARE @IncludeSynonyms            bit = 1;
DECLARE @IncludeExtendedProperties  bit = 1;
DECLARE @IncludePermissions         bit = 0;   -- GRANT / DENY on objects

DECLARE @DropIfExists               bit = 0;   -- prefix modules and synonyms with a drop guard
DECLARE @OrderByDependency     bit = 1;   -- topologically sort view-on-view references
DECLARE @OutputMode                 varchar(10) = 'PRINT';   -- 'PRINT' | 'ROWS' | 'SINGLE'

--------------------------------------------------------------------------------
-- Phase presets
--   A phase other than 99 overrides the @Include* switches above. Set @Phase to
--   99 if you want to drive the switches by hand.
--------------------------------------------------------------------------------
IF @Phase <> 99
BEGIN
    SELECT @IncludeSchemas            = 0, @IncludeUserDefinedTypes = 0,
           @IncludeSequences          = 0, @IncludeTables           = 0,
           @IncludeKeyConstraints     = 0, @IncludeDefaults         = 0,
           @IncludeCheckConstraints   = 0, @IncludeIndexes          = 0,
           @IncludeViews              = 0, @IncludeFunctions        = 0,
           @IncludeProcedures         = 0, @IncludeTriggers         = 0,
           @IncludeForeignKeys        = 0, @IncludeSynonyms         = 0,
           @IncludeExtendedProperties = 0, @IncludePermissions      = 0;

    IF @Phase = 1 SELECT @IncludeSchemas = 1, @IncludeUserDefinedTypes = 1, @IncludeSequences = 1;
    IF @Phase = 2 SELECT @IncludeTables = 1, @IncludeKeyConstraints = 1;
    IF @Phase = 3 SELECT @IncludeDefaults = 1, @IncludeCheckConstraints = 1, @IncludeIndexes = 1;
    IF @Phase = 4 SELECT @IncludeForeignKeys = 1;
    IF @Phase = 5 SELECT @IncludeViews = 1, @IncludeFunctions = 1;
    IF @Phase = 6 SELECT @IncludeProcedures = 1;
    IF @Phase = 7 SELECT @IncludeTriggers = 1;
    IF @Phase = 8 SELECT @IncludeSynonyms = 1, @IncludeExtendedProperties = 1, @IncludePermissions = 1;
END

IF @PartCount < 1 SET @PartCount = 1;
IF @PartNumber < 1 OR @PartNumber > @PartCount
BEGIN
    RAISERROR('@PartNumber must be between 1 and @PartCount.', 16, 1);
    RETURN;
END

-- The small one-off sections (schemas, types, sequences, synonyms, extended
-- properties, permissions) are emitted by part 1 only, so splitting a phase
-- never duplicates them.
DECLARE @FirstPart bit = CASE WHEN @PartNumber = 1 THEN 1 ELSE 0 END;

--------------------------------------------------------------------------------
-- Working storage
--------------------------------------------------------------------------------
DECLARE @crlf nchar(2) = NCHAR(13) + NCHAR(10);
DECLARE @dbCollation sysname = CONVERT(sysname, DATABASEPROPERTYEX(DB_NAME(), 'Collation'));
DECLARE @majorVersion int = CONVERT(int, PARSENAME(CONVERT(varchar(50), SERVERPROPERTY('ProductVersion')), 4));

IF OBJECT_ID('tempdb..#script')       IS NOT NULL DROP TABLE #script;
IF OBJECT_ID('tempdb..#schema_filter') IS NOT NULL DROP TABLE #schema_filter;
IF OBJECT_ID('tempdb..#module_dep')    IS NOT NULL DROP TABLE #module_dep;
IF OBJECT_ID('tempdb..#module_level')  IS NOT NULL DROP TABLE #module_level;

CREATE TABLE #script
(
    id          int IDENTITY(1,1) NOT NULL PRIMARY KEY,
    sort_order  int      NOT NULL,
    sub_order   int      NOT NULL DEFAULT (0),
    object_type varchar(30)  NOT NULL,
    schema_name sysname  NULL,
    object_name sysname  NULL,
    script_text nvarchar(max) NOT NULL
);

CREATE TABLE #schema_filter    (name sysname NOT NULL PRIMARY KEY);
CREATE TABLE #exclude_pattern  (pattern nvarchar(200) NOT NULL PRIMARY KEY);

-- Split @SchemaFilter on commas.
DECLARE @rest nvarchar(4000);
DECLARE @one  nvarchar(4000);
DECLARE @pos  int;

IF @SchemaFilter IS NOT NULL
BEGIN
    SET @rest = @SchemaFilter + N',';

    WHILE CHARINDEX(N',', @rest) > 0
    BEGIN
        SET @pos  = CHARINDEX(N',', @rest);
        SET @one  = LTRIM(RTRIM(REPLACE(REPLACE(LEFT(@rest, @pos - 1), N'[', N''), N']', N'')));
        SET @rest = SUBSTRING(@rest, @pos + 1, LEN(@rest + N'|'));

        IF @one <> N'' AND NOT EXISTS (SELECT 1 FROM #schema_filter WHERE name = @one)
            INSERT #schema_filter (name) VALUES (@one);
    END
END

-- Split @ExcludeNameLike on commas. Each element is a LIKE pattern.
IF @ExcludeNameLike IS NOT NULL
BEGIN
    SET @rest = @ExcludeNameLike + N',';

    WHILE CHARINDEX(N',', @rest) > 0
    BEGIN
        SET @pos  = CHARINDEX(N',', @rest);
        SET @one  = LTRIM(RTRIM(LEFT(@rest, @pos - 1)));
        SET @rest = SUBSTRING(@rest, @pos + 1, LEN(@rest + N'|'));

        IF @one <> N'' AND NOT EXISTS (SELECT 1 FROM #exclude_pattern WHERE pattern = @one)
            INSERT #exclude_pattern (pattern) VALUES (@one);
    END
END

--------------------------------------------------------------------------------
-- 1. Schemas
--------------------------------------------------------------------------------
IF @IncludeSchemas = 1 AND @FirstPart = 1
    INSERT #script (sort_order, object_type, schema_name, object_name, script_text)
    SELECT 100, 'SCHEMA', s.name, s.name,
           N'IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = ' + QUOTENAME(s.name, '''') + N')' + @crlf +
           N'    EXEC (''CREATE SCHEMA ' + REPLACE(QUOTENAME(s.name), N'''', N'''''') +
           N' AUTHORIZATION ' + REPLACE(QUOTENAME(dp.name), N'''', N'''''') + N''');'
    FROM   sys.schemas s
    JOIN   sys.database_principals dp ON dp.principal_id = s.principal_id
    WHERE  s.schema_id < 16384                                  -- exclude the auto-created role schemas
      AND  s.name NOT IN (N'dbo', N'guest', N'sys', N'INFORMATION_SCHEMA')
      AND  (@SchemaFilter IS NULL OR s.name IN (SELECT name FROM #schema_filter));

--------------------------------------------------------------------------------
-- 2a. User-defined data types (alias types)
--------------------------------------------------------------------------------
IF @IncludeUserDefinedTypes = 1 AND @FirstPart = 1
    INSERT #script (sort_order, object_type, schema_name, object_name, script_text)
    SELECT 200, 'TYPE', s.name, t.name,
           N'CREATE TYPE ' + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name) + N' FROM ' +
           CASE
               WHEN bt.name IN (N'varchar', N'char', N'varbinary', N'binary')
                    THEN bt.name + N'(' + CASE WHEN t.max_length = -1 THEN N'max'
                                               ELSE CONVERT(nvarchar(10), t.max_length) END + N')'
               WHEN bt.name IN (N'nvarchar', N'nchar')
                    THEN bt.name + N'(' + CASE WHEN t.max_length = -1 THEN N'max'
                                               ELSE CONVERT(nvarchar(10), t.max_length / 2) END + N')'
               WHEN bt.name IN (N'decimal', N'numeric')
                    THEN bt.name + N'(' + CONVERT(nvarchar(10), t.precision) + N',' + CONVERT(nvarchar(10), t.scale) + N')'
               WHEN bt.name IN (N'datetime2', N'datetimeoffset', N'time')
                    THEN bt.name + N'(' + CONVERT(nvarchar(10), t.scale) + N')'
               ELSE bt.name
           END +
           CASE WHEN t.is_nullable = 1 THEN N' NULL' ELSE N' NOT NULL' END + N';'
    FROM   sys.types t
    JOIN   sys.schemas s ON s.schema_id = t.schema_id
    JOIN   sys.types bt  ON bt.user_type_id = t.system_type_id AND bt.is_user_defined = 0
    WHERE  t.is_user_defined = 1
      AND  t.is_table_type = 0
      AND  t.is_assembly_type = 0
      AND  (@SchemaFilter IS NULL OR s.name IN (SELECT name FROM #schema_filter))
      AND  (@NameFilter IS NULL OR t.name LIKE @NameFilter)
      AND  (@ExcludeNameLike IS NULL OR NOT EXISTS
                (SELECT 1 FROM #exclude_pattern x WHERE t.name LIKE x.pattern))
      AND  (@CustomObjectsOnly = 0 OR t.name LIKE N'uf[_]%'
                                   OR t.name LIKE N'Uf[_]%'
                                   OR t.name LIKE N'MMC[_]%');

--------------------------------------------------------------------------------
-- 2b. User-defined table types
--------------------------------------------------------------------------------
IF @IncludeUserDefinedTypes = 1 AND @FirstPart = 1
    INSERT #script (sort_order, object_type, schema_name, object_name, script_text)
    SELECT 210, 'TABLE TYPE', s.name, tt.name,
           N'CREATE TYPE ' + QUOTENAME(s.name) + N'.' + QUOTENAME(tt.name) + N' AS TABLE' + @crlf + N'(' +
           STUFF((
                SELECT  N',' + @crlf + N'    ' + QUOTENAME(c.name) + N' ' +
                        CASE
                            WHEN cc.definition IS NOT NULL
                                 THEN N'AS ' + cc.definition +
                                      CASE WHEN cc.is_persisted = 1 THEN N' PERSISTED' ELSE N'' END
                            ELSE
                                CASE
                                    WHEN ty.is_user_defined = 1 THEN QUOTENAME(tys.name) + N'.' + QUOTENAME(ty.name)
                                    WHEN ty.name IN (N'varchar', N'char', N'varbinary', N'binary')
                                         THEN ty.name + N'(' + CASE WHEN c.max_length = -1 THEN N'max'
                                                                    ELSE CONVERT(nvarchar(10), c.max_length) END + N')'
                                    WHEN ty.name IN (N'nvarchar', N'nchar')
                                         THEN ty.name + N'(' + CASE WHEN c.max_length = -1 THEN N'max'
                                                                    ELSE CONVERT(nvarchar(10), c.max_length / 2) END + N')'
                                    WHEN ty.name IN (N'decimal', N'numeric')
                                         THEN ty.name + N'(' + CONVERT(nvarchar(10), c.precision) + N',' +
                                              CONVERT(nvarchar(10), c.scale) + N')'
                                    WHEN ty.name IN (N'datetime2', N'datetimeoffset', N'time')
                                         THEN ty.name + N'(' + CONVERT(nvarchar(10), c.scale) + N')'
                                    ELSE ty.name
                                END +
                                CASE WHEN c.collation_name IS NOT NULL AND ty.is_user_defined = 0
                                          AND c.collation_name <> @dbCollation
                                     THEN N' COLLATE ' + c.collation_name ELSE N'' END +
                                CASE WHEN c.is_identity = 1 THEN N' IDENTITY(1,1)' ELSE N'' END +
                                CASE WHEN c.is_nullable = 1 THEN N' NULL' ELSE N' NOT NULL' END
                        END
                FROM   sys.columns c
                JOIN   sys.types ty  ON ty.user_type_id = c.user_type_id
                JOIN   sys.schemas tys ON tys.schema_id = ty.schema_id
                LEFT   JOIN sys.computed_columns cc ON cc.object_id = c.object_id AND cc.column_id = c.column_id
                WHERE  c.object_id = tt.type_table_object_id
                ORDER  BY c.column_id
                FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 1, N'') +
           ISNULL((
                SELECT  N',' + @crlf + N'    ' +
                        CASE WHEN i.is_primary_key = 1 THEN N'PRIMARY KEY' ELSE N'UNIQUE' END +
                        CASE WHEN i.type = 1 THEN N' CLUSTERED' ELSE N' NONCLUSTERED' END + N' (' +
                        STUFF((
                             SELECT N', ' + QUOTENAME(COL_NAME(ic.object_id, ic.column_id)) +
                                    CASE WHEN ic.is_descending_key = 1 THEN N' DESC' ELSE N' ASC' END
                             FROM   sys.index_columns ic
                             WHERE  ic.object_id = i.object_id AND ic.index_id = i.index_id
                               AND  ic.is_included_column = 0
                             ORDER  BY ic.key_ordinal
                             FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'') + N')'
                FROM   sys.indexes i
                WHERE  i.object_id = tt.type_table_object_id
                  AND  (i.is_primary_key = 1 OR i.is_unique_constraint = 1 OR i.is_unique = 1)
                  AND  i.index_id > 0
                ORDER  BY i.is_primary_key DESC, i.index_id
                FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), N'') +
           @crlf + N');'
    FROM   sys.table_types tt
    JOIN   sys.schemas s ON s.schema_id = tt.schema_id
    WHERE  tt.is_user_defined = 1
      AND  (@SchemaFilter IS NULL OR s.name IN (SELECT name FROM #schema_filter))
      AND  (@NameFilter IS NULL OR tt.name LIKE @NameFilter)
      AND  (@ExcludeNameLike IS NULL OR NOT EXISTS
                (SELECT 1 FROM #exclude_pattern x WHERE tt.name LIKE x.pattern))
      AND  (@CustomObjectsOnly = 0 OR tt.name LIKE N'uf[_]%'
                                   OR tt.name LIKE N'Uf[_]%'
                                   OR tt.name LIKE N'MMC[_]%');

--------------------------------------------------------------------------------
-- 3. Sequences (SQL Server 2012+; queried dynamically so the batch still
--    compiles on older versions)
--------------------------------------------------------------------------------
IF @IncludeSequences = 1 AND @FirstPart = 1 AND @majorVersion >= 11
BEGIN
    DECLARE @seqSql nvarchar(max) = N'
    INSERT #script (sort_order, object_type, schema_name, object_name, script_text)
    SELECT 300, ''SEQUENCE'', s.name, sq.name,
           N''CREATE SEQUENCE '' + QUOTENAME(s.name) + N''.'' + QUOTENAME(sq.name) +
           N'' AS '' + CASE WHEN t.is_user_defined = 1
                            THEN QUOTENAME(ts.name) + N''.'' + QUOTENAME(t.name)
                            ELSE QUOTENAME(t.name) END +
           N'' START WITH ''   + CONVERT(nvarchar(40), COALESCE(sq.current_value, sq.start_value)) +
           N'' INCREMENT BY '' + CONVERT(nvarchar(40), sq.increment) +
           N'' MINVALUE ''     + CONVERT(nvarchar(40), sq.minimum_value) +
           N'' MAXVALUE ''     + CONVERT(nvarchar(40), sq.maximum_value) +
           CASE WHEN sq.is_cycling = 1 THEN N'' CYCLE'' ELSE N'' NO CYCLE'' END +
           CASE WHEN sq.is_cached = 0 THEN N'' NO CACHE''
                WHEN sq.cache_size IS NULL THEN N'' CACHE''
                ELSE N'' CACHE '' + CONVERT(nvarchar(20), sq.cache_size) END + N'';''
    FROM   sys.sequences sq
    JOIN   sys.schemas s ON s.schema_id = sq.schema_id
    JOIN   sys.types   t ON t.user_type_id = sq.user_type_id
    JOIN   sys.schemas ts ON ts.schema_id = t.schema_id
    WHERE  (@SchemaFilter IS NULL OR s.name IN (SELECT name FROM #schema_filter))
      AND  (@NameFilter IS NULL OR sq.name LIKE @NameFilter);';

    EXEC sp_executesql @seqSql,
         N'@SchemaFilter nvarchar(4000), @NameFilter nvarchar(4000)',
         @SchemaFilter = @SchemaFilter, @NameFilter = @NameFilter;
END

--------------------------------------------------------------------------------
-- 4. Tables
--------------------------------------------------------------------------------
IF @IncludeTables = 1
    INSERT #script (sort_order, object_type, schema_name, object_name, script_text)
    SELECT 400, 'TABLE', s.name, t.name,
           N'CREATE TABLE ' + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name) + @crlf + N'(' +
           STUFF((
                SELECT  N',' + @crlf + N'    ' + QUOTENAME(c.name) + N' ' +
                        CASE
                            -- computed column: no data type, just the expression
                            WHEN cc.definition IS NOT NULL
                                 THEN N'AS ' + cc.definition +
                                      CASE WHEN cc.is_persisted = 1 THEN N' PERSISTED' ELSE N'' END +
                                      CASE WHEN cc.is_persisted = 1 AND c.is_nullable = 0 THEN N' NOT NULL' ELSE N'' END
                            ELSE
                                CASE
                                    WHEN ty.is_user_defined = 1 THEN QUOTENAME(tys.name) + N'.' + QUOTENAME(ty.name)
                                    WHEN ty.name IN (N'varchar', N'char', N'varbinary', N'binary')
                                         THEN ty.name + N'(' + CASE WHEN c.max_length = -1 THEN N'max'
                                                                    ELSE CONVERT(nvarchar(10), c.max_length) END + N')'
                                    WHEN ty.name IN (N'nvarchar', N'nchar')
                                         THEN ty.name + N'(' + CASE WHEN c.max_length = -1 THEN N'max'
                                                                    ELSE CONVERT(nvarchar(10), c.max_length / 2) END + N')'
                                    WHEN ty.name IN (N'decimal', N'numeric')
                                         THEN ty.name + N'(' + CONVERT(nvarchar(10), c.precision) + N',' +
                                              CONVERT(nvarchar(10), c.scale) + N')'
                                    WHEN ty.name IN (N'datetime2', N'datetimeoffset', N'time')
                                         THEN ty.name + N'(' + CONVERT(nvarchar(10), c.scale) + N')'
                                    WHEN ty.name = N'float'
                                         THEN ty.name + N'(' + CONVERT(nvarchar(10), c.precision) + N')'
                                    ELSE ty.name
                                END +
                                CASE WHEN c.collation_name IS NOT NULL AND ty.is_user_defined = 0
                                          AND c.collation_name <> @dbCollation
                                     THEN N' COLLATE ' + c.collation_name ELSE N'' END +
                                CASE WHEN ic.object_id IS NOT NULL
                                     THEN N' IDENTITY(' + CONVERT(nvarchar(40), ic.seed_value) + N',' +
                                          CONVERT(nvarchar(40), ic.increment_value) + N')'
                                     ELSE N'' END +
                                CASE WHEN c.is_rowguidcol = 1 THEN N' ROWGUIDCOL' ELSE N'' END +
                                CASE WHEN c.is_sparse = 1 THEN N' SPARSE' ELSE N'' END +
                                CASE WHEN c.is_nullable = 1 THEN N' NULL' ELSE N' NOT NULL' END
                        END
                FROM   sys.columns c
                JOIN   sys.types ty    ON ty.user_type_id = c.user_type_id
                JOIN   sys.schemas tys ON tys.schema_id = ty.schema_id
                LEFT   JOIN sys.computed_columns  cc ON cc.object_id = c.object_id AND cc.column_id = c.column_id
                LEFT   JOIN sys.identity_columns  ic ON ic.object_id = c.object_id AND ic.column_id = c.column_id
                WHERE  c.object_id = t.object_id
                ORDER  BY c.column_id
                FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 1, N'') +
           @crlf + N');'
    FROM   sys.tables t
    JOIN   sys.schemas s ON s.schema_id = t.schema_id
    WHERE  t.is_ms_shipped = 0
      AND  t.name <> N'sysdiagrams'
      AND  (@SchemaFilter IS NULL OR s.name IN (SELECT name FROM #schema_filter))
      AND  (@NameFilter IS NULL OR t.name LIKE @NameFilter)
      AND  (@ExcludeNameLike IS NULL OR NOT EXISTS
                (SELECT 1 FROM #exclude_pattern x WHERE t.name LIKE x.pattern))
      AND  (@CustomObjectsOnly = 0 OR t.name LIKE N'uf[_]%'
                                   OR t.name LIKE N'Uf[_]%'
                                   OR t.name LIKE N'MMC[_]%')
      AND  (@PartCount = 1 OR ABS(CHECKSUM(t.name)) % @PartCount = @PartNumber - 1);

--------------------------------------------------------------------------------
-- 5. Primary key and unique constraints
--------------------------------------------------------------------------------
IF @IncludeKeyConstraints = 1
    INSERT #script (sort_order, object_type, schema_name, object_name, script_text)
    SELECT 500, 'KEY', s.name, t.name,
           N'ALTER TABLE ' + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name) +
           N' ADD CONSTRAINT ' + QUOTENAME(kc.name) + @crlf + N'    ' +
           CASE WHEN kc.type = 'PK' THEN N'PRIMARY KEY' ELSE N'UNIQUE' END +
           CASE WHEN i.type = 1 THEN N' CLUSTERED' ELSE N' NONCLUSTERED' END + N' (' +
           STUFF((
                SELECT N', ' + QUOTENAME(COL_NAME(ixc.object_id, ixc.column_id)) +
                       CASE WHEN ixc.is_descending_key = 1 THEN N' DESC' ELSE N' ASC' END
                FROM   sys.index_columns ixc
                WHERE  ixc.object_id = i.object_id AND ixc.index_id = i.index_id
                  AND  ixc.is_included_column = 0
                ORDER  BY ixc.key_ordinal
                FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'') + N')' +
           CASE WHEN i.fill_factor > 0
                THEN N' WITH (FILLFACTOR = ' + CONVERT(nvarchar(10), i.fill_factor) + N')'
                ELSE N'' END + N';'
    FROM   sys.key_constraints kc
    JOIN   sys.tables  t ON t.object_id = kc.parent_object_id
    JOIN   sys.schemas s ON s.schema_id = t.schema_id
    JOIN   sys.indexes i ON i.object_id = kc.parent_object_id AND i.index_id = kc.unique_index_id
    WHERE  t.is_ms_shipped = 0
      AND  t.name <> N'sysdiagrams'
      AND  (@SchemaFilter IS NULL OR s.name IN (SELECT name FROM #schema_filter))
      AND  (@NameFilter IS NULL OR t.name LIKE @NameFilter)
      AND  (@ExcludeNameLike IS NULL OR NOT EXISTS
                (SELECT 1 FROM #exclude_pattern x WHERE t.name LIKE x.pattern))
      AND  (@CustomObjectsOnly = 0 OR t.name LIKE N'uf[_]%'
                                   OR t.name LIKE N'Uf[_]%'
                                   OR t.name LIKE N'MMC[_]%')
      AND  (@PartCount = 1 OR ABS(CHECKSUM(t.name)) % @PartCount = @PartNumber - 1);

--------------------------------------------------------------------------------
-- 6. Default constraints
--------------------------------------------------------------------------------
IF @IncludeDefaults = 1
    INSERT #script (sort_order, object_type, schema_name, object_name, script_text)
    SELECT 600, 'DEFAULT', s.name, t.name,
           N'ALTER TABLE ' + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name) +
           N' ADD CONSTRAINT ' + QUOTENAME(dc.name) +
           N' DEFAULT ' + dc.definition + N' FOR ' + QUOTENAME(c.name) + N';'
    FROM   sys.default_constraints dc
    JOIN   sys.tables  t ON t.object_id = dc.parent_object_id
    JOIN   sys.schemas s ON s.schema_id = t.schema_id
    JOIN   sys.columns c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id
    WHERE  t.is_ms_shipped = 0
      AND  t.name <> N'sysdiagrams'
      AND  (@SchemaFilter IS NULL OR s.name IN (SELECT name FROM #schema_filter))
      AND  (@NameFilter IS NULL OR t.name LIKE @NameFilter)
      AND  (@ExcludeNameLike IS NULL OR NOT EXISTS
                (SELECT 1 FROM #exclude_pattern x WHERE t.name LIKE x.pattern))
      AND  (@CustomObjectsOnly = 0 OR t.name LIKE N'uf[_]%'
                                   OR t.name LIKE N'Uf[_]%'
                                   OR t.name LIKE N'MMC[_]%')
      AND  (@PartCount = 1 OR ABS(CHECKSUM(t.name)) % @PartCount = @PartNumber - 1);

--------------------------------------------------------------------------------
-- 7. Check constraints
--------------------------------------------------------------------------------
IF @IncludeCheckConstraints = 1
    INSERT #script (sort_order, object_type, schema_name, object_name, script_text)
    SELECT 700, 'CHECK', s.name, t.name,
           N'ALTER TABLE ' + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name) +
           CASE WHEN cc.is_not_trusted = 1 THEN N' WITH NOCHECK' ELSE N' WITH CHECK' END +
           N' ADD CONSTRAINT ' + QUOTENAME(cc.name) + N' CHECK ' +
           CASE WHEN cc.is_not_for_replication = 1 THEN N'NOT FOR REPLICATION ' ELSE N'' END +
           cc.definition + N';' +
           CASE WHEN cc.is_disabled = 1
                THEN @crlf + N'ALTER TABLE ' + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name) +
                     N' NOCHECK CONSTRAINT ' + QUOTENAME(cc.name) + N';'
                ELSE N'' END
    FROM   sys.check_constraints cc
    JOIN   sys.tables  t ON t.object_id = cc.parent_object_id
    JOIN   sys.schemas s ON s.schema_id = t.schema_id
    WHERE  t.is_ms_shipped = 0
      AND  cc.is_ms_shipped = 0
      AND  (@SchemaFilter IS NULL OR s.name IN (SELECT name FROM #schema_filter))
      AND  (@NameFilter IS NULL OR t.name LIKE @NameFilter)
      AND  (@ExcludeNameLike IS NULL OR NOT EXISTS
                (SELECT 1 FROM #exclude_pattern x WHERE t.name LIKE x.pattern))
      AND  (@CustomObjectsOnly = 0 OR t.name LIKE N'uf[_]%'
                                   OR t.name LIKE N'Uf[_]%'
                                   OR t.name LIKE N'MMC[_]%')
      AND  (@PartCount = 1 OR ABS(CHECKSUM(t.name)) % @PartCount = @PartNumber - 1);

--------------------------------------------------------------------------------
-- 8a. Rowstore indexes (clustered / nonclustered, not backing a constraint)
--------------------------------------------------------------------------------
IF @IncludeIndexes = 1
    INSERT #script (sort_order, object_type, schema_name, object_name, script_text)
    SELECT 800, 'INDEX', s.name, t.name,
           N'CREATE ' + CASE WHEN i.is_unique = 1 THEN N'UNIQUE ' ELSE N'' END +
           CASE WHEN i.type = 1 THEN N'CLUSTERED' ELSE N'NONCLUSTERED' END +
           N' INDEX ' + QUOTENAME(i.name) + N' ON ' + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name) + @crlf + N'    (' +
           STUFF((
                SELECT N', ' + QUOTENAME(COL_NAME(ixc.object_id, ixc.column_id)) +
                       CASE WHEN ixc.is_descending_key = 1 THEN N' DESC' ELSE N' ASC' END
                FROM   sys.index_columns ixc
                WHERE  ixc.object_id = i.object_id AND ixc.index_id = i.index_id
                  AND  ixc.is_included_column = 0
                ORDER  BY ixc.key_ordinal
                FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'') + N')' +
           ISNULL(@crlf + N'    INCLUDE (' + STUFF((
                SELECT N', ' + QUOTENAME(COL_NAME(ixc.object_id, ixc.column_id))
                FROM   sys.index_columns ixc
                WHERE  ixc.object_id = i.object_id AND ixc.index_id = i.index_id
                  AND  ixc.is_included_column = 1
                ORDER  BY ixc.index_column_id
                FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'') + N')', N'') +
           ISNULL(@crlf + N'    WHERE ' + i.filter_definition, N'') +
           CASE
               WHEN i.fill_factor > 0 OR i.is_padded = 1 OR i.ignore_dup_key = 1
                    OR i.allow_row_locks = 0 OR i.allow_page_locks = 0
               THEN @crlf + N'    WITH (' +
                    STUFF(
                        CASE WHEN i.is_padded = 1        THEN N', PAD_INDEX = ON' ELSE N'' END +
                        CASE WHEN i.fill_factor > 0      THEN N', FILLFACTOR = ' + CONVERT(nvarchar(10), i.fill_factor) ELSE N'' END +
                        CASE WHEN i.ignore_dup_key = 1   THEN N', IGNORE_DUP_KEY = ON' ELSE N'' END +
                        CASE WHEN i.allow_row_locks = 0  THEN N', ALLOW_ROW_LOCKS = OFF' ELSE N'' END +
                        CASE WHEN i.allow_page_locks = 0 THEN N', ALLOW_PAGE_LOCKS = OFF' ELSE N'' END,
                        1, 2, N'') + N')'
               ELSE N''
           END + N';'
    FROM   sys.indexes i
    JOIN   sys.tables  t ON t.object_id = i.object_id
    JOIN   sys.schemas s ON s.schema_id = t.schema_id
    WHERE  t.is_ms_shipped = 0
      AND  t.name <> N'sysdiagrams'
      AND  i.index_id > 0
      AND  i.type IN (1, 2)                    -- clustered / nonclustered rowstore
      AND  i.is_primary_key = 0
      AND  i.is_unique_constraint = 0
      AND  i.is_hypothetical = 0
      AND  i.name IS NOT NULL
      AND  (@SchemaFilter IS NULL OR s.name IN (SELECT name FROM #schema_filter))
      AND  (@NameFilter IS NULL OR t.name LIKE @NameFilter)
      AND  (@ExcludeNameLike IS NULL OR NOT EXISTS
                (SELECT 1 FROM #exclude_pattern x WHERE t.name LIKE x.pattern))
      AND  (@CustomObjectsOnly = 0 OR t.name LIKE N'uf[_]%'
                                   OR t.name LIKE N'Uf[_]%'
                                   OR t.name LIKE N'MMC[_]%')
      AND  (@PartCount = 1 OR ABS(CHECKSUM(t.name)) % @PartCount = @PartNumber - 1);

--------------------------------------------------------------------------------
-- 8b. Columnstore indexes
--------------------------------------------------------------------------------
IF @IncludeIndexes = 1
    INSERT #script (sort_order, object_type, schema_name, object_name, script_text)
    SELECT 810, 'INDEX', s.name, t.name,
           N'CREATE ' + CASE WHEN i.type = 5 THEN N'CLUSTERED' ELSE N'NONCLUSTERED' END +
           N' COLUMNSTORE INDEX ' + QUOTENAME(i.name) +
           N' ON ' + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name) +
           CASE WHEN i.type = 6
                THEN @crlf + N'    (' + STUFF((
                        SELECT N', ' + QUOTENAME(COL_NAME(ixc.object_id, ixc.column_id))
                        FROM   sys.index_columns ixc
                        WHERE  ixc.object_id = i.object_id AND ixc.index_id = i.index_id
                        ORDER  BY ixc.index_column_id
                        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'') + N')'
                ELSE N'' END +
           ISNULL(@crlf + N'    WHERE ' + i.filter_definition, N'') + N';'
    FROM   sys.indexes i
    JOIN   sys.tables  t ON t.object_id = i.object_id
    JOIN   sys.schemas s ON s.schema_id = t.schema_id
    WHERE  t.is_ms_shipped = 0
      AND  i.type IN (5, 6)
      AND  i.name IS NOT NULL
      AND  (@SchemaFilter IS NULL OR s.name IN (SELECT name FROM #schema_filter))
      AND  (@NameFilter IS NULL OR t.name LIKE @NameFilter)
      AND  (@ExcludeNameLike IS NULL OR NOT EXISTS
                (SELECT 1 FROM #exclude_pattern x WHERE t.name LIKE x.pattern))
      AND  (@CustomObjectsOnly = 0 OR t.name LIKE N'uf[_]%'
                                   OR t.name LIKE N'Uf[_]%'
                                   OR t.name LIKE N'MMC[_]%')
      AND  (@PartCount = 1 OR ABS(CHECKSUM(t.name)) % @PartCount = @PartNumber - 1);

--------------------------------------------------------------------------------
-- 9. Views and functions
--    These two are emitted together, in one dependency order, on purpose.
--    CREATE VIEW and CREATE FUNCTION bind at creation time -- unlike procedures
--    and triggers they get no deferred name resolution -- so a view built on
--    another view, a view calling a scalar function, or a function selecting
--    from a view all have to be created in the right order or the replay
--    fails. They are also never split by @PartCount for the same reason.
--------------------------------------------------------------------------------
CREATE TABLE #module_level (object_id int NOT NULL PRIMARY KEY, depth int NOT NULL);

IF (@IncludeViews = 1 OR @IncludeFunctions = 1) AND @FirstPart = 1
BEGIN
    IF @IncludeViews = 1
        INSERT #module_level (object_id, depth)
        SELECT v.object_id, 0
        FROM   sys.views v
        JOIN   sys.schemas s ON s.schema_id = v.schema_id
        WHERE  v.is_ms_shipped = 0
          AND  (@SchemaFilter IS NULL OR s.name IN (SELECT name FROM #schema_filter))
          AND  (@NameFilter IS NULL OR v.name LIKE @NameFilter)
          AND  (@ExcludeNameLike IS NULL OR NOT EXISTS
                    (SELECT 1 FROM #exclude_pattern x WHERE v.name LIKE x.pattern))
          AND  (@CustomObjectsOnly = 0 OR v.name LIKE N'uf[_]%'
                                       OR v.name LIKE N'Uf[_]%'
                                       OR v.name LIKE N'MMC[_]%');

    IF @IncludeFunctions = 1
        INSERT #module_level (object_id, depth)
        SELECT o.object_id, 0
        FROM   sys.objects o
        JOIN   sys.schemas s ON s.schema_id = o.schema_id
        WHERE  o.type IN ('FN', 'IF', 'TF')
          AND  o.is_ms_shipped = 0
          AND  (@SchemaFilter IS NULL OR s.name IN (SELECT name FROM #schema_filter))
          AND  (@NameFilter IS NULL OR o.name LIKE @NameFilter)
          AND  (@ExcludeNameLike IS NULL OR NOT EXISTS
                    (SELECT 1 FROM #exclude_pattern x WHERE o.name LIKE x.pattern))
          AND  (@CustomObjectsOnly = 0 OR o.name LIKE N'uf[_]%'
                                       OR o.name LIKE N'Uf[_]%'
                                       OR o.name LIKE N'MMC[_]%');

    IF @OrderByDependency = 1
    BEGIN
        CREATE TABLE #module_dep (referencing_id int NOT NULL, referenced_id int NOT NULL,
                                  PRIMARY KEY (referencing_id, referenced_id));

        INSERT #module_dep (referencing_id, referenced_id)
        SELECT DISTINCT d.referencing_id, d.referenced_id
        FROM   sys.sql_expression_dependencies d
        JOIN   #module_level a ON a.object_id = d.referencing_id
        JOIN   #module_level b ON b.object_id = d.referenced_id
        WHERE  d.referenced_id <> d.referencing_id;

        -- Push each module above everything it reads. Bounded, so a
        -- pathological graph cannot spin forever.
        DECLARE @pass int = 0;
        DECLARE @moved int = 1;

        WHILE @pass < 32 AND @moved > 0
        BEGIN
            UPDATE l
            SET    l.depth = x.max_depth + 1
            FROM   #module_level l
            JOIN   (SELECT md.referencing_id, MAX(p.depth) AS max_depth
                    FROM   #module_dep md
                    JOIN   #module_level p ON p.object_id = md.referenced_id
                    GROUP  BY md.referencing_id) x ON x.referencing_id = l.object_id
            WHERE  l.depth <= x.max_depth;

            SET @moved = @@ROWCOUNT;
            SET @pass  = @pass + 1;
        END

        IF @moved > 0
            RAISERROR('Module dependency sort hit its 32-pass ceiling; check the emitted order by hand.', 10, 1) WITH NOWAIT;
    END

    -- Views
    INSERT #script (sort_order, sub_order, object_type, schema_name, object_name, script_text)
    SELECT 900, ml.depth, 'VIEW', s.name, v.name,
           CASE WHEN @DropIfExists = 1
                THEN N'IF OBJECT_ID(N''' + REPLACE(QUOTENAME(s.name) + N'.' + QUOTENAME(v.name), N'''', N'''''') +
                     N''', ''V'') IS NOT NULL DROP VIEW ' + QUOTENAME(s.name) + N'.' + QUOTENAME(v.name) + N';' +
                     @crlf + N'GO' + @crlf
                ELSE N'' END +
           ISNULL(sm.definition,
                  N'/* ' + QUOTENAME(s.name) + N'.' + QUOTENAME(v.name) +
                  N' is encrypted (WITH ENCRYPTION); its definition cannot be scripted. */')
    FROM   sys.views v
    JOIN   sys.schemas s    ON s.schema_id = v.schema_id
    JOIN   #module_level ml ON ml.object_id = v.object_id
    LEFT   JOIN sys.sql_modules sm ON sm.object_id = v.object_id;

    -- Functions (scalar, inline TVF, multi-statement TVF)
    INSERT #script (sort_order, sub_order, object_type, schema_name, object_name, script_text)
    SELECT 900, ml.depth, 'FUNCTION', s.name, o.name,
           CASE WHEN @DropIfExists = 1
                THEN N'IF OBJECT_ID(N''' + REPLACE(QUOTENAME(s.name) + N'.' + QUOTENAME(o.name), N'''', N'''''') +
                     N''') IS NOT NULL DROP FUNCTION ' + QUOTENAME(s.name) + N'.' + QUOTENAME(o.name) + N';' +
                     @crlf + N'GO' + @crlf
                ELSE N'' END +
           ISNULL(sm.definition,
                  N'/* ' + QUOTENAME(s.name) + N'.' + QUOTENAME(o.name) +
                  N' is encrypted (WITH ENCRYPTION); its definition cannot be scripted. */')
    FROM   sys.objects o
    JOIN   sys.schemas s    ON s.schema_id = o.schema_id
    JOIN   #module_level ml ON ml.object_id = o.object_id
    LEFT   JOIN sys.sql_modules sm ON sm.object_id = o.object_id
    WHERE  o.type IN ('FN', 'IF', 'TF');
END

--------------------------------------------------------------------------------
-- 10. Stored procedures
--------------------------------------------------------------------------------
IF @IncludeProcedures = 1
    INSERT #script (sort_order, object_type, schema_name, object_name, script_text)
    SELECT 1100, 'PROCEDURE', s.name, p.name,
           CASE WHEN @DropIfExists = 1
                THEN N'IF OBJECT_ID(N''' + REPLACE(QUOTENAME(s.name) + N'.' + QUOTENAME(p.name), N'''', N'''''') +
                     N''', ''P'') IS NOT NULL DROP PROCEDURE ' + QUOTENAME(s.name) + N'.' + QUOTENAME(p.name) + N';' +
                     @crlf + N'GO' + @crlf
                ELSE N'' END +
           ISNULL(sm.definition,
                  N'/* ' + QUOTENAME(s.name) + N'.' + QUOTENAME(p.name) +
                  N' is encrypted (WITH ENCRYPTION); its definition cannot be scripted. */')
    FROM   sys.procedures p
    JOIN   sys.schemas s ON s.schema_id = p.schema_id
    LEFT   JOIN sys.sql_modules sm ON sm.object_id = p.object_id
    WHERE  p.is_ms_shipped = 0
      AND  p.type = 'P'
      AND  (@SchemaFilter IS NULL OR s.name IN (SELECT name FROM #schema_filter))
      AND  (@NameFilter IS NULL OR p.name LIKE @NameFilter)
      AND  (@ExcludeNameLike IS NULL OR NOT EXISTS
                (SELECT 1 FROM #exclude_pattern x WHERE p.name LIKE x.pattern))
      AND  (@CustomObjectsOnly = 0 OR p.name LIKE N'uf[_]%'
                                   OR p.name LIKE N'Uf[_]%'
                                   OR p.name LIKE N'MMC[_]%')
      AND  (@PartCount = 1 OR ABS(CHECKSUM(p.name)) % @PartCount = @PartNumber - 1);

--------------------------------------------------------------------------------
-- 11a. DML triggers
--------------------------------------------------------------------------------
IF @IncludeTriggers = 1
    INSERT #script (sort_order, object_type, schema_name, object_name, script_text)
    SELECT 1200, 'TRIGGER', s.name, tr.name,
           CASE WHEN @DropIfExists = 1
                THEN N'IF OBJECT_ID(N''' + REPLACE(QUOTENAME(s.name) + N'.' + QUOTENAME(tr.name), N'''', N'''''') +
                     N''', ''TR'') IS NOT NULL DROP TRIGGER ' + QUOTENAME(s.name) + N'.' + QUOTENAME(tr.name) + N';' +
                     @crlf + N'GO' + @crlf
                ELSE N'' END +
           ISNULL(sm.definition,
                  N'/* ' + QUOTENAME(s.name) + N'.' + QUOTENAME(tr.name) +
                  N' is encrypted (WITH ENCRYPTION); its definition cannot be scripted. */') +
           CASE WHEN tr.is_disabled = 1
                THEN @crlf + N'GO' + @crlf + N'DISABLE TRIGGER ' + QUOTENAME(s.name) + N'.' + QUOTENAME(tr.name) +
                     N' ON ' + QUOTENAME(s.name) + N'.' + QUOTENAME(pt.name) + N';'
                ELSE N'' END
    FROM   sys.triggers tr
    JOIN   sys.objects pt ON pt.object_id = tr.parent_id
    JOIN   sys.schemas s  ON s.schema_id = pt.schema_id
    LEFT   JOIN sys.sql_modules sm ON sm.object_id = tr.object_id
    WHERE  tr.is_ms_shipped = 0
      AND  tr.parent_class = 1
      AND  (@SchemaFilter IS NULL OR s.name IN (SELECT name FROM #schema_filter))
      AND  (@NameFilter IS NULL OR pt.name LIKE @NameFilter)
      AND  (@ExcludeNameLike IS NULL OR NOT EXISTS
                (SELECT 1 FROM #exclude_pattern x WHERE pt.name LIKE x.pattern))
      AND  (@CustomObjectsOnly = 0 OR pt.name LIKE N'uf[_]%'
                                   OR pt.name LIKE N'Uf[_]%'
                                   OR pt.name LIKE N'MMC[_]%')
      AND  (@PartCount = 1 OR ABS(CHECKSUM(pt.name)) % @PartCount = @PartNumber - 1);

--------------------------------------------------------------------------------
-- 11b. Database-level DDL triggers (only when not filtering by schema/name)
--------------------------------------------------------------------------------
IF @IncludeTriggers = 1 AND @FirstPart = 1 AND @SchemaFilter IS NULL AND @NameFilter IS NULL
    INSERT #script (sort_order, object_type, schema_name, object_name, script_text)
    SELECT 1210, 'DDL TRIGGER', NULL, tr.name,
           CASE WHEN @DropIfExists = 1
                THEN N'IF EXISTS (SELECT 1 FROM sys.triggers WHERE parent_class = 0 AND name = ' +
                     QUOTENAME(tr.name, '''') + N') DROP TRIGGER ' + QUOTENAME(tr.name) + N' ON DATABASE;' +
                     @crlf + N'GO' + @crlf
                ELSE N'' END +
           ISNULL(sm.definition,
                  N'/* ' + QUOTENAME(tr.name) + N' is encrypted; its definition cannot be scripted. */') +
           CASE WHEN tr.is_disabled = 1
                THEN @crlf + N'GO' + @crlf + N'DISABLE TRIGGER ' + QUOTENAME(tr.name) + N' ON DATABASE;'
                ELSE N'' END
    FROM   sys.triggers tr
    LEFT   JOIN sys.sql_modules sm ON sm.object_id = tr.object_id
    WHERE  tr.parent_class = 0
      AND  tr.is_ms_shipped = 0;

--------------------------------------------------------------------------------
-- 12. Foreign keys (last, so every referenced table exists by now)
--------------------------------------------------------------------------------
IF @IncludeForeignKeys = 1
    INSERT #script (sort_order, object_type, schema_name, object_name, script_text)
    SELECT 1300, 'FOREIGN KEY', ps.name, pt.name,
           N'ALTER TABLE ' + QUOTENAME(ps.name) + N'.' + QUOTENAME(pt.name) +
           CASE WHEN fk.is_not_trusted = 1 THEN N' WITH NOCHECK' ELSE N' WITH CHECK' END +
           N' ADD CONSTRAINT ' + QUOTENAME(fk.name) + @crlf + N'    FOREIGN KEY (' +
           STUFF((
                SELECT N', ' + QUOTENAME(COL_NAME(fkc.parent_object_id, fkc.parent_column_id))
                FROM   sys.foreign_key_columns fkc
                WHERE  fkc.constraint_object_id = fk.object_id
                ORDER  BY fkc.constraint_column_id
                FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'') + N')' + @crlf +
           N'    REFERENCES ' + QUOTENAME(rs.name) + N'.' + QUOTENAME(rt.name) + N' (' +
           STUFF((
                SELECT N', ' + QUOTENAME(COL_NAME(fkc.referenced_object_id, fkc.referenced_column_id))
                FROM   sys.foreign_key_columns fkc
                WHERE  fkc.constraint_object_id = fk.object_id
                ORDER  BY fkc.constraint_column_id
                FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'') + N')' +
           CASE WHEN fk.delete_referential_action > 0
                THEN N' ON DELETE ' + REPLACE(fk.delete_referential_action_desc, N'_', N' ') ELSE N'' END +
           CASE WHEN fk.update_referential_action > 0
                THEN N' ON UPDATE ' + REPLACE(fk.update_referential_action_desc, N'_', N' ') ELSE N'' END +
           CASE WHEN fk.is_not_for_replication = 1 THEN N' NOT FOR REPLICATION' ELSE N'' END + N';' +
           CASE WHEN fk.is_disabled = 1
                THEN @crlf + N'ALTER TABLE ' + QUOTENAME(ps.name) + N'.' + QUOTENAME(pt.name) +
                     N' NOCHECK CONSTRAINT ' + QUOTENAME(fk.name) + N';'
                ELSE N'' END
    FROM   sys.foreign_keys fk
    JOIN   sys.tables  pt ON pt.object_id = fk.parent_object_id
    JOIN   sys.schemas ps ON ps.schema_id = pt.schema_id
    JOIN   sys.tables  rt ON rt.object_id = fk.referenced_object_id
    JOIN   sys.schemas rs ON rs.schema_id = rt.schema_id
    WHERE  fk.is_ms_shipped = 0
      AND  (@SchemaFilter IS NULL OR ps.name IN (SELECT name FROM #schema_filter))
      AND  (@NameFilter IS NULL OR pt.name LIKE @NameFilter)
      AND  (@ExcludeNameLike IS NULL OR NOT EXISTS
                (SELECT 1 FROM #exclude_pattern x WHERE pt.name LIKE x.pattern))
      AND  (@CustomObjectsOnly = 0 OR pt.name LIKE N'uf[_]%'
                                   OR pt.name LIKE N'Uf[_]%'
                                   OR pt.name LIKE N'MMC[_]%')
      AND  (@PartCount = 1 OR ABS(CHECKSUM(pt.name)) % @PartCount = @PartNumber - 1);

--------------------------------------------------------------------------------
-- 13. Synonyms
--------------------------------------------------------------------------------
IF @IncludeSynonyms = 1 AND @FirstPart = 1
    INSERT #script (sort_order, object_type, schema_name, object_name, script_text)
    SELECT 1400, 'SYNONYM', s.name, sy.name,
           CASE WHEN @DropIfExists = 1
                THEN N'IF OBJECT_ID(N''' + REPLACE(QUOTENAME(s.name) + N'.' + QUOTENAME(sy.name), N'''', N'''''') +
                     N''', ''SN'') IS NOT NULL DROP SYNONYM ' + QUOTENAME(s.name) + N'.' + QUOTENAME(sy.name) + N';' + @crlf
                ELSE N'' END +
           N'CREATE SYNONYM ' + QUOTENAME(s.name) + N'.' + QUOTENAME(sy.name) +
           N' FOR ' + sy.base_object_name + N';'
    FROM   sys.synonyms sy
    JOIN   sys.schemas s ON s.schema_id = sy.schema_id
    WHERE  sy.is_ms_shipped = 0
      AND  (@SchemaFilter IS NULL OR s.name IN (SELECT name FROM #schema_filter))
      AND  (@NameFilter IS NULL OR sy.name LIKE @NameFilter)
      AND  (@ExcludeNameLike IS NULL OR NOT EXISTS
                (SELECT 1 FROM #exclude_pattern x WHERE sy.name LIKE x.pattern))
      AND  (@CustomObjectsOnly = 0 OR sy.name LIKE N'uf[_]%'
                                   OR sy.name LIKE N'Uf[_]%'
                                   OR sy.name LIKE N'MMC[_]%');

--------------------------------------------------------------------------------
-- 14. Extended properties (MS_Description and friends)
--------------------------------------------------------------------------------
IF @IncludeExtendedProperties = 1 AND @FirstPart = 1
BEGIN
    -- on schemas
    INSERT #script (sort_order, object_type, schema_name, object_name, script_text)
    SELECT 1500, 'EXT PROPERTY', s.name, s.name,
           N'EXEC sys.sp_addextendedproperty @name = ' + QUOTENAME(ep.name, '''') +
           N', @value = N''' + REPLACE(CONVERT(nvarchar(max), ep.value), N'''', N'''''') + N'''' +
           N', @level0type = ''SCHEMA'', @level0name = ' + QUOTENAME(s.name, '''') + N';'
    FROM   sys.extended_properties ep
    JOIN   sys.schemas s ON s.schema_id = ep.major_id
    WHERE  ep.class = 3
      AND  (@SchemaFilter IS NULL OR s.name IN (SELECT name FROM #schema_filter));

    -- on objects and their columns
    INSERT #script (sort_order, object_type, schema_name, object_name, script_text)
    SELECT 1510, 'EXT PROPERTY', s.name, o.name,
           N'EXEC sys.sp_addextendedproperty @name = ' + QUOTENAME(ep.name, '''') +
           N', @value = N''' + REPLACE(CONVERT(nvarchar(max), ep.value), N'''', N'''''') + N'''' +
           N', @level0type = ''SCHEMA'', @level0name = ' + QUOTENAME(s.name, '''') +
           N', @level1type = ''' +
           CASE o.type WHEN 'U' THEN N'TABLE'
                       WHEN 'V' THEN N'VIEW'
                       WHEN 'P' THEN N'PROCEDURE'
                       WHEN 'TR' THEN N'TRIGGER'
                       ELSE N'FUNCTION' END +
           N''', @level1name = ' + QUOTENAME(o.name, '''') +
           CASE WHEN ep.minor_id > 0
                THEN N', @level2type = ''COLUMN'', @level2name = ' +
                     QUOTENAME(COL_NAME(ep.major_id, ep.minor_id), '''')
                ELSE N'' END + N';'
    FROM   sys.extended_properties ep
    JOIN   sys.objects o ON o.object_id = ep.major_id
    JOIN   sys.schemas s ON s.schema_id = o.schema_id
    WHERE  ep.class = 1
      AND  o.is_ms_shipped = 0
      AND  o.type IN ('U', 'V', 'P', 'TR', 'FN', 'IF', 'TF')
      AND  (ep.minor_id = 0 OR COL_NAME(ep.major_id, ep.minor_id) IS NOT NULL)
      AND  (@SchemaFilter IS NULL OR s.name IN (SELECT name FROM #schema_filter))
      AND  (@NameFilter IS NULL OR o.name LIKE @NameFilter)
      AND  (@ExcludeNameLike IS NULL OR NOT EXISTS
                (SELECT 1 FROM #exclude_pattern x WHERE o.name LIKE x.pattern))
      AND  (@CustomObjectsOnly = 0 OR o.name LIKE N'uf[_]%'
                                   OR o.name LIKE N'Uf[_]%'
                                   OR o.name LIKE N'MMC[_]%');
END

--------------------------------------------------------------------------------
-- 15. Object-level permissions
--------------------------------------------------------------------------------
IF @IncludePermissions = 1 AND @FirstPart = 1
    INSERT #script (sort_order, object_type, schema_name, object_name, script_text)
    SELECT 1600, 'PERMISSION', s.name, o.name,
           CASE WHEN perm.state = 'W' THEN N'GRANT' ELSE perm.state_desc END +
           N' ' + perm.permission_name +
           CASE WHEN perm.minor_id > 0
                THEN N' (' + QUOTENAME(COL_NAME(perm.major_id, perm.minor_id)) + N')'
                ELSE N'' END +
           N' ON ' + QUOTENAME(s.name) + N'.' + QUOTENAME(o.name) +
           CASE WHEN perm.state = 'R' THEN N' FROM ' ELSE N' TO ' END + QUOTENAME(grantee.name) +
           CASE WHEN perm.state = 'W' THEN N' WITH GRANT OPTION' ELSE N'' END + N';'
    FROM   sys.database_permissions perm
    JOIN   sys.objects o ON o.object_id = perm.major_id
    JOIN   sys.schemas s ON s.schema_id = o.schema_id
    JOIN   sys.database_principals grantee ON grantee.principal_id = perm.grantee_principal_id
    WHERE  perm.class = 1
      AND  o.is_ms_shipped = 0
      AND  grantee.name <> N'dbo'
      AND  (@SchemaFilter IS NULL OR s.name IN (SELECT name FROM #schema_filter))
      AND  (@NameFilter IS NULL OR o.name LIKE @NameFilter)
      AND  (@ExcludeNameLike IS NULL OR NOT EXISTS
                (SELECT 1 FROM #exclude_pattern x WHERE o.name LIKE x.pattern))
      AND  (@CustomObjectsOnly = 0 OR o.name LIKE N'uf[_]%'
                                   OR o.name LIKE N'Uf[_]%'
                                   OR o.name LIKE N'MMC[_]%');

--------------------------------------------------------------------------------
-- Section banners + a script header
--------------------------------------------------------------------------------
DECLARE @sections TABLE (base int PRIMARY KEY, label varchar(50));
INSERT @sections (base, label) VALUES
    ( 100, 'SCHEMAS'),                ( 200, 'USER-DEFINED TYPES'),
    ( 300, 'SEQUENCES'),              ( 400, 'TABLES'),
    ( 500, 'PRIMARY KEY / UNIQUE CONSTRAINTS'),
    ( 600, 'DEFAULT CONSTRAINTS'),    ( 700, 'CHECK CONSTRAINTS'),
    ( 800, 'INDEXES'),                ( 900, 'VIEWS AND FUNCTIONS'),
    (1100, 'STORED PROCEDURES'),
    (1200, 'TRIGGERS'),               (1300, 'FOREIGN KEYS'),
    (1400, 'SYNONYMS'),               (1500, 'EXTENDED PROPERTIES'),
    (1600, 'PERMISSIONS');

DECLARE @stmtCount int = (SELECT COUNT(*) FROM #script);

DECLARE @sectionCounts TABLE (base int PRIMARY KEY, label varchar(50), cnt int);
INSERT @sectionCounts (base, label, cnt)
SELECT sec.base, sec.label,
       (SELECT COUNT(*) FROM #script x WHERE x.sort_order BETWEEN sec.base AND sec.base + 98)
FROM   @sections sec;

INSERT #script (sort_order, sub_order, object_type, script_text)
SELECT sc.base - 1, -1, 'BANNER',
       N'/*' + REPLICATE(N'-', 76) + @crlf +
       N'  ' + sc.label + N'  (' + CONVERT(nvarchar(10), sc.cnt) + N')' + @crlf +
       REPLICATE(N'-', 76) + N'*/'
FROM   @sectionCounts sc
WHERE  sc.cnt > 0;

INSERT #script (sort_order, sub_order, object_type, script_text)
SELECT 0, -1, 'BANNER',
       N'/*' + REPLICATE(N'=', 76) + @crlf +
       N'  Schema script for database ' + QUOTENAME(DB_NAME()) +
       N' on ' + QUOTENAME(CONVERT(sysname, SERVERPROPERTY('ServerName'))) + @crlf +
       N'  Generated ' + CONVERT(nvarchar(30), GETDATE(), 120) +
       N' by Script-Database-Schema.sql' + @crlf +
       N'  ' + CONVERT(nvarchar(10), @stmtCount) + N' statements' + @crlf +
       CASE WHEN @Phase = 99 THEN N'  Phase: all' ELSE N'  Phase: ' + CONVERT(nvarchar(10), @Phase) END +
       CASE WHEN @PartCount > 1
            THEN N'   Part ' + CONVERT(nvarchar(10), @PartNumber) + N' of ' + CONVERT(nvarchar(10), @PartCount)
            ELSE N'' END + @crlf +
       N'  There is deliberately no USE statement: replay this against whatever' + @crlf +
       N'  database you connect to, so it cannot overwrite the source by accident.' + @crlf +
       REPLICATE(N'=', 76) + N'*/';

--------------------------------------------------------------------------------
-- Output
--------------------------------------------------------------------------------
IF @OutputMode = 'ROWS'
BEGIN
    SELECT sort_order, object_type, schema_name, object_name, script_text
    FROM   #script
    ORDER  BY sort_order, sub_order, schema_name, object_name, id;
END
ELSE IF @OutputMode = 'SINGLE'
BEGIN
    SELECT (SELECT script_text + @crlf + N'GO' + @crlf + @crlf
            FROM   #script
            ORDER  BY sort_order, sub_order, schema_name, object_name, id
            FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)') AS full_script;
END
ELSE  -- 'PRINT'
BEGIN
    DECLARE @id int, @text nvarchar(max), @chunk nvarchar(4000), @cut int, @len int;

    DECLARE script_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT id, script_text
        FROM   #script
        ORDER  BY sort_order, sub_order, schema_name, object_name, id;

    OPEN script_cursor;
    FETCH NEXT FROM script_cursor INTO @id, @text;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @text = @text + @crlf + N'GO' + @crlf;
        SET @len  = DATALENGTH(@text) / 2;

        -- PRINT tops out at 4000 nchars, so emit in chunks that break on a line end
        WHILE @len > 0
        BEGIN
            IF @len <= 4000
                SET @cut = @len;
            ELSE
            BEGIN
                SET @chunk = SUBSTRING(@text, 1, 4000);
                SET @cut   = CHARINDEX(NCHAR(10), REVERSE(@chunk));
                -- no line break inside the window: one very long line, hard split
                SET @cut   = CASE WHEN @cut = 0 THEN 4000 ELSE 4000 - @cut + 1 END;
            END

            PRINT SUBSTRING(@text, 1, @cut);
            SET @text = SUBSTRING(@text, @cut + 1, @len);
            SET @len  = DATALENGTH(@text) / 2;
        END

        FETCH NEXT FROM script_cursor INTO @id, @text;
    END

    CLOSE script_cursor;
    DEALLOCATE script_cursor;
END

DROP TABLE #script;
DROP TABLE #schema_filter;
DROP TABLE #exclude_pattern;
DROP TABLE #module_level;
IF OBJECT_ID('tempdb..#module_dep') IS NOT NULL DROP TABLE #module_dep;
