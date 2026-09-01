<#
.SYNOPSIS
    Runs every test suite in this folder and reports one overall result.

.EXAMPLE
    pwsh -File ./tests/Invoke-AllTests.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$suites = Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'Test-*.ps1' -File | Sort-Object Name
$failed = @()

foreach ($suite in $suites) {
    & (Get-Process -Id $PID).Path -NoProfile -File $suite.FullName
    if ($LASTEXITCODE -ne 0) { $failed += $suite.Name }
}

Write-Host ''
if ($failed.Count -gt 0) {
    Write-Host "FAILED: $($failed -join ', ')" -ForegroundColor Red
    exit 1
}
Write-Host "$($suites.Count) suite(s) passed." -ForegroundColor Green
