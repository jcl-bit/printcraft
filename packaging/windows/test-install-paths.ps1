<#
.SYNOPSIS
  Install, upgrade and remove the app's MSI the ways administrators do, and check where everything lands.
.DESCRIPTION
  For a disposable, elevated CI runner only (storytold/pdfcraft#5739). It installs and removes products for
  the runner's account and for all users, and refuses to start if any copy of the app is already installed.
  Two packages take part:
    previous  the last release's x64 MSI, downloaded and verified by the caller;
    current   this checkout's WiX sources built by build-fixture-msi.ps1 (the real tables, plain-text
              payloads), one patch version above previous; or CurrentMsi when given.
  Cases, numbered by the rows of the table in #5739:
    1  per-user install to a chosen INSTALLFOLDER
    2  all-users install (ALLUSERS=1) to the default folder
    3  all-users install to a chosen INSTALLFOLDER
    4  upgrade with no INSTALLFOLDER keeps the folder, per-user and all-users
    5  per-user upgrade with a new INSTALLFOLDER moves there and removes the old folder
    6  plain /qn over an all-users copy, 7 per-user over it, 8 all-users over a per-user copy: each refused
       by a launch condition, with the existing copy left as it was
  After every step exactly one product is registered, with the expected scope, version and ProductCode, and
  every file, registry value and shortcut in that package's tables is where its component's installed state
  says it should be: in the expected folder, in HKLM or HKCU for the scope, and nowhere in the other one.
  These are the Windows Sandbox checks used for #305 (App Paths, Open with, Default apps, the context menus,
  the shortcuts, the remembered InstallDir), read from the package's tables rather than written out for
  one app. Whether a conditional component (a context menu, the desktop shortcut) is installed at all is
  logged, not judged; only its files, values and shortcuts are. After every case the product is removed and a sweep must find nothing left: no product, file,
  folder or registry line naming the app.
  Every step says which account runs msiexec. Only the runner's own account is implemented. A LocalSystem
  runner (#5879: Datto RMM and Intune install as SYSTEM) plugs into Invoke-Step; the product list and the
  leftover sweep already look in LocalSystem's profile.
#>
param(
  [Parameter(Mandatory = $true)] [string] $PackagingDirectory,
  [Parameter(Mandatory = $true)] [string] $OutputDirectory,
  [Parameter(Mandatory = $true)] [string] $PreviousMsi,
  # A package to test instead of the fixture build, such as a release candidate. Must be newer than PreviousMsi.
  [string] $CurrentMsi = '',
  [string[]] $Only = @()
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($env:GITHUB_ACTIONS -ne 'true' -and $env:CRAFT_ALLOW_INSTALL_TESTS -ne '1') {
  throw 'This installs and removes software. Run it on a disposable CI runner, or set CRAFT_ALLOW_INSTALL_TESTS=1 in a throwaway VM.'
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'All-users installs need an elevated session.'
}
$CurrentSid = $identity.User.Value
$packaging = (Resolve-Path -LiteralPath $PackagingDirectory).Path
$policy = Get-Content -Raw -LiteralPath (Join-Path $packaging 'install-policy.json') | ConvertFrom-Json
if ($policy.mode -ne 'dualScope') { throw "Only dual-scope packages are covered (install-policy.json mode '$($policy.mode)')." }
$AppName = [string]$policy.name
$Suite = if ($policy.PSObject.Properties['suiteFolder']) { [string]$policy.suiteFolder } else { 'ArtCraft' }
[void](New-Item -ItemType Directory -Force -Path $OutputDirectory)
$Out = (Resolve-Path -LiteralPath $OutputDirectory).Path
$LogDir = Join-Path $Out 'logs'
[void](New-Item -ItemType Directory -Force -Path $LogDir)
$Summary = Join-Path $Out 'summary.txt'
if (Test-Path -LiteralPath $Summary) { Remove-Item -LiteralPath $Summary -Force } # one run per summary
$script:Pass = 0
$script:Fail = 0
$SysProfile = Join-Path $env:WINDIR 'System32\config\systemprofile'

# ---------------------------------------------------------------- reporting
function Note([string] $Text) {
  Write-Host $Text
  # Something reading the file at the same moment (a log tail, an indexer) must not fail the run.
  for ($try = 1; ; $try++) {
    try { Add-Content -LiteralPath $Summary -Value $Text -Encoding UTF8; return }
    catch [System.IO.IOException] { if ($try -ge 5) { throw }; Start-Sleep -Milliseconds 200 }
  }
}
function Check([string] $What, $Actual, $Expected) {
  if ("$Actual" -ceq "$Expected") { $script:Pass++; Note "PASS $What (= $Actual)"; return }
  $script:Fail++
  Note "FAIL $What (expected $Expected, got $Actual)"
  if ($env:GITHUB_ACTIONS -eq 'true') { Write-Host "::error::$What`: expected $Expected, got $Actual" }
}
function Add-Failure([string] $What) {
  $script:Fail++
  Note "FAIL $What"
  if ($env:GITHUB_ACTIONS -eq 'true') { Write-Host "::error::$What" }
}

# ---------------------------------------------------------------- package tables
function Get-ComProperty($Object, [string] $Name, [object[]] $Arguments = $null) {
  $Object.GetType().InvokeMember($Name, [Reflection.BindingFlags]::GetProperty, $null, $Object, $Arguments)
}
function Read-Rows($Database, [string] $Sql, [int] $Columns) {
  $view = $Database.OpenView($Sql)
  try {
    [void]$view.Execute()
    while ($null -ne ($record = $view.Fetch())) {
      try {
        $values = @(for ($i = 1; $i -le $Columns; $i++) { [string](Get-ComProperty $record 'StringData' @($i)) })
        , $values
      } finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($record) }
    }
  } finally {
    [void]$view.Close()
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($view)
  }
}
# "short|long" names: the long one. Directory.DefaultDir may also be "target:source": the target.
function Get-LongName([string] $Name) {
  $target = $Name.Split(':')[0]
  return $target.Split('|')[-1]
}
function Read-Package([string] $Path) {
  $installer = New-Object -ComObject WindowsInstaller.Installer
  $db = $installer.OpenDatabase((Resolve-Path -LiteralPath $Path).Path, 0)
  try {
    $tables = @(Read-Rows $db 'SELECT `Name` FROM `_Tables`' 1 | ForEach-Object { $_[0] })
    $props = @{}
    foreach ($r in @(Read-Rows $db 'SELECT `Property`, `Value` FROM `Property`' 2)) { $props[$r[0]] = $r[1] }
    $summary = Get-ComProperty $db 'SummaryInformation' @(0)
    try { $template = [string](Get-ComProperty $summary 'Property' @(7)) }
    finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($summary) }
    $dirs = @{}
    foreach ($r in @(Read-Rows $db 'SELECT `Directory`, `Directory_Parent`, `DefaultDir` FROM `Directory`' 3)) {
      $dirs[$r[0]] = [pscustomobject]@{ Parent = $r[1]; Name = (Get-LongName $r[2]) }
    }
    $components = @(Read-Rows $db 'SELECT `Component`, `ComponentId`, `Directory_`, `Condition` FROM `Component`' 4 | ForEach-Object {
        [pscustomobject]@{ Id = $_[0]; Guid = $_[1]; Dir = $_[2]; Condition = $_[3] } })
    $files = @(Read-Rows $db 'SELECT `File`, `Component_`, `FileName` FROM `File`' 3 | ForEach-Object {
        [pscustomobject]@{ Key = $_[0]; Component = $_[1]; Name = (Get-LongName $_[2]) } })
    $registry = @()
    if ($tables -contains 'Registry') {
      $registry = @(Read-Rows $db 'SELECT `Root`, `Key`, `Name`, `Value`, `Component_` FROM `Registry`' 5 | ForEach-Object {
          [pscustomobject]@{ Root = [int]$_[0]; Key = $_[1]; Name = $_[2]; Value = $_[3]; Component = $_[4] } })
    }
    $shortcuts = @()
    if ($tables -contains 'Shortcut') {
      $shortcuts = @(Read-Rows $db 'SELECT `Directory_`, `Name`, `Component_`, `Target` FROM `Shortcut`' 4 | ForEach-Object {
          [pscustomobject]@{ Dir = $_[0]; Name = (Get-LongName $_[1]); Component = $_[2]; Target = $_[3] } })
    }
    $launch = @()
    if ($tables -contains 'LaunchCondition') {
      $launch = @(Read-Rows $db 'SELECT `Condition`, `Description` FROM `LaunchCondition`' 2 | ForEach-Object {
          [pscustomobject]@{ Condition = $_[0]; Message = $_[1] } })
    }
  } finally {
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($db)
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($installer)
  }
  $version = (@($props['ProductVersion'].Split('.'))[0..2]) -join '.'
  return [pscustomobject]@{ Path = (Resolve-Path -LiteralPath $Path).Path; ProductCode = $props['ProductCode']; UpgradeCode = $props['UpgradeCode']
    ProductName = $props['ProductName']; Version = $version; Template = $template; Dirs = $dirs; Components = $components
    Files = $files; Registry = $registry; Shortcuts = $shortcuts; LaunchConditions = $launch }
}
# The path of a directory below Anchor ('' for Anchor itself), or $null if it is not below it.
function Get-SubPath($Package, [string] $Dir, [string] $Anchor) {
  $parts = New-Object System.Collections.Generic.List[string]
  for ($hop = 0; $hop -lt 32 -and $Dir; $hop++) {
    if ($Dir -eq $Anchor) { $parts.Reverse(); return ($parts.ToArray() | Where-Object { $_ -ne '.' }) -join '\' }
    if (-not $Package.Dirs.ContainsKey($Dir)) { return $null }
    $parts.Add($Package.Dirs[$Dir].Name)
    $Dir = $Package.Dirs[$Dir].Parent
  }
  return $null
}
function Join-Folder([string] $Base, [string] $Sub) {
  if ($Sub) { return (Join-Path $Base $Sub) + '\' }
  return $Base
}
function Get-FilePath($Package, [string] $Key, [string] $Folder) {
  $file = @($Package.Files | Where-Object { $_.Key -ceq $Key })
  if ($file.Count -ne 1) { return $null }
  $component = @($Package.Components | Where-Object { $_.Id -ceq $file[0].Component })
  if ($component.Count -ne 1) { return $null }
  $sub = Get-SubPath $Package $component[0].Dir 'INSTALLFOLDER'
  if ($null -eq $sub) { return $null }
  return Join-Path (Join-Folder $Folder $sub) $file[0].Name
}
# Resolve [#File] and [Directory] references below INSTALLFOLDER; $null if anything else is left to format.
function Format-Value($Package, [string] $Text, [string] $Folder) {
  $reference = '\[(#?)([A-Za-z_][A-Za-z0-9_.]*)\]'
  if (([regex]::Replace($Text, $reference, '')).Contains('[')) { return $null }
  $out = New-Object System.Text.StringBuilder
  $last = 0
  foreach ($m in [regex]::Matches($Text, $reference)) {
    if ($m.Groups[1].Value -eq '#') { $path = Get-FilePath $Package $m.Groups[2].Value $Folder }
    else {
      $sub = Get-SubPath $Package $m.Groups[2].Value 'INSTALLFOLDER'
      $path = if ($null -eq $sub) { $null } else { Join-Folder $Folder $sub }
    }
    if ($null -eq $path) { return $null }
    [void]$out.Append($Text.Substring($last, $m.Index - $last)).Append($path)
    $last = $m.Index + $m.Length
  }
  return $out.Append($Text.Substring($last)).ToString()
}
function Get-Hive([string] $Scope) {
  if ($Scope -eq 'machine') { return 'Registry::HKEY_LOCAL_MACHINE' }
  return 'Registry::HKEY_CURRENT_USER'
}
function Get-LinkFolder([string] $Dir, [string] $Scope) {
  $map = @{ ProgramMenuFolder = @('Programs', 'CommonPrograms'); DesktopFolder = @('Desktop', 'CommonDesktopDirectory') }
  if (-not $map.ContainsKey($Dir)) { return $null }
  $name = if ($Scope -eq 'machine') { $map[$Dir][1] } else { $map[$Dir][0] }
  return [Environment]::GetFolderPath($name)
}
# Everything the package puts on disk or in the registry for one scope and folder, by component.
# Expected = $null means "exists", for values this script does not format (binary, multi-string, other properties).
function Get-Expectations($Package, [string] $Scope, [string] $Folder) {
  $items = New-Object System.Collections.Generic.List[object]
  foreach ($f in $Package.Files) {
    $path = Get-FilePath $Package $f.Key $Folder
    if ($path) { $items.Add([pscustomobject]@{ Component = $f.Component; Kind = 'file'; Path = $path; Name = ''; Expected = $null }) }
  }
  foreach ($r in $Package.Registry) {
    # Registry.Root: -1 is HKLM for all users and HKCU for one, 0 is HKCR (the scope's Software\Classes).
    $hive = @{ '-1' = (Get-Hive $Scope); '0' = (Get-Hive $Scope) + '\Software\Classes'; '1' = 'Registry::HKEY_CURRENT_USER'; '2' = 'Registry::HKEY_LOCAL_MACHINE' }["$($r.Root)"]
    if (-not $hive -or $r.Name -eq '-') { continue }
    $path = "$hive\$($r.Key)"
    if ($r.Name -in @('+', '*') -or ($r.Name -eq '' -and $r.Value -eq '')) {
      $items.Add([pscustomobject]@{ Component = $r.Component; Kind = 'key'; Path = $path; Name = ''; Expected = $null }); continue
    }
    $raw = Format-Value $Package $r.Value $Folder
    $expected = $null
    if ($null -ne $raw) {
      if ($raw -match '^#[+-]?\d+$') { $expected = [string][int]$raw.Substring(1) }
      elseif ($raw.StartsWith('#%')) { $expected = $raw.Substring(2) }
      elseif ($raw.StartsWith('##')) { $expected = $raw.Substring(1) }
      elseif (-not $raw.StartsWith('#')) { $expected = $raw }
    }
    $items.Add([pscustomobject]@{ Component = $r.Component; Kind = 'value'; Path = $path; Name = $r.Name; Expected = $expected })
  }
  foreach ($s in $Package.Shortcuts) {
    $dir = Get-LinkFolder $s.Dir $Scope
    if (-not $dir) { continue }
    $target = $null
    if ($s.Target.StartsWith('[')) { $target = Format-Value $Package $s.Target $Folder }
    $items.Add([pscustomobject]@{ Component = $s.Component; Kind = 'link'; Path = (Join-Path $dir "$($s.Name).lnk"); Name = ''; Expected = $target })
  }
  return $items.ToArray()
}
# $null if the item is absent, otherwise what is there ('' for a key, a value without data, or a file).
function Get-Actual($Item) {
  switch ($Item.Kind) {
    'file' { if (Test-Path -LiteralPath $Item.Path -PathType Leaf) { return '' }; return $null }
    'key' { if (Test-Path -LiteralPath $Item.Path) { return '' }; return $null }
    'link' {
      if (-not (Test-Path -LiteralPath $Item.Path -PathType Leaf)) { return $null }
      return [string](New-Object -ComObject WScript.Shell).CreateShortcut($Item.Path).TargetPath
    }
    'value' {
      $key = Get-Item -LiteralPath $Item.Path -ErrorAction SilentlyContinue
      if (-not $key) { return $null }
      try {
        if ($key.GetValueNames() -notcontains $Item.Name) { return $null }
        return [string]$key.GetValue($Item.Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
      } finally { $key.Close() }
    }
  }
}
function Format-Item($Item) {
  if ($Item.Kind -eq 'value') { return "$($Item.Path) '$($Item.Name)'" }
  return "$($Item.Kind) $($Item.Path)"
}

# ---------------------------------------------------------------- installed products
function Get-InstallProperty($Product, [string] $Name) {
  try { return [string](Get-ComProperty $Product 'InstallProperty' @($Name)) } catch { return '' }
}
# A ProductCode as Windows Installer writes it in registry key names, and back (the transform is its own inverse).
function Convert-SquishedGuid([string] $Guid) {
  $h = $Guid.Trim('{}') -replace '-', ''
  $r = (-join $h.Substring(0, 8)[7..0]) + (-join $h.Substring(8, 4)[3..0]) + (-join $h.Substring(12, 4)[3..0])
  for ($i = 16; $i -lt 32; $i += 2) { $r += [string]$h[$i + 1] + [string]$h[$i] }
  return $r.ToUpper()
}
# Every installed copy of the app, in every context, with the context Windows Installer installed it in.
function Get-Products {
  $out = New-Object System.Collections.Generic.List[object]
  $wi = New-Object -ComObject WindowsInstaller.Installer
  foreach ($p in @(Get-ComProperty $wi 'ProductsEx' @('', 's-1-1-0', 7))) {
    if ((Get-InstallProperty $p 'ProductName') -cne $AppName) { continue }
    $context = [int](Get-ComProperty $p 'Context')
    $sid = [string](Get-ComProperty $p 'UserSid')
    $scope = if ($context -eq 4) { 'machine' } elseif ($sid -eq 'S-1-5-18') { 'system' } elseif ($sid -eq $CurrentSid) { 'user' } else { 'other-user' }
    $out.Add([pscustomobject]@{ Code = [string](Get-ComProperty $p 'ProductCode'); Version = (Get-InstallProperty $p 'VersionString'); Scope = $scope; Sid = $sid; Com = $p })
  }
  # ProductsEx has not listed LocalSystem's per-user copies (Windows Sandbox, 2026-11-02): read them from
  # where Windows Installer publishes an unmanaged per-user product, in SYSTEM's hive.
  foreach ($k in @(Get-ChildItem -LiteralPath 'Registry::HKEY_USERS\S-1-5-18\Software\Microsoft\Installer\Products' -ErrorAction SilentlyContinue)) {
    if ("$($k.GetValue('ProductName'))" -cne $AppName -or $k.PSChildName -notmatch '^[0-9A-Fa-f]{32}$') { continue }
    $hex = Convert-SquishedGuid $k.PSChildName
    $code = '{' + $hex.Substring(0, 8) + '-' + $hex.Substring(8, 4) + '-' + $hex.Substring(12, 4) + '-' + $hex.Substring(16, 4) + '-' + $hex.Substring(20, 12) + '}'
    if (@($out | Where-Object { $_.Code -eq $code -and $_.Scope -eq 'system' }).Count) { continue }
    $v = [int64]$k.GetValue('Version')
    $out.Add([pscustomobject]@{ Code = $code; Version = "$($v -shr 24).$(($v -shr 16) -band 0xFF).$($v -band 0xFFFF)"; Scope = 'system'; Sid = 'S-1-5-18'; Com = $null })
  }
  return $out.ToArray()
}

# ---------------------------------------------------------------- msiexec
# Verbose logs can be UTF-16 with or without a byte order mark, or ANSI.
function Read-Log([string] $Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  $bytes = [IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { return [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2) }
  if ($bytes.Length -ge 2 -and $bytes[1] -eq 0) { return [Text.Encoding]::Unicode.GetString($bytes) }
  return [Text.Encoding]::Default.GetString($bytes)
}
function Invoke-Msiexec([string] $Name, [string[]] $Arguments) {
  $log = Join-Path $LogDir "$($Name -replace '[^A-Za-z0-9.-]+', '-').log"
  # 1618: another installation is in progress (a runner image's own MSI work, or the service still busy).
  for ($try = 1; ; $try++) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath msiexec.exe -ArgumentList (@($Arguments) + @('/l*v', "`"$log`"")) -Wait -PassThru
    $sw.Stop()
    Note ('{0}: msiexec {1} -> exit {2} in {3:n0}s' -f $Name, ($Arguments -join ' '), $p.ExitCode, $sw.Elapsed.TotalSeconds)
    if ($p.ExitCode -ne 1618 -or $try -ge 5) { return [pscustomobject]@{ Code = $p.ExitCode; Log = $log } }
    Note "$Name`: another installation is in progress (1618), trying again in 20 s"
    Start-Sleep -Seconds 20
  }
}
# One install step. RunAs names the account msiexec runs as; 'runner' (this elevated session) is the only one
# so far. A 'system' runner for #5879 goes here, and its products and leftovers are already looked for.
function Invoke-Step([string] $Name, $Package, [string[]] $Properties, [string] $RunAs) {
  if ($RunAs -ne 'runner') { throw "msiexec as '$RunAs' is not implemented yet." }
  return Invoke-Msiexec $Name (@('/i', "`"$($Package.Path)`"", '/qn', '/norestart') + $Properties)
}
# Remove every copy, per-user ones first: copies in two contexts share component GUIDs, and the one removed
# last takes the shared components with it (Windows Sandbox, 2026-11-02).
function Remove-All([string] $Name) {
  $tried = @{}
  $i = 0
  while ($true) {
    $next = @(@(Get-Products) | Where-Object { -not $tried.ContainsKey("$($_.Scope)|$($_.Code)") } |
        Sort-Object { if ($_.Scope -eq 'machine') { 1 } else { 0 } })
    if ($next.Count -eq 0) { break }
    $p = $next[0]
    $tried["$($p.Scope)|$($p.Code)"] = $true
    $i++
    if ($p.Scope -notin @('user', 'machine')) { Add-Failure "$Name`: cannot remove the $($p.Scope) copy $($p.Code) ($($p.Sid)) from this account"; continue }
    $r = Invoke-Msiexec "$Name-$i-$($p.Scope)" @('/x', $p.Code, '/qn', '/norestart')
    Check "$Name`: msiexec /x of the $($p.Scope) copy exit code" $r.Code 0
  }
}

# ---------------------------------------------------------------- checks
function Assert-Installed([string] $Tag, $Package, [string] $Scope, [string] $Folder) {
  $products = @(Get-Products)
  Check "$Tag`: $AppName products registered" $products.Count 1
  if ($products.Count -ne 1) { return }
  $p = $products[0]
  Check "$Tag`: installed for" $p.Scope $Scope
  Check "$Tag`: version" $p.Version $Package.Version
  Check "$Tag`: ProductCode" $p.Code $Package.ProductCode
  Check "$Tag`: folder exists ($Folder)" (Test-Path -LiteralPath $Folder -PathType Container) $true
  if (-not $p.Com) { return }
  $installed = @{}
  $missing = New-Object System.Collections.Generic.List[string]
  foreach ($c in $Package.Components) {
    # 3 local, 4 source; 2 absent. A component without a GUID is never registered, so it has no state.
    if (-not $c.Guid) { $installed[$c.Id] = -not $c.Condition; continue }
    $state = try { [int](Get-ComProperty $p.Com 'ComponentState' @($c.Guid)) } catch { -1 }
    $installed[$c.Id] = $state -in @(3, 4)
    if (-not $c.Condition -and -not $installed[$c.Id]) { $missing.Add("$($c.Id) (state $state)") }
  }
  Check "$Tag`: unconditional components not installed" (@($missing) -join ', ') ''
  Note "$Tag`: conditional components installed: $((@($Package.Components | Where-Object { $_.Condition } | ForEach-Object { "$($_.Id)=$($installed[$_.Id])" })) -join ', ')"
  $other = if ($Scope -eq 'machine') { 'user' } else { 'machine' }
  $bad = New-Object System.Collections.Generic.List[string]
  $counts = @{ file = 0; value = 0; key = 0; link = 0 }
  foreach ($item in @(Get-Expectations $Package $Scope $Folder)) {
    $actual = Get-Actual $item
    if ($installed[$item.Component]) {
      $counts[$item.Kind]++
      if ($null -eq $actual) { $bad.Add("missing $(Format-Item $item)") }
      elseif ($null -ne $item.Expected -and $actual -ine $item.Expected) { $bad.Add("$(Format-Item $item) is '$actual', expected '$($item.Expected)'") }
    } elseif ($null -ne $actual) { $bad.Add("$(Format-Item $item) present for an uninstalled component $($item.Component)") }
  }
  foreach ($item in @(Get-Expectations $Package $other $Folder | Where-Object { $_.Kind -ne 'file' })) {
    if ($null -ne (Get-Actual $item)) { $bad.Add("$(Format-Item $item) written for $other") }
  }
  foreach ($line in $bad | Select-Object -First 25) { Note "  $line" }
  Check "$Tag`: mismatches among $($counts.file) files, $($counts.value) registry values, $($counts.key) keys and $($counts.link) shortcuts, and in the $other scope" $bad.Count 0
}
# Guard is a property the expected launch condition tests (install-policy.wxi: CRAFT_MACHINE_DIR refuses a
# per-user copy over an all-users one, CRAFT_USER_DIR the reverse).
function Assert-Refused([string] $Tag, $Result, $Package, [string] $Guard) {
  Check "$Tag`: exit code" $Result.Code 1603
  $text = Read-Log $Result.Log
  # Compare the text up to the first formatted [Property], which the log shows resolved.
  $hits = @($Package.LaunchConditions | Where-Object { $prefix = ($_.Message -split '\[')[0].Trim(); $prefix.Length -ge 10 -and $text.Contains($prefix) })
  Check "$Tag`: launch condition messages in the log" $hits.Count 1
  if ($hits.Count -eq 1) {
    Note "$Tag`: launch condition message: $($hits[0].Message)"
    Check "$Tag`: refused by the condition that tests $Guard" ($hits[0].Condition -match "\b$([regex]::Escape($Guard))\b") $true
  }
}
# Registry lines and files naming the app anywhere an installation could leave them. MuiCache and similar
# lines under "Local Settings" are Windows' own launch records: logged, not counted.
function Get-Leftovers([string] $Tag, [string[]] $Folders) {
  $lines = New-Object System.Collections.Generic.List[string]
  $roots = New-Object System.Collections.Generic.List[string]
  foreach ($h in @('HKLM', 'HKCU', 'HKU\S-1-5-18')) {
    foreach ($sub in @('SOFTWARE\Classes', "SOFTWARE\$AppName", 'SOFTWARE\RegisteredApplications', 'SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths',
        'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')) { $roots.Add("$h\$sub") }
  }
  foreach ($r in @('HKLM\SOFTWARE\WOW6432Node\Classes', 'HKCU\SOFTWARE\Microsoft\Installer', 'HKU\S-1-5-18\SOFTWARE\Microsoft\Installer')) { $roots.Add($r) }
  foreach ($root in $roots) {
    # Through cmd with stderr discarded: a missing root is not an error here.
    $key = ''
    foreach ($line in @(& cmd.exe /d /c "reg.exe query `"$root`" /s /f `"$AppName`" 2>nul")) {
      if ($line -match '^HKEY_') { $key = $line.Trim() }
      if ($line -notmatch [regex]::Escape($AppName) -or $key -match '\\Local Settings\\') { continue }
      $lines.Add($(if ($line -match '^HKEY_') { "registry $key" } else { "registry $key :: $($line.Trim())" }))
    }
  }
  $global:LASTEXITCODE = 0
  # The app's own default folders, not the suite folder: another Craft app may share it.
  $paths = @($Folders) + @((Join-Path $env:LOCALAPPDATA "Programs\$Suite\$AppName"), (Join-Path $env:ProgramW6432 "$Suite\$AppName"),
    (Join-Path $SysProfile "AppData\Local\Programs\$Suite\$AppName"))
  foreach ($pkg in $Packages.Values) {
    foreach ($s in $pkg.Shortcuts) {
      foreach ($scope in @('user', 'machine')) { $d = Get-LinkFolder $s.Dir $scope; if ($d) { $paths += Join-Path $d "$($s.Name).lnk" } }
      if ($s.Dir -eq 'ProgramMenuFolder') { $paths += Join-Path $SysProfile "AppData\Roaming\Microsoft\Windows\Start Menu\Programs\$($s.Name).lnk" }
      if ($s.Dir -eq 'DesktopFolder') { $paths += Join-Path $SysProfile "Desktop\$($s.Name).lnk" }
    }
  }
  foreach ($p in @($paths | Where-Object { $_ } | Select-Object -Unique)) { if (Test-Path -LiteralPath $p) { $lines.Add("file $p") } }
  Set-Content -LiteralPath (Join-Path $LogDir "leftovers-$($Tag -replace '[^A-Za-z0-9.-]+', '-').txt") -Value $lines -Encoding UTF8
  return $lines.ToArray()
}
function Assert-Clean([string] $Tag, [string[]] $Folders) {
  $products = @(Get-Products)
  Check "$Tag`: $AppName products registered" $products.Count 0
  $left = @(Get-Leftovers $Tag $Folders)
  foreach ($line in $left | Select-Object -First 25) { Note "  $line" }
  Check "$Tag`: leftover files, folders and registry lines" $left.Count 0
}

# ---------------------------------------------------------------- packages
$Packages = [ordered]@{}
$Packages['previous'] = Read-Package $PreviousMsi
$prev = $Packages['previous']
if ($prev.UpgradeCode.Trim('{}') -ne $policy.upgradeCode) { throw "$PreviousMsi is not $AppName (UpgradeCode $($prev.UpgradeCode))." }
if ($prev.Template -notmatch '^x64;') { throw "$PreviousMsi is not an x64 package ($($prev.Template))." }
if ($CurrentMsi) { $Packages['current'] = Read-Package $CurrentMsi }
else {
  $v = @($prev.Version.Split('.') | ForEach-Object { [int]$_ })
  if ($v[2] -ge 65534) { throw "No patch version above $($prev.Version) that the fixture builder can stamp." }
  $next = "$($v[0]).$($v[1]).$($v[2] + 1)"
  $built = @(& (Join-Path $PSScriptRoot 'build-fixture-msi.ps1') -PackagingDirectory $packaging -StageDirectory (Join-Path $Out 'fixture') `
      -Arch x64 -Version $next -DisplayVersion "$next-install-test" -MsiName "$($policy.id)-$next-install-test.msi")
  $Packages['current'] = Read-Package $built[-1]
}
$cur = $Packages['current']
if ($cur.UpgradeCode -ne $prev.UpgradeCode -or $cur.Template -notmatch '^x64;') { throw "$($cur.Path) is not the same x64 product as $PreviousMsi." }
if ([version]$cur.Version -le [version]$prev.Version) { throw "$($cur.Path) ($($cur.Version)) is not newer than $PreviousMsi ($($prev.Version))." }
foreach ($k in $Packages.Keys) { Note "package $k`: $($Packages[$k].ProductName) $($Packages[$k].Version) $($Packages[$k].ProductCode) $($Packages[$k].Path)" }
if (@(Get-Products).Count) { throw "$AppName is already installed here. This script removes what it installs, so it will not start." }

$UserDefault = Join-Path $env:LOCALAPPDATA "Programs\$Suite\$AppName\"
$MachineDefault = Join-Path $env:ProgramW6432 "$Suite\$AppName\"
$UserA = Join-Path $env:LOCALAPPDATA "$AppName Test A\"
$UserB = Join-Path $env:LOCALAPPDATA "$AppName Test B\"
$MachineChosen = Join-Path "$env:SystemDrive\" "$AppName Test M\"
$U = @('ALLUSERS=2', 'MSIINSTALLPERUSER=1')
$M = @('ALLUSERS=1')
function Folder([string] $Path) { "INSTALLFOLDER=`"$Path`"" }
# Each step runs one package with properties. A step with RefusedBy must exit 1603 through the launch
# condition that tests that property and leave the state as it was.
function Step([string] $Msi, [string[]] $Properties, [string] $Package, [string] $Scope, [string] $Folder, [string] $RefusedBy = '', [string[]] $Gone = @()) {
  return @{ Msi = $Msi; Properties = $Properties; Package = $Package; Scope = $Scope; Folder = $Folder; RefusedBy = $RefusedBy; Gone = $Gone; RunAs = 'runner' }
}
$Cases = @(
  @{ Id = 'user-chosen-folder'; Rows = '1'; Steps = @(
      Step current ($U + (Folder $UserA)) current user $UserA) }
  @{ Id = 'machine-default-folder'; Rows = '2'; Steps = @(
      Step current $M current machine $MachineDefault) }
  @{ Id = 'machine-chosen-folder'; Rows = '3'; Steps = @(
      Step current ($M + (Folder $MachineChosen)) current machine $MachineChosen) }
  @{ Id = 'user-upgrade-keeps-folder'; Rows = '4'; Steps = @(
      (Step previous ($U + (Folder $UserA)) previous user $UserA),
      (Step current $U current user $UserA)) }
  @{ Id = 'machine-upgrade-keeps-folder'; Rows = '4'; Steps = @(
      (Step previous ($M + (Folder $MachineChosen)) previous machine $MachineChosen),
      (Step current $M current machine $MachineChosen)) }
  @{ Id = 'user-upgrade-moves-folder'; Rows = '5'; Steps = @(
      (Step previous ($U + (Folder $UserA)) previous user $UserA),
      (Step current ($U + (Folder $UserB)) current user $UserB -Gone $UserA)) }
  @{ Id = 'refused-over-machine'; Rows = '6, 7'; Steps = @(
      (Step previous $M previous machine $MachineDefault),
      (Step current @() previous machine $MachineDefault -RefusedBy CRAFT_MACHINE_DIR),
      (Step current $U previous machine $MachineDefault -RefusedBy CRAFT_MACHINE_DIR)) }
  @{ Id = 'refused-machine-over-user'; Rows = '8'; Steps = @(
      (Step previous $U previous user $UserDefault),
      (Step current $M previous user $UserDefault -RefusedBy CRAFT_USER_DIR)) }
)
$unknown = @($Only | Where-Object { $_ -notin @($Cases | ForEach-Object { $_.Id }) })
if ($unknown.Count) { throw "Unknown case in -Only: $($unknown -join ', ')." }

# ---------------------------------------------------------------- run
Assert-Clean 'clean start' @($UserDefault, $MachineDefault, $UserA, $UserB, $MachineChosen)
$ran = 0
foreach ($case in $Cases) {
  if ($Only.Count -and $Only -notcontains $case.Id) { continue }
  $ran++
  Note "---- $($case.Id) (#5739 rows $($case.Rows))"
  $folders = New-Object System.Collections.Generic.List[string]
  try {
    $n = 0
    foreach ($s in $case.Steps) {
      $n++
      $tag = "$($case.Id) step $n"
      $folders.Add($s.Folder)
      $result = Invoke-Step $tag $Packages[$s.Msi] $s.Properties $s.RunAs
      if ($s.RefusedBy) { Assert-Refused $tag $result $Packages[$s.Msi] $s.RefusedBy } else { Check "$tag`: exit code" $result.Code 0 }
      Assert-Installed $tag $Packages[$s.Package] $s.Scope $s.Folder
      foreach ($g in $s.Gone) { Check "$tag`: old folder removed ($g)" (Test-Path -LiteralPath $g) $false }
    }
  } catch {
    Add-Failure "$($case.Id) threw: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())"
  } finally {
    Remove-All "$($case.Id) uninstall"
    Assert-Clean "$($case.Id) uninstall" $folders.ToArray()
  }
}
if ($ran -eq 0) { Add-Failure 'No case ran.' }
Note "DONE: $ran cases, $script:Pass checks passed, $script:Fail failed"
if ($script:Fail -gt 0) { exit 1 }
