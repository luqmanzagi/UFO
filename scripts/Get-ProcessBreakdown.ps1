# Requires: Windows PowerShell 5+ (or PowerShell 7) on Windows 10/11
# Usage: .\Get-ProcessBreakdown.ps1 <ApplicationName> [-BaselinePid <PID>] [-WaitSeconds <seconds>]
#
# Monitors new processes created after a baseline snapshot and tracks their network connections.
# Outputs process information with network connection details to a CSV file in real-time.

param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$ApplicationName,
    [Parameter(Mandatory=$false)]
    [int]$BaselinePid = -1,
    [Parameter(Mandatory=$false)]
    [string]$BaselinePids = "",
    [Parameter(Mandatory=$false)]
    [int]$WaitSeconds = 10
)

# Set console output encoding to UTF-8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ---- helper functions --------------------------------------------------------
function Write-Info($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [INFO ] $msg" -ForegroundColor Cyan
}

function Write-Warn($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Warning "[$timestamp] [WARN ] $msg"
}

function Write-Error($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Error "[$timestamp] [ERROR] $msg"
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

function Get-ProcessNetworkConnections {
    <#
        .SYNOPSIS
        Gets network connections for a specific process ID.
        
        .PARAMETER ProcessId
        The process ID to get connections for.
        
        .OUTPUTS
        Array of connection objects with LocalAddress, LocalPort, RemoteAddress, RemotePort
    #>
    param(
        [Parameter(Mandatory=$true)]
        [int]$ProcessId
    )
    
    $connections = @()
    
    try {
        # Get TCP connections for this process
        $tcpConnections = Get-NetTCPConnection -OwningProcess $ProcessId -ErrorAction SilentlyContinue
        
        foreach ($conn in $tcpConnections) {
            $connection = [PSCustomObject]@{
                LocalAddress = $conn.LocalAddress
                LocalPort = $conn.LocalPort
                RemoteAddress = $conn.RemoteAddress
                RemotePort = $conn.RemotePort
                State = $conn.State
            }
            $connections += $connection
        }
        
        # Get UDP connections for this process (UDP doesn't have remote connections, but we track local)
        $udpConnections = Get-NetUDPEndpoint -OwningProcess $ProcessId -ErrorAction SilentlyContinue
        
        foreach ($conn in $udpConnections) {
            $connection = [PSCustomObject]@{
                LocalAddress = $conn.LocalAddress
                LocalPort = $conn.LocalPort
                RemoteAddress = ""
                RemotePort = ""
                State = "UDP"
            }
            $connections += $connection
        }
        
    } catch {
        Write-Warn "Failed to get network connections for PID $ProcessId : $($_.Exception.Message)"
    }
    
    return $connections
}

function Export-ProcessInfoToCsv {
    <#
        .SYNOPSIS
        Exports process information to CSV file, appending if file exists.
        
        .PARAMETER ProcessInfo
        Process information object to export.
        
        .PARAMETER CsvPath
        Path to CSV file.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$ProcessInfo,
        [Parameter(Mandatory=$true)]
        [string]$CsvPath
    )
    
    try {
        # Check if file exists to determine if we need headers
        $fileExists = Test-Path -LiteralPath $CsvPath
        
        if (-not $fileExists) {
            # Create file with headers
            $ProcessInfo | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
        } else {
            # Append to existing file
            $ProcessInfo | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8 -Append
        }
    } catch {
        Write-Warn "Failed to write to CSV: $($_.Exception.Message)"
    }
}

# ---- main --------------------------------------------------------------------

Write-Info "Starting process breakdown monitoring..."

# Capture baseline process IDs
if (-not [string]::IsNullOrWhiteSpace($BaselinePids)) {
    # If BaselinePids string is provided, parse it as comma-separated values
    try {
        $baselinePids = $BaselinePids -split ',' | ForEach-Object { [int]::Parse($_.Trim()) } | Where-Object { $_ -gt 0 } | Sort-Object -Unique
        Write-Info "Using provided baseline PIDs: $($baselinePids.Count) processes"
    } catch {
        Write-Error "Failed to parse BaselinePids parameter. Using all current processes as baseline."
        $baselinePids = Get-AllProcessIds
    }
} elseif ($BaselinePid -gt 0) {
    # If a specific PID is provided, check if it exists and capture all PIDs except it
    try {
        $baselineProc = Get-Process -Id $BaselinePid -ErrorAction Stop
        Write-Info "Using PID $BaselinePid ($($baselineProc.ProcessName)) as baseline reference"
        $baselinePids = Get-AllProcessIds | Where-Object { $_ -ne $BaselinePid }
    } catch {
        Write-Error "Baseline PID $BaselinePid not found. Using all current processes as baseline."
        $baselinePids = Get-AllProcessIds
    }
} else {
    # Capture all current processes as baseline
    $baselinePids = Get-AllProcessIds
}

Write-Info "Captured baseline: $($baselinePids.Count) processes"

# Wait for specified duration
Write-Info "Waiting $WaitSeconds seconds for new processes to start..."
Start-Sleep -Seconds $WaitSeconds

# Get current process IDs
$currentPids = Get-AllProcessIds
$newPids = $currentPids | Where-Object { $baselinePids -notcontains $_ }

if ($newPids.Count -eq 0) {
    Write-Warn "No new processes detected after waiting period."
    Write-Info "Monitoring will continue, but no new processes found initially."
} else {
    Write-Info "Found $($newPids.Count) new process(es): $($newPids -join ', ')"
}

# Create process_captured directory in parent directory if it doesn't exist
$scriptDir = if ($PSCommandPath) {
    Split-Path -Parent $PSCommandPath
} else {
    (Get-Location).Path
}
$parentDir = Split-Path -Parent $scriptDir

$processBreakdownDir = Join-Path $parentDir 'process_captured'
if (-not (Test-Path -LiteralPath $processBreakdownDir)) {
    New-Item -ItemType Directory -Path $processBreakdownDir -Force | Out-Null
    Write-Info "Created directory: $processBreakdownDir"
}

# Create CSV file path based on application name
$csvFileName = "$ApplicationName.csv"
$csvPath = Join-Path $processBreakdownDir $csvFileName

Write-Info "Output CSV file: $csvPath"

# Track monitored processes and their connections
$script:monitoredProcesses = @{}  # Key = PID, Value = ProcessName
$script:processStartTime = @{}    # Key = PID, Value = StartTime
$script:knownConnections = @{}    # Track connections we've already written: Key = "PID:LocalAddr:LocalPort:RemoteAddr:RemotePort"

# Function to get connection key for tracking
function Get-ConnectionKey {
    param(
        [int]$ProcessId,
        [string]$LocalAddress,
        [int]$LocalPort,
        [string]$RemoteAddress,
        [int]$RemotePort
    )
    return "$ProcessId`:$LocalAddress`:$LocalPort`:$RemoteAddress`:$RemotePort"
}

# Function to process a new process and write to CSV
function Process-NewProcess {
    param([int]$ProcessId)
    
    if ($script:monitoredProcesses.ContainsKey($ProcessId)) {
        return  # Already processing this process
    }
    
    try {
        $proc = Get-Process -Id $ProcessId -ErrorAction Stop
        $script:monitoredProcesses[$ProcessId] = $proc.ProcessName
        $script:processStartTime[$ProcessId] = Get-Date
        
        Write-Info "Monitoring new process: PID $ProcessId - $($proc.ProcessName)"
        
        # Get network connections
        $connections = Get-ProcessNetworkConnections -ProcessId $ProcessId
        Write-ProcessConnections -ProcessId $ProcessId -ProcessName $proc.ProcessName -Connections $connections
        
    } catch {
        # Process may have exited already
        if ($_.Exception.Message -notlike "*not found*") {
            Write-Warn "Error processing PID $ProcessId : $($_.Exception.Message)"
        }
    }
}

# Function to write process connections to CSV (only new ones)
function Write-ProcessConnections {
    param(
        [int]$ProcessId,
        [string]$ProcessName,
        [array]$Connections
    )
    
    if ($Connections.Count -eq 0) {
        # No connections yet, but still record the process once
        $connKey = Get-ConnectionKey -ProcessId $ProcessId -LocalAddress "" -LocalPort 0 -RemoteAddress "" -RemotePort 0
        if (-not $script:knownConnections.ContainsKey($connKey)) {
            $processInfo = [PSCustomObject]@{
                Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                ProcessId = $ProcessId
                ProcessName = $ProcessName
                HostAddress = ""
                HostPort = ""
                RemoteAddress = ""
                RemotePort = ""
                ConnectionState = "No Connections"
            }
            Export-ProcessInfoToCsv -ProcessInfo $processInfo -CsvPath $csvPath
            $script:knownConnections[$connKey] = $true
            Write-Info "  -> Process $ProcessId ($ProcessName): No network connections"
        }
    } else {
        # Write each new connection as a separate row
        foreach ($conn in $Connections) {
            $connKey = Get-ConnectionKey -ProcessId $ProcessId -LocalAddress $conn.LocalAddress -LocalPort $conn.LocalPort -RemoteAddress $conn.RemoteAddress -RemotePort $conn.RemotePort
            if (-not $script:knownConnections.ContainsKey($connKey)) {
                $processInfo = [PSCustomObject]@{
                    Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                    ProcessId = $ProcessId
                    ProcessName = $ProcessName
                    HostAddress = $conn.LocalAddress
                    HostPort = $conn.LocalPort
                    RemoteAddress = $conn.RemoteAddress
                    RemotePort = $conn.RemotePort
                    ConnectionState = $conn.State
                }
                Export-ProcessInfoToCsv -ProcessInfo $processInfo -CsvPath $csvPath
                $script:knownConnections[$connKey] = $true
                Write-Info "  -> Process $ProcessId ($ProcessName): $($conn.LocalAddress):$($conn.LocalPort) -> $($conn.RemoteAddress):$($conn.RemotePort) ($($conn.State))"
            }
        }
    }
}

# Process initially found new processes
foreach ($single_pid in $newPids) {
    Process-NewProcess -ProcessId $single_pid
}

# Monitor loop: check for new processes and update connections for existing ones
Write-Info "Entering monitoring loop. Press Ctrl+C to stop..."
$checkInterval = 2  # Check every 2 seconds

try {
    while ($true) {
        Start-Sleep -Seconds $checkInterval
        
        # Check for new processes
        $currentPids = Get-AllProcessIds
        $currentlyNewPids = $currentPids | Where-Object { $baselinePids -notcontains $_ }
        
        # Find truly new processes (not yet monitored)
        $trulyNewPids = $currentlyNewPids | Where-Object { -not $script:monitoredProcesses.ContainsKey($_) }
        
        foreach ($single_pid in $trulyNewPids) {
            Process-NewProcess -ProcessId $single_pid
        }
        
        # Check for connection changes in monitored processes
        foreach ($single_pid in @($script:monitoredProcesses.Keys)) {  # Create copy to avoid modification during iteration
            try {
                $proc = Get-Process -Id $single_pid -ErrorAction Stop
                $connections = Get-ProcessNetworkConnections -ProcessId $single_pid
                Write-ProcessConnections -ProcessId $single_pid -ProcessName $proc.ProcessName -Connections $connections
                
            } catch {
                # Process has exited
                if ($_.Exception.Message -like "*not found*" -or $_.Exception.Message -like "*Cannot find*") {
                    $procName = "Unknown"
                    # Get process name from our tracked list
                    if ($script:monitoredProcesses.ContainsKey($single_pid)) {
                        $procName = $script:monitoredProcesses[$single_pid]
                    }
                    
                    $exitInfo = [PSCustomObject]@{
                        Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                        ProcessId = $single_pid
                        ProcessName = $procName
                        HostAddress = ""
                        HostPort = ""
                        RemoteAddress = ""
                        RemotePort = ""
                        ConnectionState = "Process Exited"
                    }
                    Export-ProcessInfoToCsv -ProcessInfo $exitInfo -CsvPath $csvPath
                    Write-Info "Process $single_pid ($procName) has exited."
                    $script:monitoredProcesses.Remove($single_pid)
                    if ($script:processStartTime.ContainsKey($single_pid)) {
                        $script:processStartTime.Remove($single_pid)
                    }
                    # Clean up connection tracking for this process
                    $keysToRemove = @()
                    foreach ($key in $script:knownConnections.Keys) {
                        if ($key -like "$single_pid`:*") {
                            $keysToRemove += $key
                        }
                    }
                    foreach ($key in $keysToRemove) {
                        $script:knownConnections.Remove($key)
                    }
                }
            }
        }
        
        # Exit if no processes are being monitored anymore
        if ($script:monitoredProcesses.Count -eq 0 -and ($currentPids | Where-Object { $baselinePids -notcontains $_ }).Count -eq 0) {
            Write-Info "All monitored processes have exited. Stopping monitoring."
            break
        }
    }
} catch {
    if ($_.Exception.Message -notlike "*Cancel*" -and $_.Exception.Message -notlike "*interrupt*") {
        Write-Error "Monitoring error: $($_.Exception.Message)"
    }
} finally {
    $totalMonitored = if ($script:monitoredProcesses) { $script:monitoredProcesses.Count } else { 0 }
    Write-Info "Monitoring stopped. Results saved to: $csvPath"
    Write-Info "Total processes monitored during session: $totalMonitored"
}


