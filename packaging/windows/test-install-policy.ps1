<#
.SYNOPSIS
  Build non-executable installer metadata fixtures; never install them.
#>
param(
  [Parameter(Mandatory = $true)] [string] $OutputDirectory,
  [ValidateSet('x64','x86','arm64')] [string[]] $Architectures = @('x64','x86','arm64')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$policy = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'install-policy.json') | ConvertFrom-Json
[void](New-Item -ItemType Directory -Force -Path $OutputDirectory)
$output = (Resolve-Path -LiteralPath $OutputDirectory).Path
foreach ($arch in $Architectures) {
  $msi = & (Join-Path $PSScriptRoot 'build-fixture-msi.ps1') -PackagingDirectory $PSScriptRoot -StageDirectory (Join-Path $output $arch) `
    -Arch $arch -Version '0.0.1' -DisplayVersion '0.0.1-metadata-test' -MsiName "$($policy.id)-NOT-INSTALLABLE.msi"
  $shell = (Get-Process -Id $PID).Path
  & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'check-install-policy.ps1') -MsiPath $msi
  if ($LASTEXITCODE -ne 0) { throw "Compiled installer policy failed for $arch (exit $LASTEXITCODE)." }
  Write-Output "PASS $arch metadata-only package. This is not an executable installer."
}
