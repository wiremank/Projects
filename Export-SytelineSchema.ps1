<#
.SYNOPSIS
    Drives Script-Database-Schema.sql through its phases and writes one numbered
    .sql file per phase, plus a master file that replays them in order.

.DESCRIPTION
    Phase 0 runs Phase-0-Inventory.sql and writes 00-inventory.txt -- read that
    before generating anything else. Phases 1..8 then generate the schema:

        01-foundation.sql       schemas, alias types, table types, sequences
        02-tables.sql           CREATE TABLE + primary key / unique
        03-integrity.sql        defaults, check constraints, indexes
        04-relations.sql        foreign keys
        05-views-functions.sql  views and functions, dependency-ordered
        06-procedures.sql       stored procedures
        07-triggers.sql         triggers
        08-extras.sql           synonyms, extended properties, permissions
        99-replay-all.sql       :r includes of the above, in order

    Nothing is written to the source database. Every phase is a read-only
    catalog query run under READ UNCOMMITTED.

    The engine script itself is never modified: each phase gets a temporary copy
    with its @Phase / @PartCount / @PartNumber / filter DECLAREs rewritten.

.PARAMETER Server
    SQL Server instance, e.g. SQLPROD01\SYTELINE.

.PARAMETER Database
    Database to script. Defaults to MMC_V10.

.PARAMETER OutDir
    Output folder. Defaults to .\schema-export-<database>-<yyyyMMdd-HHmm>.

.PARAMETER Phases
    Which phases to run. Defaults to 0..8 (inventory plus everything).
    Phase 0 is the inventory report.

.PARAMETER Parts
    Split a phase into N files, e.g. -Parts @{6 = 8} to cut the procedures
    phase into eight. Phase 5 cannot be split and is ignored if named here.

.PARAMETER SchemaFilter
    Comma-separated schema list, e.g. 'dbo'.

.PARAMETER NameFilter
    LIKE pattern on object name, e.g. 'po%'.

.PARAMETER ExcludeNameLike
    Comma-separated LIKE patterns to drop, e.g. '%_all,tmp[_]%'.

.PARAMETER CustomObjectsOnly
    Keep only uf_ / Uf_ / MMC_ named objects.

.PARAMETER SqlLogin / SqlPassword
    SQL authentication. Omit both for Windows integrated auth.

.EXAMPLE
    .\Export-SytelineSchema.ps1 -Server SQLPROD01\SYTELINE -Phases 0
    Inventory only. Start here.

.EXAMPLE
    .\Export-SytelineSchema.ps1 -Server SQLPROD01\SYTELINE -Parts @{6 = 8}
    Everything, with the procedures phase split into eight files.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $Server,
    [string]    $Database          = 'MMC_V10',
    [string]    $OutDir,
    [int[]]     $Phases            = @(0,1,2,3,4,5,6,7,8),
    [hashtable] $Parts             = @{},
    [string]    $SchemaFilter,
    [string]    $NameFilter,
    [string]    $ExcludeNameLike,
    [switch]    $CustomObjectsOnly,
    [switch]    $DropIfExists,
    [string]    $SqlLogin,
    [string]    $SqlPassword,
    [int]       $CodePage          = 65001,
    [string]    $EnginePath        = (Join-Path $PSScriptRoot 'Script-Database-Schema.sql'),
    [string]    $InventoryPath     = (Join-Path $PSScriptRoot 'Phase-0-Inventory.sql')
)

$ErrorActionPreference = 'Stop'

$phaseNames = @{
    1 = 'foundation'; 2 = 'tables';     3 = 'integrity'; 4 = 'relations'
    5 = 'views-functions'; 6 = 'procedures'; 7 = 'triggers'; 8 = 'extras'
}

if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
    throw "sqlcmd was not found on PATH. Install the SQL Server command line tools, or run the .sql files by hand in SSMS."
}
foreach ($f in @($EnginePath, $InventoryPath)) {
    if (-not (Test-Path $f)) { throw "Cannot find $f" }
}

if (-not $OutDir) {
    $OutDir = Join-Path (Get-Location) ("schema-export-{0}-{1}" -f $Database, (Get-Date -Format 'yyyyMMdd-HHmm'))
}
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$tempDir = Join-Path $OutDir '_temp'
New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

Write-Host "Server   : $Server"
Write-Host "Database : $Database"
Write-Host "Output   : $OutDir"
Write-Host ""

# ---------------------------------------------------------------------------
function Get-SqlcmdArgs {
    param([string] $InFile, [string] $OutFile)

    $a = @('-S', $Server, '-d', $Database, '-b', '-I', '-t', '0', '-w', '65535',
           '-i', $InFile, '-o', $OutFile)
    if ($SqlLogin) { $a += @('-U', $SqlLogin, '-P', $SqlPassword) } else { $a += '-E' }
    if ($CodePage -gt 0) { $a += @('-f', "$CodePage") }
    return $a
}

function Invoke-Phase {
    param([string] $InFile, [string] $OutFile, [string] $Label)

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $sqlArgs = Get-SqlcmdArgs -InFile $InFile -OutFile $OutFile
    & sqlcmd $sqlArgs 2>&1 | ForEach-Object { Write-Verbose $_ }
    $code = $LASTEXITCODE
    $sw.Stop()

    # sqlcmd writes server errors into the output file, so scan it either way
    $errLines = @()
    if (Test-Path $OutFile) {
        $errLines = @(Select-String -Path $OutFile -Pattern '^Msg \d+, Level \d+' -ErrorAction SilentlyContinue)
    }

    $sizeMb = 0
    if (Test-Path $OutFile) { $sizeMb = [math]::Round((Get-Item $OutFile).Length / 1MB, 2) }

    $status = if ($code -ne 0 -or $errLines.Count -gt 0) { 'FAILED' } else { 'ok' }
    '{0,-34} {1,8} {2,9} MB  {3,6}s' -f $Label, $status, $sizeMb, [math]::Round($sw.Elapsed.TotalSeconds, 1) |
        Write-Host -ForegroundColor $(if ($status -eq 'ok') { 'Green' } else { 'Red' })

    foreach ($e in ($errLines | Select-Object -First 5)) { Write-Host "    $($e.Line)" -ForegroundColor Red }

    [pscustomobject]@{
        Label = $Label; File = $OutFile; Status = $status; SizeMB = $sizeMb
        Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); Errors = $errLines.Count
    }
}

function New-PhaseScript {
    param([int] $Phase, [int] $PartCount, [int] $PartNumber, [string] $Path)

    $sql = Get-Content -Path $EnginePath -Raw

    $sql = [regex]::Replace($sql, '(?m)^(DECLARE\s+@Phase\s+int\s*=\s*)\d+;',      "`${1}$Phase;")
    $sql = [regex]::Replace($sql, '(?m)^(DECLARE\s+@PartCount\s+int\s*=\s*)\d+;',  "`${1}$PartCount;")
    $sql = [regex]::Replace($sql, '(?m)^(DECLARE\s+@PartNumber\s+int\s*=\s*)\d+;', "`${1}$PartNumber;")

    function Set-StringVar([string] $body, [string] $name, [string] $value) {
        $literal = if ([string]::IsNullOrEmpty($value)) { 'NULL' } else { "N'" + $value.Replace("'", "''") + "'" }
        return [regex]::Replace($body, "(?m)^(DECLARE\s+@$name\s+nvarchar\(4000\)\s*=\s*)[^;]+;", "`${1}$literal;")
    }
    $sql = Set-StringVar $sql 'SchemaFilter'    $SchemaFilter
    $sql = Set-StringVar $sql 'NameFilter'      $NameFilter
    $sql = Set-StringVar $sql 'ExcludeNameLike' $ExcludeNameLike

    $sql = [regex]::Replace($sql, '(?m)^(DECLARE\s+@CustomObjectsOnly\s+bit\s*=\s*)\d+;',
                            "`${1}$(if ($CustomObjectsOnly) { 1 } else { 0 });")
    $sql = [regex]::Replace($sql, '(?m)^(DECLARE\s+@DropIfExists\s+bit\s*=\s*)\d+;',
                            "`${1}$(if ($DropIfExists) { 1 } else { 0 });")
    $sql = [regex]::Replace($sql, "(?m)^(DECLARE\s+@OutputMode\s+varchar\(10\)\s*=\s*)'[^']*';", "`${1}'PRINT';")

    Set-Content -Path $Path -Value $sql -Encoding UTF8
}

# ---------------------------------------------------------------------------
$results  = @()
$replay   = @()

if ($Phases -contains 0) {
    $results += Invoke-Phase -InFile $InventoryPath `
                             -OutFile (Join-Path $OutDir '00-inventory.txt') `
                             -Label   'phase 0  inventory'
}

foreach ($phase in ($Phases | Where-Object { $_ -ge 1 -and $_ -le 8 } | Sort-Object)) {

    $partCount = 1
    if ($Parts.ContainsKey($phase)) { $partCount = [int] $Parts[$phase] }
    if ($phase -eq 5 -and $partCount -gt 1) {
        Write-Host "phase 5 cannot be split (views and functions bind at creation time) - running whole" -ForegroundColor Yellow
        $partCount = 1
    }

    foreach ($part in 1..$partCount) {
        $suffix   = if ($partCount -gt 1) { "-part{0}of{1}" -f $part, $partCount } else { '' }
        $baseName = '{0:00}-{1}{2}.sql' -f $phase, $phaseNames[$phase], $suffix
        $outFile  = Join-Path $OutDir $baseName
        $tmpFile  = Join-Path $tempDir ("engine-p{0}-{1}.sql" -f $phase, $part)

        New-PhaseScript -Phase $phase -PartCount $partCount -PartNumber $part -Path $tmpFile

        $label = 'phase {0}  {1}{2}' -f $phase, $phaseNames[$phase], $suffix
        $results += Invoke-Phase -InFile $tmpFile -OutFile $outFile -Label $label
        $replay  += $baseName
    }
}

# ---------------------------------------------------------------------------
if ($replay.Count -gt 0) {
    $master = Join-Path $OutDir '99-replay-all.sql'
    $lines  = @(
        '/*'
        "  Replay of $Database from $Server, generated $(Get-Date -Format 'yyyy-MM-dd HH:mm')."
        ''
        '  Run against the database you want to BUILD, not the source:'
        '      sqlcmd -S <server> -d <new_empty_db> -b -I -i 99-replay-all.sql'
        ''
        '  In SSMS this needs SQLCMD Mode (Query > SQLCMD Mode) for the :r includes.'
        '  The phase files carry no USE statement, so they build wherever you connect.'
        '*/'
        ''
    )
    foreach ($f in $replay) { $lines += ':r "{0}"' -f $f }
    Set-Content -Path $master -Value $lines -Encoding UTF8
    Write-Host ""
    Write-Host "Replay master: $master"
}

Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
$results | Format-Table Label, Status, SizeMB, Seconds, Errors -AutoSize

$failed = @($results | Where-Object { $_.Status -ne 'ok' })
if ($failed.Count -gt 0) {
    Write-Host "$($failed.Count) phase(s) failed - see the output files for the Msg lines." -ForegroundColor Red
    exit 1
}
Write-Host "All phases completed. Total $([math]::Round((($results | Measure-Object SizeMB -Sum).Sum), 2)) MB in $OutDir" -ForegroundColor Green
