# SyteLine schema scripter

Scripts a SQL Server database schema — tables, views, functions, stored
procedures, triggers, indexes, constraints, alias types, everything — out to
`.sql` files, using only T-SQL. No SMO, no SSMS "Generate Scripts" wizard.

Built for an ERP-sized schema, so it runs in **phases**: start with an
inventory, then generate one slice at a time and check each before moving on.

| File | What it is |
| --- | --- |
| `Script-Database-Schema.sql` | The whole thing. One file, one `@Phase` setting at the top. |
| `Export-SytelineSchema.ps1` | Optional driver — runs every phase and writes numbered files. |

Written for **SQL Server 2019** (it uses `STRING_AGG`, so 2017+ is required).

Everything is read-only: catalog queries under `READ UNCOMMITTED`, no locks a
clerk would notice, nothing written to the source database.

## The phases

| Phase | Contents | Splittable |
| --- | --- | --- |
| 0 | Inventory report — no DDL | — |
| 1 | Schemas, alias types, table types, sequences | first part only |
| 2 | Tables + primary key / unique constraints | yes |
| 3 | Defaults, check constraints, indexes | yes |
| 4 | Foreign keys | yes |
| 5 | **Views and functions**, dependency-ordered together | **no** |
| 6 | Stored procedures | yes |
| 7 | Triggers (DML + database DDL) | yes |
| 8 | Synonyms, extended properties, permissions | first part only |

Replayed in numeric order on an empty database they build the schema: alias
types before the tables that use them, tables before their indexes, everything
before the foreign keys that tie them together.

**Why views and functions share a phase, and why that phase can't be split.**
`CREATE VIEW` and `CREATE FUNCTION` resolve their references at creation time.
Procedures and triggers get deferred name resolution and will compile against
objects that don't exist yet — views and functions won't. So those two are
emitted together in one dependency order (view over view, view calling a
function, function selecting from a view) and always whole.

## Start here

Set `@Phase = 0` at the top of `Script-Database-Schema.sql` (that is the
shipped default) and run it:

```
sqlcmd -S <server>\<instance> -d MMC_V10 -E -W -s "|" -y 0 -Y 0 -h -1 ^
       -i Script-Database-Schema.sql -o inventory.txt
```

That reports the object census, an estimated output size per phase with a
suggested part count, every alias type and its base type, the `_mst` / `_all` /
site-view breakdown, which tables carry `uf_` columns, the largest module
definitions, and any encrypted modules that **cannot** be scripted at all.

Read it before generating anything. It tells you whether phase 6 is 20 MB or
400 MB, which decides how far to split.

In SSMS just open the script and hit execute — phase 0 comes back as result
grids whatever `@OutputMode` says.

## Then generate, one phase at a time

**In SSMS** — open `Script-Database-Schema.sql`, set the phase at the top:

```sql
DECLARE @Phase      int = 1;   -- 1..8, or 99 for everything
DECLARE @PartCount  int = 1;
DECLARE @PartNumber int = 1;
```

Run it, then copy the Messages tab into a file. Output is chunked at line
boundaries, so `PRINT`'s 4000-character cap never truncates anything.

With `@Verbose = 1` (the default) each section reports as it finishes, as a SQL
comment so it stays valid inside the generated file:

```
-- [14:22:07] phase 2 starting on [MMC_V10]
-- [14:22:19] tables: 9812 statements
```

If a run dies, the last of those lines tells you which section it died in.

**With sqlcmd** — same edit, then:

```
sqlcmd -S <server>\<instance> -d MMC_V10 -E -b -I -t 0 ^
       -i Script-Database-Schema.sql -o 01-foundation.sql
```

**With the driver** — runs every phase and writes numbered files:

```powershell
.\Export-SytelineSchema.ps1 -Server SQLPROD01\SYTELINE -Database MMC_V10 -Phases 0
.\Export-SytelineSchema.ps1 -Server SQLPROD01\SYTELINE -Database MMC_V10 -Parts @{6 = 8}
```

It never edits the engine — each phase gets a temp copy with the `DECLARE`
values rewritten. Output:

```
00-inventory.txt
01-foundation.sql
02-tables.sql
03-integrity.sql
04-relations.sql
05-views-functions.sql
06-procedures-part1of8.sql ... -part8of8.sql
07-triggers.sql
08-extras.sql
99-replay-all.sql
```

## Splitting a phase

`@PartCount` / `@PartNumber` cut one phase into N files. Bucketing is by object
name, so a given table lands in the same part in every phase, and part 1 is the
only part carrying the small one-off sections — splitting never duplicates
anything. Phase 5 ignores it.

## Replaying

The generated files carry **no `USE` statement** — deliberately, so a replay
can't overwrite the source by accident. They build into whatever database you
connect to:

```
sqlcmd -S <server> -d <new_empty_db> -b -I -i 99-replay-all.sql
```

In SSMS the master file needs SQLCMD Mode (Query → SQLCMD Mode) for its `:r`
includes; individual phase files run normally.

## SyteLine specifics

* **Alias types are not optional.** Every SyteLine column is declared with one
  — `AmountType`, `VendNumType`, `DateType` — so phase 1 has to run before
  phase 2 or every `CREATE TABLE` fails on an unknown type. Phase 0 lists them
  all with their base types.
* **The three layers fall out naturally.** `_mst` tables come in phase 2; the
  `_all` views and the site views come in phase 5, in the right order relative
  to each other.
* **Infor's objects are user objects** (`is_ms_shipped = 0`), so they're all in
  scope. `@CustomObjectsOnly` narrows to the `uf_` / `Uf_` / `MMC_` naming
  convention — but custom *columns* live inside stock tables, and no
  object-name filter finds those. Phase 0 reports them separately.
* **Encrypted modules can't be scripted.** Phase 0 lists them up front so you
  know what will be missing before you start.

## Other knobs

| Variable | Default | Purpose |
| --- | --- | --- |
| `@SchemaFilter` | `NULL` | Comma-separated schema list, e.g. `N'dbo'`. |
| `@NameFilter` | `NULL` | `LIKE` pattern on object name. |
| `@ExcludeNameLike` | `NULL` | Comma-separated `LIKE` patterns to drop, e.g. `N'%_all,tmp[_]%'`. |
| `@CustomObjectsOnly` | `0` | Keep only `uf_` / `Uf_` / `MMC_` named objects. |
| `@DropIfExists` | `0` | Prefix modules and synonyms with a drop guard. |
| `@OrderByDependency` | `1` | Dependency-sort views and functions. |
| `@Verbose` | `1` | Progress comments with timings, per section. |
| `@TopN` | `25` | Phase 0: rows in the "largest" / "most" lists. |
| `@OutputMode` | `'PRINT'` | `PRINT`, `ROWS` (one row per statement), or `SINGLE`. |

## Deliberate limitations

* Filegroups, partition functions/schemes, FILESTREAM and memory-optimized
  table options are not emitted — everything lands on the default filegroup.
* XML schema collections, CLR assemblies and types, full-text catalogs, Service
  Broker objects, and logins/users/roles are not emitted.
* Modules created `WITH ENCRYPTION` cannot be read; a comment is emitted in
  their place.
* Table types get their columns and PK/UNIQUE, not their check or default
  constraints.

Requires SQL Server 2017 or later — `STRING_AGG` does the list building. The
script checks the version up front and stops with a clear message rather than
failing on an unrecognised function.

## Not yet run against a live instance

There's no SQL Server reachable from the environment this was written in, so it
is statically checked, not execute-tested. Run phase 0 first and send the output
back, then phase 1 — both are small and will surface any syntax or catalog-shape
problem before you commit to generating hundreds of megabytes.

Direct SQL only, so this applies to the on-prem environments (MMC_V10,
LIVE-BLR). The SaaS sites (CISUS-G, WUXI-S) have no direct SQL access, so
nothing here runs against them.

## Publishing to GitHub

The export is only half of it — `PUBLISHING.md` covers getting the generated
files into this repository: what belongs in git, the size limits that decide
how far to split a phase, and `scripts/Publish-SchemaExport.ps1`, which checks
an export and commits it.
