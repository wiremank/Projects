# Getting an on-prem SQL Server database into this repo

You can reach the SQL Server; the assistant working in this repo cannot, and
cannot be granted access. So the split is fixed: **you run the extraction, git
carries the result.** Everything below runs on a machine of yours.

## First: decide what "copy the database" means

A git repository is not a place to put a database. It has no rows, no engine,
no restore. What it can hold is a **text description of the database** that
diffs, reviews and greps like source code.

| | Into git? | Why |
| --- | --- | --- |
| Schema — tables, views, procs, indexes, constraints | **Yes** | Text, diffable, reviewable. This is the point. |
| Catalog census — object and column inventory | **Yes** | Small, and answers "which table holds X" without a connection. |
| Small reference/config tables | Case by case | Only if non-sensitive and genuinely small. See below. |
| Transactional data — ledger, vouchers, POs, customers | **No** | Volume aside, it is financial and personal data. |
| `.bak`, `.bacpac`, `.mdf`/`.ldf` | **Never** | Opaque binaries containing *all* the data. `.gitignore` blocks them. |

For an ERP schema the practical limits are git's, not the disk's:

* **100 MB per file** — git refuses outright.
* **50 MB per file** — GitHub warns; the push still works.
* **~1 GB repo** recommended, 5 GB enforced.
* Git LFS does not solve this. It relocates the bytes and keeps the review
  problem: a binary blob nobody can read in a diff.

## The three steps

### 1. Export, on a machine that can reach SQL Server

`Script-Database-Schema.sql` and `Export-SytelineSchema.ps1` in this repo do
this with nothing but `sqlcmd` — no SSMS wizard, no SMO, no DDL rights, no
writes to the source. See `README.md` for the phases.

Start with the inventory and read it:

```powershell
.\Export-SytelineSchema.ps1 -Server <server>\<instance> -Database MMC_V10 -Phases 0
```

Phase 0 estimates the output size per phase. That number decides how far to
split — anything projected over ~45 MB gets more parts:

```powershell
.\Export-SytelineSchema.ps1 -Server <server>\<instance> -Database MMC_V10 -Parts @{ 6 = 8 }
```

Output lands in `schema-export-<db>-<stamp>\`, which `.gitignore` keeps out of
the repo until you publish it deliberately.

### 2. Review what came out

Skim it before it becomes a commit. Generated SQL should contain schema and
nothing else — no rows, no connection strings, no passwords, no personal data
that slipped in through an extended property or a default. The publish script
checks the mechanical parts of this; it cannot judge the content.

### 3. Publish

```powershell
.\scripts\Publish-SchemaExport.ps1 -ExportDir .\schema-export-MMC_V10-20260831-0915
```

It refuses oversized files and database binaries, copies the export into
`schema/MMC_V10/`, writes a `MANIFEST.md` with sizes and hashes, and makes one
commit. Add `-Push` when you want it pushed in the same step.

Re-running it later replaces the folder rather than adding to it, so dropped
objects show up as deletions and the diff between two exports is the real
schema change.

## If the SQL Server box has no GitHub access

Common, and it changes nothing structurally — only where each step runs.

1. On the locked-down box, run the export. `sqlcmd` alone is enough; the
   PowerShell driver is convenience, not a requirement.
2. Copy the output folder off it by whatever route is already approved for
   moving files out of that environment.
3. On a machine that does have GitHub, clone this repo and run
   `Publish-SchemaExport.ps1` against the copied folder.

For a handful of files GitHub's web uploader (Add file → Upload files) also
works, with a 25 MB per-file ceiling — lower than git's 100 MB, so it is only
useful for the inventory and the smaller phases.

## Committing actual data, when you must

Some tables are configuration rather than records — a UOM list, a code table —
and are genuinely useful in the repo. For those, and only those:

```
bcp "SELECT code, description FROM dbo.<table>_mst ORDER BY code" queryout data.tsv ^
    -S <server>\<instance> -d MMC_V10 -T -c -t"\t" -C 65001
```

Tab-separated, explicitly ordered so the file is stable across runs and the
diff means something. Keep it under a few thousand rows, and look at every
column you are about to publish — names, addresses, prices and contact details
do not belong in a repo, even a private one.

## Repository hygiene

* **Keep this repo private.** A schema is a map of the business.
* Never commit a connection string with a password. Windows auth (`-E` /
  `-T`) leaves nothing to leak.
* Turn on GitHub secret scanning and push protection (Settings → Code security).
* If something sensitive does get committed, rewriting history is not enough on
  its own — rotate whatever was exposed, because the old objects can persist in
  forks and caches.

## Running the tests

`Publish-SchemaExport.ps1` touches no database, so it can be tested properly:

```
pwsh -File ./tests/Test-PublishSchemaExport.ps1
```

The suite builds a throwaway repo and a fake export under the temp directory and
checks the things that would otherwise be discovered the hard way — that an
unchanged export produces no commit, that a dropped object comes through as a
deletion, and that each guard rail actually refuses rather than warns. It also
parses every `.ps1` in the repo, which stands in for PSScriptAnalyzer where the
Gallery is unreachable.

## PowerShell in a Claude Code web session

Those containers are Linux and start without PowerShell, so `.ps1` files can be
read but not run. `.claude/hooks/session-start.sh` installs it from Microsoft's
apt repository at session start — idempotent, and a no-op outside the remote
container. It needs registering in `.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command",
                     "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh" } ] }
    ]
  }
}
```

On your own machine, if you would rather not install PowerShell directly:

```
docker run --rm -it -v "${PWD}:/repo" -w /repo mcr.microsoft.com/powershell:latest pwsh
```

That gets you a shell with the repo mounted. Note the image has no `git` and no
`sqlcmd`, so it suits running the tests, not the export or the publish.
