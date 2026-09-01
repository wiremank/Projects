<#
.SYNOPSIS
    Parses every .sql file in the repo against the SQL Server 2019 grammar.

.DESCRIPTION
    Script-Database-Schema.sql is 78 KB of T-SQL that runs against production.
    A syntax error in a phase nobody has reached yet would surface as a failed
    run on the live server, which is the worst place to find one.

    Microsoft's own parser -- the one SSMS and sqlpackage use -- settles that
    without a database. TSql150Parser is the SQL Server 2019 grammar, matching
    MMC_V10. It checks syntax only: a misspelled catalog view parses fine, so
    this proves the script can be *loaded*, not that it returns the right rows.

    The parser ships as a NuGet package rather than with PowerShell, so it is
    fetched on first run and cached. With no network access the file parse is
    skipped rather than failed -- an unreachable nuget.org is not a defect in
    this repository.

.PARAMETER CacheDir
    Where to keep the downloaded parser. Defaults to .scriptdom/ at the repo
    root, which .gitignore excludes.

.EXAMPLE
    pwsh -File ./tests/Test-TSqlSyntax.ps1
#>

[CmdletBinding()]
param(
    [string] $CacheDir
)

$ErrorActionPreference = 'Stop'

$RepoRoot       = Split-Path -Parent $PSScriptRoot
$PackageId      = 'microsoft.sqlserver.transactsql.scriptdom'
$PackageVersion = '180.102.0'

if (-not $CacheDir) { $CacheDir = Join-Path $RepoRoot '.scriptdom' }

$script:Failures = 0

function Test-Case {
    param([string] $Name, [scriptblock] $Body)
    try {
        & $Body
        Write-Host "  PASS  $Name" -ForegroundColor Green
    }
    catch {
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        $($_.Exception.Message)"
        $script:Failures++
    }
}

# --- acquire the parser ------------------------------------------------------

function Get-ScriptDomAssembly {
    $dll = Join-Path $CacheDir 'Microsoft.SqlServer.TransactSql.ScriptDom.dll'
    if (Test-Path -LiteralPath $dll) { return $dll }

    New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
    $nupkg = Join-Path $CacheDir 'scriptdom.nupkg'
    $url   = "https://api.nuget.org/v3-flatcontainer/$PackageId/$PackageVersion/$PackageId.$PackageVersion.nupkg"

    Write-Host "  fetching the T-SQL parser ($PackageId $PackageVersion)..."
    Invoke-WebRequest -Uri $url -OutFile $nupkg -UseBasicParsing -ErrorAction Stop

    # A .nupkg is a zip. Take the net8.0 build, which is what pwsh 7 loads.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($nupkg)
    try {
        $entry = $zip.Entries | Where-Object {
            $_.FullName -eq 'lib/net8.0/Microsoft.SqlServer.TransactSql.ScriptDom.dll'
        }
        if (-not $entry) { throw 'the package does not contain a net8.0 build' }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dll, $true)
    }
    finally {
        $zip.Dispose()
        Remove-Item -LiteralPath $nupkg -Force -ErrorAction SilentlyContinue
    }
    return $dll
}

Write-Host ''
Write-Host 'T-SQL syntax (SQL Server 2019 grammar)'

try {
    Add-Type -Path (Get-ScriptDomAssembly)
}
catch {
    Write-Host "  SKIP  parser unavailable: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host ''
    exit 0
}

function Get-ParseError {
    param([string] $Path)
    # TSql150Parser == SQL Server 2019. $true means quoted identifiers are on,
    # which is how sqlcmd and SSMS connect by default.
    $parser = [Microsoft.SqlServer.TransactSql.ScriptDom.TSql150Parser]::new($true)
    $reader = [System.IO.StreamReader]::new($Path)
    try {
        $parseErrors = $null
        $parser.Parse($reader, [ref] $parseErrors) | Out-Null
        return $parseErrors
    }
    finally { $reader.Dispose() }
}

# --- self-check --------------------------------------------------------------

# A parser that silently returned no errors would make every test below pass
# while proving nothing. Confirm it rejects something first.
Test-Case 'the parser rejects invalid T-SQL' {
    $broken = Join-Path ([System.IO.Path]::GetTempPath()) "broken-$([guid]::NewGuid().ToString('N').Substring(0,8)).sql"
    Set-Content -LiteralPath $broken -Value 'SELECT FROM WHERE ORDER dbo..;' -Encoding UTF8
    try {
        $found = Get-ParseError -Path $broken
        if ($found.Count -eq 0) { throw 'the parser accepted deliberately invalid SQL' }
    }
    finally { Remove-Item -LiteralPath $broken -Force -ErrorAction SilentlyContinue }
}

# --- the repo's own SQL ------------------------------------------------------

$sqlFiles = Get-ChildItem -LiteralPath $RepoRoot -Filter '*.sql' -Recurse -File |
            Where-Object { $_.FullName -notmatch '[\\/](\.scriptdom|schema)[\\/]' }

if (-not $sqlFiles) {
    Write-Host '  no .sql files found' -ForegroundColor Yellow
}

foreach ($file in $sqlFiles) {
    $relative = $file.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')
    Test-Case "parses: $relative" {
        $parseErrors = Get-ParseError -Path $file.FullName
        if ($parseErrors.Count -gt 0) {
            $detail = $parseErrors | Select-Object -First 5 | ForEach-Object {
                "line $($_.Line) col $($_.Column): $($_.Message)"
            }
            throw "$($parseErrors.Count) syntax error(s); " + ($detail -join '; ')
        }
    }
}

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host "$script:Failures failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All tests passed.' -ForegroundColor Green
