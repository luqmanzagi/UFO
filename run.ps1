# Requires: Windows PowerShell 5+ (or PowerShell 7) on Windows 10/11

# ---- config / inputs ---------------------------------------------------------
$appsFile = "app.txt"     # one app name per line (Store name)
$genericFile = "generic_time.txt"     # optional extra prompt text

# ---- helper: write info/error conveniently ----------------------------------
function Info($msg)  { Write-Host "[INFO ] $msg" -ForegroundColor Cyan }
function Warn($msg)  { Write-Warning $msg }
function Fail($msg)  { Write-Error $msg }

# ---- read files --------------------------------------------------------------
if (-not (Test-Path $appsFile)) { throw "Missing apps file: $appsFile" }
$apps = Get-Content $appsFile | Where-Object { $_.Trim() -ne '' }

$common = ""
if (Test-Path $genericFile) { $common = Get-Content $genericFile -Raw }

# Ensure .\rec exists next to this script
# Resolve script directory safely (no assignment to $PSScriptRoot)
$baseDir = if ($PSCommandPath) {
    Split-Path -Parent $PSCommandPath
} else {
    (Get-Location).Path
}

# Ensure .\rec exists under the script (or current) directory
$recDir = Join-Path $baseDir 'rec'
if (-not (Test-Path -LiteralPath $recDir)) {
    New-Item -ItemType Directory -Path $recDir -Force | Out-Null
}

# ---- helpers -----------------------------------------------------------------
function Normalize-Name([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return "" }
  $t = $s.ToLowerInvariant()
  $t = ($t -replace '[®™©]', '')
  $t = ($t -replace '[^a-z0-9\s]', ' ')
  $t = ($t -replace '\s+', ' ').Trim()
  return $t
}

function Generate-Aliases([string]$name) {
  $aliases = New-Object System.Collections.Generic.HashSet[string]
  if ([string]::IsNullOrWhiteSpace($name)) { return $aliases }

  $aliases.Add($name) | Out-Null

  # strip after colon / dash
  if ($name -match '^(.*?):') { $aliases.Add($Matches[1].Trim()) | Out-Null }
  if ($name -match '^(.*?)-') { $aliases.Add($Matches[1].Trim()) | Out-Null }

  # strip parentheses
  $aliases.Add(($name -replace '\(.*?\)', '').Trim()) | Out-Null

  # normalized originals
  $aliases.Add((Normalize-Name $name)) | Out-Null

  # IMPORTANT: create a snapshot before adding more while iterating
  $snapshot = @()
  foreach ($it in $aliases) { $snapshot += $it }

  foreach ($a in $snapshot) {
    $aliases.Add((Normalize-Name $a)) | Out-Null
  }

  # common shortener for "X: subtitle"
  if ($name -match '^(.+?):\s') {
    $aliases.Add($Matches[1]) | Out-Null
    $aliases.Add((Normalize-Name $Matches[1])) | Out-Null
  }

  return $aliases
}

function Find-InstalledAppName([string]$targetName) {
  $startApps = Get-StartApps | Where-Object { $_.Name }
  $index = @{}
  foreach ($sa in $startApps) {
    $norm = Normalize-Name $sa.Name
    if (-not $index.ContainsKey($norm)) { $index[$norm] = @() }
    $index[$norm] += ,$sa
  }

  $candidates = Generate-Aliases $targetName

  # exact normalized match
  foreach ($cand in $candidates) {
    $norm = Normalize-Name $cand
    if ($index.ContainsKey($norm)) {
      return ($index[$norm] | Select-Object -First 1)
    }
  }

  # fuzzy contains
  $allNorms = $index.Keys
  foreach ($cand in $candidates) {
    $normCand = Normalize-Name $cand
    if (-not $normCand) { continue }
    $hits = $allNorms | Where-Object { $_ -like "*$normCand*" -or $normCand -like "*$_*" }
    if ($hits) {
      $best = ($hits | Sort-Object Length -Descending | Select-Object -First 1)
      return ($index[$best] | Select-Object -First 1)
    }
  }

  return $null
}

function Start-UWPAppByName([string]$preferredName, [ref]$resolvedStartApp) {
  # Try to resolve Start menu app (object with .Name and .AppID)
  $sa = Find-InstalledAppName $preferredName
  if (-not $sa) { return $false }

  $resolvedStartApp.Value = $sa
  if ($sa.AppID) {
    try {
      # This reliably launches UWP/Store apps
      Start-Process "explorer.exe" "shell:appsFolder\$($sa.AppID)"
      Start-Sleep -Seconds 3
      return $true
    } catch {
      Write-Warning "AUMID launch failed for '$($sa.Name)': $($_.Exception.Message)"
    }
  }
  return $false
}

function Fallback-StartMenuLaunch([string]$text) {
  try {
    powershell -Command "$wshell = New-Object -ComObject wscript.shell; $wshell.SendKeys('^{ESC}'); Start-Sleep -m 900; $wshell.SendKeys('$text'); Start-Sleep -m 900; $wshell.SendKeys('{ENTER}')"
    Start-Sleep -Seconds 3
    return $true
  } catch {
    Write-Warning "Fallback launcher failed: $($_.Exception.Message)"
    return $false
  }
}
function Get-RelatedIdsFromPsList {
  param([Parameter(Mandatory)][string]$Pattern,[switch]$CaseSensitive)
  $idList = New-Object System.Collections.Generic.List[int]
  if (Test-Path -LiteralPath ".\helpers\pslist.exe") {
    $null = & .\helpers\pslist.exe -accepteula 2>$null
    $lines = & .\helpers\pslist.exe 2>$null
    if (-not $CaseSensitive) {
      $lines = $lines | Where-Object { $_ -match [regex]::Escape($Pattern) -or $_ -match [regex]::Escape($Pattern).ToLower() -or $_ -match [regex]::Escape($Pattern).ToUpper() }
    } else {
      $lines = $lines | Select-String -Pattern $Pattern | ForEach-Object { $_.ToString() }
    }
    foreach ($line in $lines) {
      $m = [regex]::Match($line, $PsListLineRegex)
      if ($m.Success) {
        $theId  = [int]$m.Groups[2].Value
        if (-not $idList.Contains($theId)) { $idList.Add($theId) }
      }
    }
  }
  return ,$idList.ToArray()
}

function Stop-IdsRobust { param([Parameter(Mandatory)][int[]]$Ids)
  if (-not $Ids -or $Ids.Count -eq 0) { return }
  $havePskill = Test-Path -LiteralPath ".\helpers\pskill.exe"
  if ($havePskill) { $null = & .\helpers\pskill.exe -accepteula 2>$null }
  foreach ($oneId in $Ids) {
    try {
      if ($havePskill) {
        Info "pskill -t $oneId"
        & .\helpers\pskill.exe -nobanner -t $oneId | Out-Null
        Start-Sleep -Milliseconds 150
        if (-not (Get-Process -Id $oneId -ErrorAction SilentlyContinue)) { continue }
      }
    } catch { Warn "pskill: $($_.Exception.Message)" }
    try {
      Info "taskkill /T /F /PID $oneId"
      & taskkill.exe /T /F /PID $oneId | Out-Null
      Start-Sleep -Milliseconds 150
      if (-not (Get-Process -Id $oneId -ErrorAction SilentlyContinue)) { continue }
    } catch { Warn "taskkill: $($_.Exception.Message)" }
    try {
      Info "Stop-Process -Id $oneId -Force"
      Stop-Process -Id $oneId -Force -ErrorAction Stop
      Start-Sleep -Milliseconds 150
    } catch { Warn "Stop-Process: $($_.Exception.Message)" }
  }
}

function Stop-AppProcesses { param([Parameter(Mandatory)][string]$DisplayName)
  $allIds = @()
  if (Test-Path -LiteralPath ".\helpers\pslist.exe") {
    $idsFromSys = Get-RelatedIdsFromPsList -Pattern $DisplayName
    if ($idsFromSys.Count -gt 0) { $allIds += $idsFromSys }
  } else { Warn "pslist.exe not found; using native fallback." }
  try {
    $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
      $_.Name -like "*$DisplayName*" -or $_.MainWindowTitle -like "*$DisplayName*"
    }
    foreach ($p in $procs) { if ($allIds -notcontains $p.Id) { $allIds += $p.Id } }
  } catch {}
  $allIds = $allIds | Sort-Object -Unique
  if ($allIds.Count -eq 0) { Info "No matching processes for '$DisplayName'."; return }
  Info "Terminating related Ids for '$DisplayName': $($allIds -join ', ')"
  Stop-IdsRobust -Ids $allIds
}

# ---- main --------------------------------------------------------------------
$failures = @()

foreach ($rawApp in $apps) {
  $storeName = $rawApp.Trim()
  if (-not $storeName) { continue }

  $resolved = $null
  $launched = Start-UWPAppByName $storeName ([ref]$resolved)

  $displayName = if ($resolved) { $resolved.Name } else { $storeName }

  if ($launched) {
    Write-Host "Resolved '$storeName' -> Start menu app '$($resolved.Name)'; launched via AUMID."
  } else {
    Write-Host "Could not AUMID-launch '$storeName'. Fallback to Start-menu keystrokes..."
    $aliasSet = Generate-Aliases $storeName
    # try a few best candidates (shortest first often matches Start search)
    foreach ($cand in ($aliasSet | Sort-Object Length)) {
      if (Fallback-StartMenuLaunch $cand) { $displayName = $cand; break }
    }
  }

  # Build UFO request; app should already be running now
  $request = @"
Launch (if not already) the app '$displayName' and then do:

$common
"@

  Write-Host "Starting UFO for: $displayName"
  # Important: pass a descriptive task AND the resolved name for search context
  python .\helpers\rec.py --grab gdigrab --cursor --out ".\rec\$($displayName -replace '[^a-zA-Z0-9]', '_').mp4"
  python -m ufo --task "$displayName" --request "$request"
  try { Stop-AppProcesses -DisplayName $displayName } catch { Warn "Stop-AppProcesses errored: $($_.Exception.Message)" }
  python .\helpers\end_rec.py

  # Optional: you could scan UFO logs here to verify it interacted with the app,
  # and add to $failures if not detected.
}

if ($failures.Count -gt 0) {
  Write-Warning "The following apps still failed: $($failures -join ', ')"
} else {
  Write-Host "All done."
}