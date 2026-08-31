<#
.SYNOPSIS
    Copies a reviewed schema export into the repo's schema/<Database>/ folder and
    commits it, refusing anything git or GitHub will choke on.

.DESCRIPTION
    Export-SytelineSchema.ps1 writes to a timestamped folder that .gitignore
    keeps out of the repo. This script is the second half: it checks that export
    for things that must not be committed, replaces schema/<Database>/ with it,
    writes a MANIFEST.md, and makes one commit.

    Checks, all of which stop the run:

      * any file at or over 100 MB      -- git's hard per-file limit
      * any database binary             -- .bak .bacpac .mdf .ldf and friends
      * anything that looks like a password in a connection string

    A file over 45 MB is a warning, not an error: GitHub warns at 50 MB and the
    commit still goes through.

    Nothing here touches SQL Server. Run it after the export, from the machine
    that has both the export files and a clone of this repo.

.PARAMETER ExportDir
    Folder written by Export-SytelineSchema.ps1.

.PARAMETER Database
    Names the destination folder, schema/<Database>/. Defaults to MMC_V10.

.PARAMETER RepoDir
    Repo root. Defaults to the parent of this script's folder.

.PARAMETER Push
    Also push the branch. Without it the commit is left local for review.

.PARAMETER Force
    Downgrade the size and content errors to warnings. Read what it printed
    before you reach for this.

.EXAMPLE
    .\scripts\Publish-SchemaExport.ps1 -ExportDir .\schema-export-MMC_V10-20260831-0915

.EXAMPLE
    .\scripts\Publish-SchemaExport.ps1 -ExportDir .\out -Database LIVE_BLR -Push
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $ExportDir,
    [string] $Database = 'MMC_V10',
    [string] $RepoDir,
    [switch] $Push,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

$GitMaxBytes  = 100MB   # git refuses outright
$WarnBytes    = 45MB    # GitHub warns at 50MB

$BinaryExtensions = @('.bak', '.trn', '.dif', '.bacpac', '.dacpac',
                      '.mdf', '.ndf', '.ldf')

function Format-Size([long] $bytes) {
    if     ($bytes -ge 1GB) { '{0:N2} GB' -f ($bytes / 1GB) }
    elseif ($bytes -ge 1MB) { '{0:N1} MB' -f ($bytes / 1MB) }
    elseif ($bytes -ge 1KB) { '{0:N0} KB' -f ($bytes / 1KB) }
    else                    { "$bytes B" }
}

function Invoke-Git {
    # Args arrive as one array so that git's own switches (-r, -q, --) are never
    # mistaken for parameters of this function.
    param([Parameter(Mandatory = $true)][string[]] $GitArgs)

    # git writes ordinary progress to stderr, which newer PowerShell turns into
    # a terminating error under ErrorActionPreference = Stop. Judge git by its
    # exit code instead.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & git -C $RepoDir @GitArgs 2>&1
    }
    finally {
        $ErrorActionPreference = $previous
    }

    if ($LASTEXITCODE -ne 0) {
        throw "git $($GitArgs -join ' ') failed:`n$($output -join [Environment]::NewLine)"
    }
    return $output
}

# --- locate the repo and the export -----------------------------------------

if (-not $RepoDir) {
    $RepoDir = Split-Path -Parent $PSScriptRoot
}
$RepoDir = (Resolve-Path -LiteralPath $RepoDir).Path

if (-not (Test-Path -LiteralPath (Join-Path $RepoDir '.git'))) {
    throw "Not a git repository: $RepoDir"
}
if (-not (Test-Path -LiteralPath $ExportDir)) {
    throw "Export folder not found: $ExportDir"
}
$ExportDir = (Resolve-Path -LiteralPath $ExportDir).Path

$files = @(Get-ChildItem -LiteralPath $ExportDir -File -Recurse | Sort-Object Name)
if ($files.Count -eq 0) {
    throw "No files in $ExportDir -- did the export run?"
}

# --- checks ------------------------------------------------------------------

$problems = @()
$warnings = @()

foreach ($f in $files) {
    if ($BinaryExtensions -contains $f.Extension.ToLowerInvariant()) {
        $problems += "$($f.Name) is a database binary ($($f.Extension)). " +
                     'That is the data, not the schema -- it does not belong in git.'
        continue
    }
    if ($f.Length -ge $GitMaxBytes) {
        $problems += "$($f.Name) is $(Format-Size $f.Length); git's limit is 100 MB. " +
                     'Re-run that phase with a higher -Parts count.'
    }
    elseif ($f.Length -ge $WarnBytes) {
        $warnings += "$($f.Name) is $(Format-Size $f.Length); GitHub warns over 50 MB."
    }
}

# A generated schema file has no business carrying a password. Catch the two
# shapes sqlcmd and SSMS leave behind.
$credentialPattern = '(?i)(pwd|password)\s*=\s*[^;''"\s]+'
$scannable = $files | Where-Object {
    $_.Length -lt 20MB -and $_.Extension -match '^\.(sql|txt|md|csv|json|xml|config)$'
}
foreach ($f in $scannable) {
    $hit = Select-String -LiteralPath $f.FullName -Pattern $credentialPattern -List -ErrorAction SilentlyContinue
    if ($hit) {
        $problems += "$($f.Name):$($hit.LineNumber) looks like it carries a password."
    }
}

$totalBytes = ($files | Measure-Object -Property Length -Sum).Sum
Write-Host ''
Write-Host "Export : $ExportDir"
Write-Host "Files  : $($files.Count), $(Format-Size $totalBytes) total"
Write-Host "Target : schema/$Database/"
Write-Host ''

foreach ($w in $warnings) { Write-Warning $w }

if ($problems.Count -gt 0) {
    foreach ($p in $problems) {
        if ($Force) { Write-Warning $p } else { Write-Host "ERROR: $p" -ForegroundColor Red }
    }
    if (-not $Force) {
        throw "$($problems.Count) blocking problem(s). Fix them, or re-run with -Force if you are certain."
    }
}

# --- replace schema/<Database>/ ----------------------------------------------

$dest = Join-Path (Join-Path $RepoDir 'schema') $Database
if (Test-Path -LiteralPath $dest) {
    # Delete through git so objects dropped since the last export show up as
    # deletions rather than lingering.
    Invoke-Git @('rm', '-r', '-q', '--ignore-unmatch', '--', "schema/$Database") | Out-Null
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Recurse -Force
    }
}
New-Item -ItemType Directory -Path $dest -Force | Out-Null

foreach ($f in $files) {
    $relative = $f.FullName.Substring($ExportDir.Length).TrimStart('\', '/')
    $target   = Join-Path $dest $relative
    $targetDir = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }
    Copy-Item -LiteralPath $f.FullName -Destination $target -Force
}

# --- manifest ----------------------------------------------------------------

$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
$rows  = foreach ($f in $files) {
    $relative = $f.FullName.Substring($ExportDir.Length).TrimStart('\', '/')
    $hash     = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.Substring(0, 12)
    '| `{0}` | {1} | `{2}` |' -f $relative, (Format-Size $f.Length), $hash
}

$manifest = @(
    "# $Database schema export",
    '',
    "Generated $stamp by ``Export-SytelineSchema.ps1``, published by",
    '``scripts/Publish-SchemaExport.ps1``. Schema only -- no table data.',
    '',
    '| File | Size | SHA-256 (first 12) |',
    '| --- | --- | --- |'
) + $rows + @(
    '',
    "Total: $($files.Count) files, $(Format-Size $totalBytes)."
)
Set-Content -LiteralPath (Join-Path $dest 'MANIFEST.md') -Value $manifest -Encoding UTF8

# --- commit ------------------------------------------------------------------

Invoke-Git @('add', '--', "schema/$Database") | Out-Null

$staged = Invoke-Git @('diff', '--cached', '--name-only', '--', "schema/$Database")
if (-not $staged) {
    Write-Host 'No change since the last export -- nothing to commit.'
    return
}

$branch = "$(Invoke-Git @('rev-parse', '--abbrev-ref', 'HEAD'))".Trim()
Invoke-Git @('commit', '-q', '-m', "Refresh $Database schema export ($stamp)") | Out-Null
Write-Host "Committed to $branch." -ForegroundColor Green

if ($Push) {
    $delay = 2
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            Invoke-Git @('push', '-u', 'origin', $branch) | Out-Null
            Write-Host "Pushed to origin/$branch." -ForegroundColor Green
            break
        }
        catch {
            if ($attempt -eq 5) { throw }
            Write-Warning "Push failed (attempt $attempt). Retrying in ${delay}s."
            Start-Sleep -Seconds $delay
            $delay *= 2
        }
    }
}
else {
    Write-Host "Review it, then: git push -u origin $branch"
}
