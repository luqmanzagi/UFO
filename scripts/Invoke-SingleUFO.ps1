# Requires: Windows PowerShell 5+ (or PowerShell 7) on Windows 10/11
# Usage: .\Invoke-SingleUFO.ps1 "Application Name"

param(
    [Parameter(Mandatory=$true)]
    [string]$AppName,
    [Parameter(Mandatory=$false)]
    [int[]]$BaselinePids = @()
)

# Set console output encoding to UTF-8 to handle Unicode characters (emojis, etc.)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# Set console code page to UTF-8 (65001) to allow Windows console to display Unicode
try {
    chcp 65001 | Out-Null
} catch {
    # If chcp fails, continue anyway
}

# Set Python encoding to UTF-8 to handle Unicode characters in Python output
$env:PYTHONIOENCODING = "utf-8"

# ---- config / inputs ---------------------------------------------------------
# Resolve parent directory (where helpers, rec, netdump, etc. are located)
$scriptDir = if ($PSCommandPath) {
    Split-Path -Parent $PSCommandPath
} else {
    (Get-Location).Path
}
$parentDir = Split-Path -Parent $scriptDir
$genericFile = Join-Path $parentDir "generic_time_1m.txt"     # optional extra prompt text

# ---- helper: write info/error conveniently ----------------------------------
# Global log file stream (will be set in main loop)
$script:LogFileStream = $null

function Info($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMsg = "[$timestamp] [INFO ] $msg"
    Write-Host "[INFO ] $msg" -ForegroundColor Cyan
    if ($script:LogFileStream) {
        $script:LogFileStream.WriteLine($logMsg)
        $script:LogFileStream.Flush()
    }
}

function Warn($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMsg = "[$timestamp] [WARN ] $msg"
    Write-Warning $msg
    if ($script:LogFileStream) {
        $script:LogFileStream.WriteLine($logMsg)
        $script:LogFileStream.Flush()
    }
}

function Fail($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMsg = "[$timestamp] [ERROR] $msg"
    Write-Error $msg
    if ($script:LogFileStream) {
        $script:LogFileStream.WriteLine($logMsg)
        $script:LogFileStream.Flush()
    }
}

# ---- read files --------------------------------------------------------------
$common = ""
if (Test-Path $genericFile) { $common = Get-Content $genericFile -Raw }

# Ensure .\results\screen_records exists in parent directory
$recDir = Join-Path $parentDir 'results\screen_records'
if (-not (Test-Path -LiteralPath $recDir)) {
    New-Item -ItemType Directory -Path $recDir -Force | Out-Null
}

# Ensure .\results\netdump exists in parent directory
$netdumpDir = Join-Path $parentDir 'results\netdump'
if (-not (Test-Path -LiteralPath $netdumpDir)) {
    New-Item -ItemType Directory -Path $netdumpDir -Force | Out-Null
}

# Ensure .\results\logs\terminal exists in parent directory
$logTerminalDir = Join-Path $parentDir 'results\logs\UFOterminal'
if (-not (Test-Path -LiteralPath $logTerminalDir)) {
    New-Item -ItemType Directory -Path $logTerminalDir -Force | Out-Null
}

# Ensure .\results\log\mitmdump exists in parent directory
$mitmLogDir = Join-Path $parentDir 'results\logs\mitmdump'
if (-not (Test-Path -LiteralPath $mitmLogDir)) {
    New-Item -ItemType Directory -Path $mitmLogDir -Force | Out-Null
}

# ---- helpers -----------------------------------------------------------------
function Set-NormalizeName([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return "" }
  $t = $s.ToLowerInvariant()
  $t = ($t -replace '[®™©]', '')
  $t = ($t -replace '[^a-z0-9\s]', ' ')
  $t = ($t -replace '\s+', ' ').Trim()
  return $t
}

function Get-Aliases([string]$name) {
  $aliases = New-Object System.Collections.Generic.HashSet[string]
  if ([string]::IsNullOrWhiteSpace($name)) { return $aliases }

  $aliases.Add($name) | Out-Null

  # strip after colon / dash
  if ($name -match '^(.*?):') { $aliases.Add($Matches[1].Trim()) | Out-Null }
  if ($name -match '^(.*?)-') { $aliases.Add($Matches[1].Trim()) | Out-Null }

  # strip parentheses
  $aliases.Add(($name -replace '\(.*?\)', '').Trim()) | Out-Null

  # normalized originals
  $aliases.Add((Set-NormalizeName $name)) | Out-Null

  # IMPORTANT: create a snapshot before adding more while iterating
  $snapshot = @()
  foreach ($it in $aliases) { $snapshot += $it }

  foreach ($a in $snapshot) {
    $aliases.Add((Set-NormalizeName $a)) | Out-Null
  }

  # common shortener for "X: subtitle"
  if ($name -match '^(.+?):\s') {
    $aliases.Add($Matches[1]) | Out-Null
    $aliases.Add((Set-NormalizeName $Matches[1])) | Out-Null
  }

  return $aliases
}

function Find-InstalledAppName([string]$targetName) {
  $startApps = Get-StartApps | Where-Object { $_.Name }
  $index = @{}
  foreach ($sa in $startApps) {
    $norm = Set-NormalizeName $sa.Name
    if (-not $norm) { continue }
    if (-not $index.ContainsKey($norm)) { $index[$norm] = @() }
    $index[$norm] += ,$sa
  }

  $candidates = Get-Aliases $targetName

  # 1) exact normalized match
  foreach ($cand in $candidates) {
    $norm = Set-NormalizeName $cand
    if ($norm -and $index.ContainsKey($norm)) {
      return ($index[$norm] | Select-Object -First 1)
    }
  }

  # 2) fuzzy "contains" match (your original behavior)
  $allNorms = $index.Keys
  foreach ($cand in $candidates) {
    $normCand = Set-NormalizeName $cand
    if (-not $normCand) { continue }
    $hits = $allNorms | Where-Object { $_ -like "*$normCand*" -or $normCand -like "*$_*" }
    if ($hits) {
      $best = ($hits | Sort-Object Length -Descending | Select-Object -First 1)
      return ($index[$best] | Select-Object -First 1)
    }
  }

  # 3) NEW: word-overlap fallback to handle Store vs Start name differences
  $normTarget = Set-NormalizeName $targetName
  if ($normTarget -and $allNorms) {
    $targetTokens = $normTarget -split ' '
    $targetTokens = $targetTokens | Where-Object { $_ }  # drop empties
    if ($targetTokens.Count -gt 0) {
      $firstToken = $targetTokens[0]

      $bestKey   = $null
      $bestScore = 0

      foreach ($normName in $allNorms) {
        $appTokens = ($normName -split ' ') | Where-Object { $_ }
        if (-not $appTokens) { continue }

        # intersection of tokens
        $intersection = $appTokens | Where-Object { $targetTokens -contains $_ }
        $score = $intersection.Count

        # small bonus if the "brand" (first token) matches
        if ($firstToken -and ($intersection -contains $firstToken)) {
          $score++
        }

        if ($score -gt $bestScore) {
          $bestScore = $score
          $bestKey   = $normName
        }
      }

      # require at least 2 shared tokens to avoid silly matches
      if ($bestKey -and $bestScore -ge 2) {
        return ($index[$bestKey] | Select-Object -First 1)
      }
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
      Warn "AUMID launch failed for '$($sa.Name)': $($_.Exception.Message)"
    }
  }
  return $false
}

function Invoke-FallbackStartMenuLaunch([string]$text) {
  try {
    powershell -Command "$wshell = New-Object -ComObject wscript.shell; $wshell.SendKeys('^{ESC}'); Start-Sleep -m 900; $wshell.SendKeys('$text'); Start-Sleep -m 900; $wshell.SendKeys('{ENTER}')"
    Start-Sleep -Seconds 3
    return $true
  } catch {
    Warn "Fallback launcher failed: $($_.Exception.Message)"
    return $false
  }
}
function Get-RelatedIdsFromPsList {
    <#
      .SYNOPSIS
        Returns related process IDs for a target app, parsed from helpers\pslist.exe (if present)
        with strong guards to avoid adding PID 0.

      .PARAMETER Target
        A string to match against the process name / window title (case-insensitive).

      .PARAMETER PsListPath
        Path to pslist.exe. If not found, falls back to Get-Process.

      .OUTPUTS
        [int[]] distinct, > 0
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$Target,
        [string]$PsListPath = ""
    )

    # Default to parent directory's helpers folder if not specified
    if ([string]::IsNullOrWhiteSpace($PsListPath)) {
        $scriptDir = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
        $parentDir = Split-Path -Parent $scriptDir
        $PsListPath = Join-Path $parentDir "helpers\pslist64.exe"
    }

    $pids = @()

    try {
        if (Test-Path -LiteralPath $PsListPath) {
            # pslist default output usually has lines like:
            # procname           pid   ...
            $raw = & $PsListPath | Out-String
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                foreach ($line in $raw -split "(`r`n|`n)") {
                    # Try to capture "name" and "pid" numbers; be liberal in spacing
                    if ($line -match '^\s*(?<name>[^\s]+)\s+(?<pid>\d+)\b') {
                        $name = $Matches['name']
                        $pidInt = 0
                        if ([int]::TryParse($Matches['pid'], [ref]$pidInt) -and $pidInt -gt 0) {
                            if ($name -like "*$Target*" -or $Target -like "*$name*") {
                                $pids += $pidInt
                            }
                        }
                    }
                }
            }
        } else {
            # Fallback: use built-in Get-Process and fuzzy match on process name / main window title
            $procs = Get-Process -ErrorAction SilentlyContinue
            foreach ($p in $procs) {
                $name = $p.ProcessName
                $title = $null
                try { $title = $p.MainWindowTitle } catch {}
                if ( ($name -and ($name -like "*$Target*")) -or ($title -and ($title -like "*$Target*")) ) {
                    if ($p.Id -gt 0) { $pids += [int]$p.Id }
                }
            }
        }
    } catch {
        Warn "Get-RelatedIdsFromPsList failed: $($_.Exception.Message)"
    }

    # Final guardrails: remove 0/negatives, dedupe, sort
    $pids = $pids | Where-Object { $_ -is [int] -and $_ -gt 0 } | Sort-Object -Unique
    return ,$pids
}

function Stop-IdsRobust {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][object[]]$Ids,
        [string]$AppName = "",
        [string]$PsKillPath = "",
        [switch]$Tree
    )

    # Sanitize input -> integers > 0
    $pidList = @()
    foreach ($i in $Ids) {
        if ($null -ne $i) {
            $s = "$i".Trim()
            if ($s -match '^\d+$') {
                $v = [int]$s
                if ($v -gt 0) { $pidList += $v }
            }
        }
    }
    $pidList = $pidList | Sort-Object -Unique

    if (-not $pidList -or $pidList.Count -eq 0) {
        Warn "No related PIDs found to terminate for '$AppName'."
        return
    }

    # Default to parent directory's helpers folder if not specified
    if ([string]::IsNullOrWhiteSpace($PsKillPath)) {
        $scriptDir = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
        $parentDir = Split-Path -Parent $scriptDir
        $PsKillPath = Join-Path $parentDir "helpers\pskill64.exe"
    }

    try {
        if (Test-Path -LiteralPath $PsKillPath) {
            $args = @()
            if ($Tree.IsPresent) { $args += '-t' }
            $args += $pidList | ForEach-Object { "$_" }

            Info "$([IO.Path]::GetFileName($PsKillPath)) $($args -join ' ')"
            $p = Start-Process -FilePath $PsKillPath -ArgumentList $args -NoNewWindow -PassThru -Wait -ErrorAction Stop
            if ($p.ExitCode -ne 0) {
                Warn "pskill exited with code $($p.ExitCode). Falling back to Stop-Process."
                foreach ($single_pid in $pidList) {
                    try { Stop-Process -Id $single_pid -Force -ErrorAction Stop } catch { Warn "Stop-Process($single_pid): $($_.Exception.Message)" }
                    Info "Stopped process Id $single_pid for '$AppName'."
                }
            }
        } else {
            foreach ($single_pid in $pidList) {
                try { Stop-Process -Id $single_pid -Force -ErrorAction Stop } catch { Warn "Stop-Process($single_pid): $($_.Exception.Message)" }
                Info "Stopped process Id $single_pid for '$AppName'."
            }
        }
    } catch {
        Fail " Stop-IdsRobust failed: $($_.Exception.Message)"
    }
}


function Get-AllProcessIds {
  <#
    .SYNOPSIS
      Returns all current process IDs as an array of integers.
  #>
  $pids = @()
  try {
    $procs = Get-Process -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
      if ($p.Id -gt 0) {
        $pids += [int]$p.Id
      }
    }
  } catch {
    Warn "Get-AllProcessIds failed: $($_.Exception.Message)"
  }
  return ($pids | Sort-Object -Unique)
}

function Stop-NewProcesses {
  <#
    .SYNOPSIS
      Stops processes that were created after a baseline snapshot.
    .PARAMETER BaselinePids
      Array of process IDs that existed before the operation.
    .PARAMETER ExcludePids
      Array of process IDs to exclude from termination (e.g., our own tools).
    .PARAMETER AppName
      Name of the app for logging purposes.
  #>
  param(
    [Parameter(Mandatory=$true)]
    [int[]]$BaselinePids,
    [int[]]$ExcludePids = @(),
    [string]$AppName = ""
  )
  
  try {
    $currentPids = Get-AllProcessIds
    $newPids = $currentPids | Where-Object { $BaselinePids -notcontains $_ }
    
    # Exclude specified PIDs (like mitmdump, our own scripts, etc.)
    if ($ExcludePids.Count -gt 0) {
      $newPids = $newPids | Where-Object { $ExcludePids -notcontains $_ }
    }
    
    # Also exclude system processes and our own PowerShell/python processes
    $excludeNames = @("powershell", "pwsh", "python", "mitmdump", "ffmpeg", "gdigrab")
    $finalPids = @()
    foreach ($processId in $newPids) {
      try {
        $proc = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($proc -and $excludeNames -notcontains $proc.ProcessName.ToLower()) {
          $finalPids += $processId
        }
      } catch {
        # Process may have already exited, skip it
      }
    }
    
    $finalPids = $finalPids | Sort-Object -Unique
    
    if ($finalPids.Count -eq 0) {
      Info "No new processes to terminate for '$AppName'."
      return
    }
    
    Info "Terminating new process IDs for '$AppName': $($finalPids -join ', ')"
    Stop-IdsRobust -Ids $finalPids -AppName $AppName
  } catch {
    Warn "Stop-NewProcesses failed: $($_.Exception.Message)"
  }
}

function Stop-AppProcesses { param([Parameter(Mandatory)][string]$DisplayName)
  $scriptDir = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
  $parentDir = Split-Path -Parent $scriptDir
  $pslistPath = Join-Path $parentDir "helpers\pslist64.exe"
  $allIds = @()
  if (Test-Path -LiteralPath $pslistPath) {
    $idsFromSys = Get-RelatedIdsFromPsList -Target $DisplayName -PsListPath $pslistPath
    if ($idsFromSys.Count -gt 0) { $allIds += $idsFromSys }
  } else { Fail "pslist64.exe not found; using native fallback." }
  try {
    $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
      $_.Name -like "*$DisplayName*" -or $_.MainWindowTitle -like "*$DisplayName*"
    }
    foreach ($p in $procs) { if ($allIds -notcontains $p.Id) { $allIds += $p.Id } }
  } catch {}
  $allIds = $allIds | Sort-Object -Unique
  if ($allIds.Count -eq 0) { Info "No matching processes for '$DisplayName'."; return }
  Info "Terminating related Ids for '$DisplayName': $($allIds -join ', ')"
  Stop-IdsRobust -Ids $allIds -AppName $DisplayName
}

$mitmCA = "$env:USERPROFILE\.mitmproxy\mitmproxy-ca-cert.pem"
$env:SSL_CERT_FILE = $mitmCA
$env:REQUESTS_CA_BUNDLE = $mitmCA

# --- helpers: start/stop mitmdump as a background process
function Start-Mitmdump {
    param(
        [string]$OutFile,
        [string]$Mode = "local",      # or "regular"
        [string[]]$IgnoreHosts = @(),
        [string]$LogFile = ""
    )

    if (-not (Get-Command mitmdump -ErrorAction SilentlyContinue)) {
        throw "mitmdump not found on PATH."
    }

    $args = @("--mode", $Mode, "-w", $OutFile)

    foreach ($pat in $IgnoreHosts) {
        $args += @("--ignore-hosts", $pat)  # <-- repeat flag per pattern
    }

    $quotedArgs = $args | ForEach-Object {
      if ($_ -match '\s') { '"' + ($_ -replace '"','""') + '"' } else { $_ }
    }
    $argString = $quotedArgs -join ' '

    Info ("Start-Process mitmdump " + $argString)
    
    $startParams = @{
        FilePath     = "mitmdump"
        ArgumentList = $argString   # single string to preserve quoting on PS5
        WindowStyle  = 'Hidden'
        PassThru     = $true
    }

    if ($LogFile) {
        # capture stdout/stderr; they must be different files for Start-Process
        $outPath = $LogFile
        $errPath = [IO.Path]::ChangeExtension($LogFile, ".err.log")
        $startParams.RedirectStandardError  = $errPath
        $startParams.RedirectStandardOutput = $outPath
    }

    Start-Process @startParams
}


function Stop-Mitmdump {
    param([Parameter(Mandatory)]$Process)
    if ($Process -and -not $Process.HasExited) {
        Stop-Process -Id $Process.Id -Force
        # tiny wait to ensure file is flushed
        Start-Sleep -Milliseconds 250
    }
}

# function Enable-SystemProxy {
#     param([string]$Endpoint = "127.0.0.1:8080")
#     try {
#         netsh winhttp set proxy $Endpoint | Out-Null
#         Info "WinHTTP proxy set to $Endpoint"
#     } catch {
#         Warn "Couldn't set WinHTTP proxy: $($_.Exception.Message)"
#     }
# }
# function Disable-SystemProxy {
#     try {
#         netsh winhttp reset proxy | Out-Null
#         Info "WinHTTP proxy reset"
#     } catch {
#         Warn "Couldn't reset WinHTTP proxy: $($_.Exception.Message)"
#     }
# }

# ---- main --------------------------------------------------------------------
$storeName = $AppName.Trim()
if (-not $storeName) { 
    Fail "Application name cannot be empty."
    exit 1
}

# Use provided baseline PIDs, or capture them if not provided
if ($BaselinePids.Count -eq 0) {
    # Capture baseline process IDs before launching the app (backward compatibility)
    $baselinePids = Get-AllProcessIds
} else {
    $baselinePids = $BaselinePids
}

$resolved = $null
$launched = Start-UWPAppByName $storeName ([ref]$resolved)
$displayName = if ($resolved) { $resolved.Name } else { $storeName }

if ($launched) {
  # Info will be logged after log file is created
} else {
  # Info will be logged after log file is created
  $aliasSet = Get-Aliases $storeName
  # try a few best candidates (shortest first often matches Start search)
  foreach ($cand in ($aliasSet | Sort-Object Length)) {
    if (Invoke-FallbackStartMenuLaunch $cand) { $displayName = $cand; break }
  }
}

# Setup log file (after final displayName is determined)
$logFileName = "$($displayName -replace '[^a-zA-Z0-9]', '_').log"
$logFilePath = Join-Path $logTerminalDir $logFileName

# Open log file stream with UTF-8 encoding to handle Unicode characters (emojis, etc.)
try {
  $utf8NoBom = New-Object System.Text.UTF8Encoding $false
  $script:LogFileStream = [System.IO.StreamWriter]::new($logFilePath, $true, $utf8NoBom)
  $script:LogFileStream.AutoFlush = $true
  Info "Log file: $logFilePath"
} catch {
  Write-Warning "Failed to create log file: $($_.Exception.Message)"
  $script:LogFileStream = $null
}

try {
  # Enable-SystemProxy "127.0.0.1:8080"
  try {
  # Log the baseline capture and launch status now that log file is open
  Info "Captured baseline process IDs: $($baselinePids.Count) processes running before app launch"
  if ($launched) {
    Info "Resolved '$storeName' -> Start menu app '$($resolved.Name)'; launched via AUMID."
  } else {
    Warn "Could not AUMID-launch '$storeName'. Used fallback to Start-menu keystrokes."
  }

  $helpersRecPath = Join-Path $parentDir "helpers\rec.py"
  $recOutPath = Join-Path $recDir "$($storeName -replace '[^a-zA-Z0-9]', '_').mp4"
  python $helpersRecPath --grab gdigrab --cursor --out $recOutPath 2>&1 | ForEach-Object {
    Write-Host $_
    if ($script:LogFileStream) {
      try {
        $logLine = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " " + $_
        $script:LogFileStream.WriteLine($logLine)
        $script:LogFileStream.Flush()
      } catch {
        # If encoding fails, try to write a sanitized version
        try {
          $sanitized = $_ -replace '[^\x00-\x7F]', '?'
          $script:LogFileStream.WriteLine((Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " " + $sanitized)
          $script:LogFileStream.Flush()
        } catch {
          # If even sanitized version fails, skip logging this line
        }
      }
    }
  }
  
  $dumpFile = Join-Path $netdumpDir "$($storeName -replace '[^a-zA-Z0-9]', '_').mitm"
  $mitmLogPath = Join-Path $mitmLogDir "$($storeName -replace '[^a-zA-Z0-9]', '_').mitmdump.log"
  if (Test-Path -LiteralPath $mitmLogPath) { Remove-Item -LiteralPath $mitmLogPath -Force -ErrorAction SilentlyContinue }
  $mitmProc = Start-Mitmdump -OutFile $dumpFile -Mode local -IgnoreHosts @(
    '(^|\.)generativelanguage\.googleapis\.com$', '(^|\.)gradio\.live$'
    # '^127\.0\.0\.1:7861$'
  ) -LogFile $mitmLogPath
  if ($mitmProc) {
    Info "mitmdump PID $($mitmProc.Id) writing to $dumpFile"
  } else {
    Fail "mitmdump failed to start; no process object returned."
  }
  # quick check for immediate crash (e.g., port in use); surface recent log lines
  Start-Sleep -Milliseconds 500
  if ($mitmProc -and $mitmProc.HasExited) {
    $code = $mitmProc.ExitCode
    Warn "mitmdump exited immediately with code $code"
    if (Test-Path -LiteralPath $mitmLogPath) {
      $tail = Get-Content -LiteralPath $mitmLogPath -Tail 20 -ErrorAction SilentlyContinue
      foreach ($line in $tail) { Warn "mitmdump: $line" }
    }
  }

  # Build UFO request; app should already be running now
  $request = @"
Bring the '$displayName' app to the front and then do:

$common
"@

  $startTime = Get-Date
  Info ("Starting UFO for: {0} on {1}" -f$displayName, $startTime.ToString("yyyy-MM-dd HH:mm:ss"))

  # Start-Sleep -Seconds 60
  
  # Change to parent directory to ensure python -m ufo runs from project root
  # (needed for config files and logs to resolve correctly)
  Push-Location $parentDir
  try {
    python -m ufo --task "$($displayName -replace ':', '')" --request "$request" 2>&1 | ForEach-Object {
      Write-Host $_
      if ($script:LogFileStream) {
        try {
          $logLine = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " " + $_
          $script:LogFileStream.WriteLine($logLine)
          $script:LogFileStream.Flush()
        } catch {
          # If encoding fails, try to write a sanitized version
          try {
            $sanitized = $_ -replace '[^\x00-\x7F]', '?'
            $script:LogFileStream.WriteLine((Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " " + $sanitized)
            $script:LogFileStream.Flush()
          } catch {
            # If even sanitized version fails, skip logging this line
          }
        }
      }
    }
  } finally {
    Pop-Location
  }
  
  # Stop new processes that appeared after baseline (excluding our own tools)
  $excludePids = @()
  try {
    # Exclude mitmdump process
    if ($mitmProc -and -not $mitmProc.HasExited) {
      $excludePids += $mitmProc.Id
    }
    # Exclude current PowerShell process
    $excludePids += $PID
    # Exclude Python processes (rec.py, ufo, end_rec.py)
    $pythonProcs = Get-Process python -ErrorAction SilentlyContinue
    foreach ($p in $pythonProcs) {
      $excludePids += $p.Id
    }
  } catch {
    Warn "Failed to get exclude PIDs: $($_.Exception.Message)"
  }
  
  try {
    Stop-NewProcesses -BaselinePids $baselinePids -ExcludePids $excludePids -AppName $displayName
  } catch {
    Warn "Stop-NewProcesses errored: $($_.Exception.Message)"
    # Fallback to old method if new method fails
    try { Stop-AppProcesses -DisplayName $displayName } catch { Warn "Stop-AppProcesses errored: $($_.Exception.Message)" }
  }
  Stop-Mitmdump -Process $mitmProc
  if (Test-Path -LiteralPath $dumpFile) {
    $dumpSize = (Get-Item -LiteralPath $dumpFile).Length
    Info "Mitmdump stopped; output saved to $dumpFile (size: $dumpSize bytes)"
  } else {
    Warn "Mitmdump output file not found at $dumpFile"
  }
  $endTime = Get-Date
  $elapsed = New-TimeSpan -Start $startTime -End $endTime
  Info ("Finished UFO for: {0} at {1} (elapsed {2})" -f $displayName, $endTime.ToString("yyyy-MM-dd HH:mm:ss"), $elapsed.ToString("hh\:mm\:ss"))
  
  $helpersEndRecPath = Join-Path $parentDir "helpers\end_rec.py"
  python $helpersEndRecPath 2>&1 | ForEach-Object {
    Write-Host $_
    if ($script:LogFileStream) {
      try {
        $logLine = (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " " + $_
        $script:LogFileStream.WriteLine($logLine)
        $script:LogFileStream.Flush()
      } catch {
        # If encoding fails, try to write a sanitized version
        try {
          $sanitized = $_ -replace '[^\x00-\x7F]', '?'
          $script:LogFileStream.WriteLine((Get-Date -Format "yyyy-MM-dd HH:mm:ss") + " " + $sanitized)
          $script:LogFileStream.Flush()
        } catch {
          # If even sanitized version fails, skip logging this line
        }
      }
    }
  }
  } finally {
    # Disable-SystemProxy
  }
} finally {
  # Close log file stream for this app
  if ($script:LogFileStream) {
    $script:LogFileStream.Close()
    $script:LogFileStream = $null
    Write-Host "Log saved to: $logFilePath" -ForegroundColor Green
  }
}

Write-Host "All done." -ForegroundColor Green


