<#
.SYNOPSIS
  Build one MSI from the app's WiX sources with plain-text stand-ins for the app's files.
.DESCRIPTION
  No Rust build: the payloads, models, docs, bitmaps and licence are small text or blank fixtures,
  so the package exercises its own tables (folders, registry, scope, upgrade and launch conditions)
  and nothing else. None of its "executables" can run: they are empty class libraries whose only
  content is a version resource. test-install-policy.ps1 only reads such a
  package; test-install-paths.ps1 installs one, on a disposable CI runner only.
  Writes the fixture files and the MSI into StageDirectory and returns the MSI's full path.
#>
param(
  [Parameter(Mandatory = $true)] [string] $PackagingDirectory,
  [Parameter(Mandatory = $true)] [string] $StageDirectory,
  [Parameter(Mandatory = $true)] [ValidateSet('x64','x86','arm64')] [string] $Arch,
  [Parameter(Mandatory = $true)] [ValidatePattern('^\d{1,3}\.\d{1,3}\.\d{1,5}$')] [string] $Version,
  [Parameter(Mandatory = $true)] [string] $DisplayVersion,
  [Parameter(Mandatory = $true)] [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*\.msi$')] [string] $MsiName
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$parts = @($Version.Split('.') | ForEach-Object { [int]$_ })
if ($parts[0] -gt 255 -or $parts[1] -gt 255 -or $parts[2] -gt 65535) { throw "Version $Version is outside MSI's 255.255.65535." }
$packaging = (Resolve-Path -LiteralPath $PackagingDirectory).Path
$root = (Resolve-Path -LiteralPath (Join-Path $packaging '..\..')).Path
$policy = Get-Content -Raw -LiteralPath (Join-Path $packaging 'install-policy.json') | ConvertFrom-Json
[void](New-Item -ItemType Directory -Force -Path $StageDirectory)
$stage = (Resolve-Path -LiteralPath $StageDirectory).Path
Add-Type -AssemblyName System.Drawing
# Executables get a version resource carrying the fixture's version and nothing else: an empty class
# library, which Windows will not start. Without one, an upgrade over a release keeps the release's
# versioned exe as the component key path ("Action: Null"), and removing the release then deletes it.
# The .NET Framework compiler that ships with Windows writes that resource; PowerShell 7's Add-Type does not.
$csc = @('Framework64', 'Framework') | ForEach-Object { Join-Path $env:WINDIR "Microsoft.NET\$_\v4.0.30319\csc.exe" } |
  Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $csc) { throw 'The .NET Framework 4 compiler (csc.exe) is needed to version the fixture executables.' }
$stub = Join-Path $stage 'versioned-fixture.cs'
$versioned = Join-Path $stage 'versioned-fixture.bin'
Set-Content -LiteralPath $stub -Encoding Ascii -Value @(
  "[assembly: System.Reflection.AssemblyFileVersion(`"$Version.0`")]"
  "[assembly: System.Reflection.AssemblyVersion(`"$Version.0`")]"
  'public static class NonExecutableMsiMetadataTestFixture {}')
& $csc /nologo /target:library "/out:$versioned" $stub | Out-Host
if ($LASTEXITCODE -ne 0) { throw "csc failed (exit $LASTEXITCODE)." }
$stamped = [Diagnostics.FileVersionInfo]::GetVersionInfo($versioned).FileVersion
if ($stamped -ne "$Version.0") { throw "The fixture executables carry version '$stamped', not $Version.0." }
foreach ($name in $policy.payloads) {
  $destination = Join-Path $stage $name
  [void](New-Item -ItemType Directory -Force -Path ([IO.Path]::GetDirectoryName($destination)))
  if ($name -match '\.(exe|dll)$') { Copy-Item -LiteralPath $versioned -Destination $destination -Force }
  else { Set-Content -LiteralPath $destination -Encoding Ascii -Value 'NON-EXECUTABLE MSI METADATA TEST FIXTURE' }
}
foreach ($folder in @('docs','models','notices')) {
  $path = Join-Path $stage $folder
  [void](New-Item -ItemType Directory -Force -Path $path)
  Set-Content -LiteralPath (Join-Path $path "$folder-fixture.txt") -Value 'Metadata test fixture, not a user file or model.'
}
foreach ($model in @('metadata-one.rten','metadata-two.rten')) {
  Set-Content -LiteralPath (Join-Path (Join-Path $stage 'models') $model) -Encoding Ascii -Value 'NON-EXECUTABLE MODEL METADATA FIXTURE'
}
foreach ($spec in @(@('banner.bmp',493,58),@('dialog.bmp',493,312))) {
  $bitmap = [Drawing.Bitmap]::new($spec[1],$spec[2],[Drawing.Imaging.PixelFormat]::Format24bppRgb)
  try { $bitmap.Save((Join-Path $stage $spec[0]),[Drawing.Imaging.ImageFormat]::Bmp) }
  finally { $bitmap.Dispose() }
}
Set-Content -LiteralPath (Join-Path $stage 'licence.rtf') -Encoding Ascii -Value '{\rtf1 Metadata test fixture.}'
$sources = @($policy.sources | ForEach-Object { Join-Path $packaging $_ })
$msi = Join-Path $stage $MsiName
$extensions = @($policy.extensions | ForEach-Object { '-ext'; "WixToolset.$_.wixext" })
& wix build @sources -arch $Arch @extensions `
  -culture en-US -d "Version=$Version" -d "DisplayVersion=$DisplayVersion" `
  -d "BinDir=$stage" -d "IconPath=$(Join-Path $root $policy.icon)" `
  -d "DocsDir=$(Join-Path $stage 'docs')" -d "ModelsDir=$(Join-Path $stage 'models')" `
  -d "AppNoticesDir=$(Join-Path $stage 'notices')" -d 'HasCraftFontLicences=1' -d 'HasCli=1' `
  -d "BannerBmp=$(Join-Path $stage 'banner.bmp')" -d "DialogBmp=$(Join-Path $stage 'dialog.bmp')" `
  -d "UiBannerBmp=$(Join-Path $stage 'banner.bmp')" -d "UiDialogBmp=$(Join-Path $stage 'dialog.bmp')" `
  -d "LicenseRtf=$(Join-Path $stage 'licence.rtf')" -o $msi @($policy.localization | ForEach-Object { '-loc'; Join-Path $packaging $_ }) |
  Out-Host # The MSI path is this script's only output.
if ($LASTEXITCODE -ne 0) { throw "WiX validation failed for $Arch (exit $LASTEXITCODE)." }
$msi
