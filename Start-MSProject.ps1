# Requires: Windows PowerShell 5+ (or PowerShell 7) on Windows 10/11
# Usage: .\msproject.ps1
# This script reads applications from app.txt and runs Invoke-SingleUFO.ps1 for each one
# In parallel with scripts/getProcess.py, which is stopped when Invoke-SingleUFO.ps1 completes

# Set console output encoding to UTF-8 to handle Unicode characters (emojis, etc.)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# Set console code page to UTF-8 (65001) to allow Windows console to display Unicode
try {
    chcp 65001 | Out-Null
} catch {
    # If chcp fails, continue anyway
}

# ---- config / inputs ---------------------------------------------------------
$appsFile = "app.txt"     # one app name per line (Store name)

# ---- helper functions --------------------------------------------------------
function Write-Info($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [INFO ] $msg" -ForegroundColor Cyan
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
        Write-Warn "Get-AllProcessIds failed: $($_.Exception.Message)"
    }
    return ($pids | Sort-Object -Unique)
}

function Write-Warn($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Warning "[$timestamp] [WARN ] $msg"
}

function Write-Error($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Error "[$timestamp] [ERROR] $msg"
}

# ---- read applications from file ----------------------------------------------
if (-not (Test-Path $appsFile)) { 
    Write-Error "Missing apps file: $appsFile"
    exit 1
}

$apps = Get-Content $appsFile | Where-Object { $_.Trim() -ne '' }

if ($apps.Count -eq 0) {
    Write-Warn "No applications found in $appsFile"
    exit 0
}

# Resolve script directory to find scripts folder
$baseDir = if ($PSCommandPath) {
    Split-Path -Parent $PSCommandPath
} else {
    (Get-Location).Path
}

$scriptsDir = Join-Path $baseDir "scripts"
$singleRunScript = Join-Path $scriptsDir "Invoke-SingleUFO.ps1"
$processCaptureScript = Join-Path $scriptsDir "getProcess.py"

if (-not (Test-Path -LiteralPath $singleRunScript)) {
    Write-Error "Invoke-SingleUFO.ps1 not found at: $singleRunScript"
    exit 1
}

if (-not (Test-Path -LiteralPath $processCaptureScript)) {
    Write-Error "getProcess.py not found at: $processCaptureScript"
    exit 1
}

# ---- main loop ----------------------------------------------------------------
$failures = @()
$totalApps = $apps.Count
$currentApp = 0

Write-Info "Starting batch run for $totalApps application(s)"

foreach ($rawApp in $apps) {
    $currentApp++
    $storeName = $rawApp.Trim()
    
    if (-not $storeName) { 
        Write-Warn "Skipping empty application name"
        continue 
    }

    Write-Info "========================================="
    Write-Info "Processing application $currentApp of $totalApps : '$storeName'"
    Write-Info "========================================="

    # Capture baseline process IDs before launching any processes
    Write-Info "Capturing baseline process IDs..."
    $baselinePids = Get-AllProcessIds
    Write-Info "Captured baseline: $($baselinePids.Count) processes"
    
    # Sleep 1 second as requested
    Write-Info "Waiting 1 second before starting parallel execution..."
    Start-Sleep -Seconds 1

    $processCaptureProc = $null
    
    try {
        # Convert baseline PIDs array to comma-separated string for passing as argument
        $baselinePidsString = $baselinePids -join ','
        
        # Start getProcess.py as a background process with baseline PIDs excluded
        Write-Info "Starting getProcess.py for '$storeName' in background..."
        $processCaptureArgs = @("`"$processCaptureScript`"", "--app-name", "`"$storeName`"", "--exclude-pids", "`"$baselinePidsString`"")
        $processCaptureProc = Start-Process -FilePath "python.exe" `
            -ArgumentList $processCaptureArgs `
            -PassThru `
            -WindowStyle Hidden `
            -WorkingDirectory $scriptsDir
        
        if (-not $processCaptureProc) {
            Write-Warn "Failed to start getProcess.py for '$storeName'"
        } else {
            Write-Info "getProcess.py started (PID: $($processCaptureProc.Id))"
            # Give it a moment to start up
            Start-Sleep -Milliseconds 500
        }
        
        # Run Invoke-SingleUFO.ps1 for this application (waits for completion) with baseline PIDs
        Write-Info "Running Invoke-SingleUFO.ps1 for '$storeName'..."
        & $singleRunScript -AppName $storeName -BaselinePids $baselinePids
        
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
            Write-Warn "Invoke-SingleUFO.ps1 exited with code $LASTEXITCODE for '$storeName'"
            $failures += $storeName
        } else {
            Write-Info "Successfully completed processing for '$storeName'"
        }
    } catch {
        Write-Error "Failed to run Invoke-SingleUFO.ps1 for '$storeName': $($_.Exception.Message)"
        $failures += $storeName
    } finally {
        # Stop getProcess.py when Invoke-SingleUFO.ps1 finishes
        if ($processCaptureProc -and -not $processCaptureProc.HasExited) {
            Write-Info "Stopping getProcess.py (PID: $($processCaptureProc.Id))..."
            try {
                Stop-Process -Id $processCaptureProc.Id -Force -ErrorAction Stop
                Write-Info "getProcess.py stopped successfully"
            } catch {
                Write-Warn "Failed to stop getProcess.py: $($_.Exception.Message)"
            }
        } elseif ($processCaptureProc -and $processCaptureProc.HasExited) {
            Write-Info "getProcess.py already exited"
        }
    }

    # Optional: Add a small delay between applications
    if ($currentApp -lt $totalApps) {
        Write-Info "Waiting 2 seconds before next application..."
        Start-Sleep -Seconds 2
    }
}

# ---- summary ------------------------------------------------------------------
Write-Info "========================================="
Write-Info "Batch run completed"
Write-Info "========================================="

if ($failures.Count -gt 0) {
    Write-Warn "The following applications failed: $($failures -join ', ')"
    exit 1
} else {
    Write-Host "All applications processed successfully." -ForegroundColor Green
    exit 0
}
