# Script-Database-Schema.sql

A single T-SQL script that scripts out an entire SQL Server database schema —
tables, views, stored procedures, functions, triggers, indexes, constraints,
sequences, user-defined types, synonyms, extended properties and permissions.

No SMO, no PowerShell, no SSMS "Generate Scripts" wizard, no linked tools: just
open it in SSMS (or run it through `sqlcmd`) against the database you want and
take the output.

## Use it

```sql
USE YourDatabase;
GO
-- then run Script-Database-Schema.sql
```

Straight to a file:

```
sqlcmd -S yourserver -d YourDatabase -E -i Script-Database-Schema.sql -o schema.sql
```

## Configuration

Everything is controlled by the `DECLARE` block at the top of the script.

| Variable | Default | Purpose |
| --- | --- | --- |
| `@SchemaFilter` | `NULL` | Comma-separated schema list, e.g. `N'dbo,sales'`. `NULL` = all schemas. |
| `@NameFilter` | `NULL` | `LIKE` pattern on object name, e.g. `N'usp[_]%'`. `NULL` = all objects. |
| `@Include*` | `1` | One switch per object category — turn off what you don't want. |
| `@IncludePermissions` | `0` | Emit object-level `GRANT`/`DENY`. |
| `@DropIfExists` | `0` | Prefix modules and synonyms with a drop guard. |
| `@OrderViewsByDependency` | `1` | Sort views so a view built on another view is created after it. |
| `@OutputMode` | `'PRINT'` | `PRINT` (Messages tab, chunked so nothing truncates), `ROWS` (one row per statement), `SINGLE` (whole script in one cell). |

## Emission order

Objects come out in an order that will replay cleanly on an empty database:

1. Schemas
2. User-defined data types and table types
3. Sequences
4. Tables (columns, computed columns, identity, collation, `SPARSE`, `ROWGUIDCOL`)
5. Primary key / unique constraints
6. Default constraints
7. Check constraints
8. Indexes — rowstore (with `INCLUDE`, filters, index options) and columnstore
9. Views (topologically sorted when `@OrderViewsByDependency = 1`)
10. Functions (scalar, inline TVF, multi-statement TVF)
11. Stored procedures
12. Triggers (DML and database-level DDL, with `DISABLE TRIGGER` for disabled ones)
13. Foreign keys — last, so every referenced table already exists
14. Synonyms
15. Extended properties (`MS_Description` and friends)
16. Object-level permissions

Each statement is separated by `GO`, and each section gets a banner comment with
an object count.

## Deliberate limitations

* Filegroups, partition functions/schemes, FILESTREAM and memory-optimized
  table options are not emitted — everything lands on the default filegroup.
* XML schema collections, CLR assemblies and types, full-text catalogs, Service
  Broker objects, and logins/users/roles are not emitted.
* Modules created `WITH ENCRYPTION` cannot be read; a comment is emitted in
  their place.
* Table types get their columns and PK/UNIQUE, not their check or default
  constraints.

Targets SQL Server 2016+, and avoids syntax newer than 2012 (no `STRING_AGG`,
no `DROP ... IF EXISTS`) so it also runs on older instances.
