<#
.SYNOPSIS
    Tests for scripts/Publish-SchemaExport.ps1.

.DESCRIPTION
    Builds a throwaway git repo and a fake export folder under the temp
    directory, runs the publish script against them, and checks what it did to
    the repo. Nothing here touches SQL Server, the network, or the real repo.

    No test framework: the repo has no package manager and the remote container
    may have no PowerShell Gallery access, so a dependency would be one more
    thing to install before anything can be verified.

.EXAMPLE
    pwsh -File ./tests/Test-PublishSchemaExport.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$RepoRoot      = Split-Path -Parent $PSScriptRoot
$PublishScript = Join-Path (Join-Path $RepoRoot 'scripts') 'Publish-SchemaExport.ps1'
$Database      = 'TEST_DB'

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

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

# --- fixture -----------------------------------------------------------------

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) "publish-test-$([guid]::NewGuid().ToString('N').Substring(0,8))"
$repo    = Join-Path $sandbox 'repo'
$export  = Join-Path $sandbox 'export'

function Reset-Fixture {
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
    New-Item -ItemType Directory -Path $repo   -Force | Out-Null
    New-Item -ItemType Directory -Path $export -Force | Out-Null

    git -C $repo init -q .
    git -C $repo config user.email 'test@example.invalid'
    git -C $repo config user.name  'schema test'

    Copy-Item -LiteralPath (Join-Path $RepoRoot '.gitignore')    -Destination $repo -Force
    Copy-Item -LiteralPath (Join-Path $RepoRoot '.gitattributes') -Destination $repo -Force
    New-Item -ItemType Directory -Path (Join-Path $repo 'scripts') -Force | Out-Null
    Copy-Item -LiteralPath $PublishScript -Destination (Join-Path $repo 'scripts') -Force

    git -C $repo add -A
    git -C $repo commit -q -m 'fixture'

    Set-SchemaFile '02-tables.sql' 'CREATE TABLE dbo.a (id int);'
}

function Set-SchemaFile {
    param([string] $Name, [string] $Content)
    Set-Content -LiteralPath (Join-Path $export $Name) -Value $Content -Encoding UTF8
}

function Remove-SchemaFile {
    param([string] $Name)
    Remove-Item -LiteralPath (Join-Path $export $Name) -Force
}

# Returns the publish script's exit code and output. Run out of process so the
# script's own `exit` is observable rather than killing the test run.
function Invoke-Publish {
    param([switch] $Force)
    $arguments = @('-NoProfile', '-File', (Join-Path (Join-Path $repo 'scripts') 'Publish-SchemaExport.ps1'),
                   '-ExportDir', $export, '-Database', $Database, '-RepoDir', $repo)
    if ($Force) { $arguments += '-Force' }

    $output = & (Get-Process -Id $PID).Path @arguments 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

function Get-CommitCount {
    [int](git -C $repo rev-list --count HEAD)
}

# --- tests -------------------------------------------------------------------

# PSScriptAnalyzer would be the real linter, but the remote container has no
# PowerShell Gallery access. The parser is built in and catches the class of
# mistake that matters most here: a script that cannot even be loaded.
Write-Host ''
Write-Host 'Syntax'

foreach ($script in Get-ChildItem -LiteralPath $RepoRoot -Filter '*.ps1' -Recurse -File) {
    $relative = $script.FullName.Substring($RepoRoot.Length).TrimStart('\', '/')
    Test-Case "parses: $relative" {
        $parseErrors = $null
        $tokens      = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $script.FullName, [ref] $tokens, [ref] $parseErrors) | Out-Null
        if ($parseErrors) {
            throw ($parseErrors | ForEach-Object {
                "line $($_.Extent.StartLineNumber): $($_.Message)"
            }) -join '; '
        }
    }
}

Write-Host ''
Write-Host 'Publish-SchemaExport.ps1'

Test-Case 'commits an export and writes a manifest' {
    Reset-Fixture
    $before = Get-CommitCount
    $result = Invoke-Publish
    Assert-True ($result.ExitCode -eq 0) "expected exit 0, got $($result.ExitCode)"
    Assert-True ((Get-CommitCount) -eq $before + 1) 'expected exactly one new commit'

    $tracked = git -C $repo ls-files "schema/$Database"
    Assert-True ($tracked -contains "schema/$Database/02-tables.sql") 'export file was not committed'
    Assert-True ($tracked -contains "schema/$Database/MANIFEST.md")   'manifest was not written'

    $manifest = Get-Content -LiteralPath (Join-Path $repo "schema/$Database/MANIFEST.md") -Raw
    Assert-True ($manifest -match '02-tables\.sql') 'manifest does not list the export file'
}

Test-Case 'makes no commit when the schema is unchanged' {
    $before = Get-CommitCount
    $result = Invoke-Publish
    Assert-True ($result.ExitCode -eq 0) "expected exit 0, got $($result.ExitCode)"
    Assert-True ((Get-CommitCount) -eq $before) 'an unchanged export produced a commit'
    Assert-True ($result.Output -match 'unchanged') 'did not report the export as unchanged'
}

Test-Case 'records a dropped object as a deletion' {
    Set-SchemaFile '05-views.sql' 'CREATE VIEW dbo.v AS SELECT 1 AS x;'
    Invoke-Publish | Out-Null
    Remove-SchemaFile '05-views.sql'

    $result = Invoke-Publish
    Assert-True ($result.ExitCode -eq 0) "expected exit 0, got $($result.ExitCode)"

    $tracked = git -C $repo ls-files "schema/$Database"
    Assert-True ($tracked -notcontains "schema/$Database/05-views.sql") 'dropped file is still tracked'

    $stat = git -C $repo show --stat --oneline HEAD | Out-String
    Assert-True ($stat -match '05-views\.sql') 'the deletion is not in the commit'
}

Test-Case 'refuses a file over git''s 100 MB limit' {
    $big = Join-Path $export '06-procedures.sql'
    $stream = [System.IO.File]::Create($big)
    try { $stream.SetLength(110MB) } finally { $stream.Dispose() }

    $before = Get-CommitCount
    $result = Invoke-Publish
    Assert-True ($result.ExitCode -eq 1) "expected exit 1, got $($result.ExitCode)"
    Assert-True ($result.Output -match '100 MB')      'did not name the size limit'
    Assert-True ((Get-CommitCount) -eq $before)       'committed despite the oversized file'
    Remove-SchemaFile '06-procedures.sql'
}

Test-Case 'refuses a database binary' {
    Set-SchemaFile 'TEST_DB.bak' 'not really a backup'
    $before = Get-CommitCount
    $result = Invoke-Publish
    Assert-True ($result.ExitCode -eq 1) "expected exit 1, got $($result.ExitCode)"
    Assert-True ($result.Output -match 'database binary') 'did not identify it as a database binary'
    Assert-True ((Get-CommitCount) -eq $before)           'committed despite the .bak'
    Remove-SchemaFile 'TEST_DB.bak'
}

Test-Case 'refuses a quoted password' {
    Set-SchemaFile '09-linked.sql' "EXEC sp_addlinkedsrvlogin @rmtpassword='hunter2';"
    $result = Invoke-Publish
    Assert-True ($result.ExitCode -eq 1) "expected exit 1, got $($result.ExitCode)"
    Assert-True ($result.Output -match 'password')       'did not flag the password'
    Remove-SchemaFile '09-linked.sql'
}

Test-Case 'refuses a CREATE LOGIN password' {
    Set-SchemaFile '09-login.sql' "CREATE LOGIN app WITH PASSWORD = N'S3cret!';"
    $result = Invoke-Publish
    Assert-True ($result.ExitCode -eq 1) "expected exit 1, got $($result.ExitCode)"
    Remove-SchemaFile '09-login.sql'
}

Test-Case 'does not mistake a password column for a password' {
    Set-SchemaFile '10-users.sql' 'CREATE TABLE dbo.users (password_hash varbinary(64), pwd_changed datetime);'
    $before = Get-CommitCount
    $result = Invoke-Publish
    Assert-True ($result.ExitCode -eq 0) "expected exit 0, got $($result.ExitCode): $($result.Output)"
    Assert-True ((Get-CommitCount) -eq $before + 1) 'a legitimate schema file was rejected'
}

Test-Case 'gitignore still blocks a binary waved through with -Force' {
    Set-SchemaFile 'TEST_DB.bak' 'not really a backup'
    Invoke-Publish -Force | Out-Null

    $tracked = git -C $repo ls-files "schema/$Database"
    Assert-True (-not ($tracked -match '\.bak$')) '-Force let a .bak into the repository'
    Remove-SchemaFile 'TEST_DB.bak'
}

# --- teardown ----------------------------------------------------------------

if (Test-Path -LiteralPath $sandbox) {
    Remove-Item -LiteralPath $sandbox -Recurse -Force
}

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host "$script:Failures failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All tests passed.' -ForegroundColor Green
