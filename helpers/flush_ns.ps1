# Requires: Windows PowerShell 5+ (or PowerShell 7) on Windows 10/11
# Usage: .\helpers\flush_ns.ps1 [--set-google-dns]
# 
# This script flushes DNS cache and resets DNS server addresses on network interfaces.
# Useful after VPN applications modify DNS settings that persist after the VPN is closed.
#
# Options:
#   --set-google-dns    : After resetting, set Google DNS (8.8.8.8, 8.8.4.4) on active interfaces
#   --set-default       : Reset DNS to DHCP/automatic (default behavior)

param(
    [switch]$SetGoogleDns = $false,
    [switch]$SetDefault = $true
)

# Set console output encoding to UTF-8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

function Write-Info($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [INFO ] $msg" -ForegroundColor Cyan
}

function Write-Warn($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Warning "[$timestamp] [WARN ] $msg"
}

function Write-Err($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Error "[$timestamp] [ERROR] $msg"
}

function Write-Success($msg) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] [OK   ] $msg" -ForegroundColor Green
}

# Check if running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Err "This script requires Administrator privileges. Please run PowerShell as Administrator."
    Write-Info "Right-click PowerShell and select 'Run as Administrator'"
    exit 1
}

Write-Info "Starting DNS flush and reset procedure..."

# Step 1: Flush DNS cache
Write-Info "Step 1: Flushing DNS cache..."
try {
    ipconfig /flushdns | Out-Null
    Write-Success "DNS cache flushed successfully"
} catch {
    Write-Warn "Failed to flush DNS cache: $($_.Exception.Message)"
}

# Step 2: Get all network interfaces
Write-Info "Step 2: Enumerating network interfaces..."
try {
    $interfaces = Get-DnsClientServerAddress | Where-Object { $_.ServerAddresses.Count -gt 0 }
    Write-Info "Found $($interfaces.Count) interface(s) with DNS servers configured"
} catch {
    Write-Err "Failed to enumerate network interfaces: $($_.Exception.Message)"
    exit 1
}

# Step 3: Reset DNS servers on all interfaces
Write-Info "Step 3: Resetting DNS server addresses on all interfaces..."
$resetCount = 0
$failedCount = 0

foreach ($interface in $interfaces) {
    $interfaceName = $interface.InterfaceAlias
    $addressFamily = $interface.AddressFamily
    
    try {
        Write-Info "  Resetting DNS on '$interfaceName' ($addressFamily)..."
        Set-DnsClientServerAddress -InterfaceAlias $interfaceName -AddressFamily $addressFamily -ResetServerAddresses -ErrorAction Stop
        $resetCount++
        Write-Success "    ✓ Reset DNS on '$interfaceName'"
    } catch {
        $failedCount++
        Write-Warn "    ✗ Failed to reset DNS on '$interfaceName': $($_.Exception.Message)"
    }
}

Write-Info "Reset DNS on $resetCount interface(s), $failedCount failed"

# Step 4: Optionally set Google DNS on active interfaces
Write-Info "Step 4: Configuring DNS servers..."

if ($SetGoogleDns) {
    Write-Info "Setting Google DNS (8.8.8.8, 8.8.4.4) on active interfaces..."

    $activeAdapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.InterfaceDescription -notlike "*Loopback*" }

    $setCount = 0
    foreach ($adapter in $activeAdapters) {
        $interfaceName = $adapter.Name
        try {
            Write-Info "  Setting Google DNS on '$interfaceName'..."
            Set-DnsClientServerAddress -InterfaceAlias $interfaceName -ServerAddresses "8.8.8.8","8.8.4.4" -ErrorAction Stop
            $setCount++
            Write-Success "    ✓ Set Google DNS on '$interfaceName'"
        } catch {
            Write-Warn "    ✗ Failed to set DNS on '$interfaceName': $($_.Exception.Message)"
        }
    }

    Write-Success "Set Google DNS on $setCount active interface(s)"
}
else {
    Write-Info "DNS servers reset to DHCP/automatic (default)"
}


# Step 5: Verify DNS resolution
Write-Info "Step 5: Verifying DNS resolution..."
try {
    $testDomain = "generativelanguage.googleapis.com"
    $result = Resolve-DnsName -Name $testDomain -ErrorAction Stop -Server 8.8.8.8 | Select-Object -First 1
    
    if ($result) {
        Write-Success "DNS resolution test passed: $testDomain -> $($result.IPAddress)"
    } else {
        Write-Warn "DNS resolution test returned no results"
    }
} catch {
    Write-Warn "DNS resolution test failed: $($_.Exception.Message)"
    Write-Info "You may need to check your network connectivity"
}

# Step 6: Display current DNS configuration
Write-Info "Step 6: Current DNS configuration:"
Write-Host ""
try {
    $currentConfig = Get-DnsClientServerAddress | Where-Object { $_.ServerAddresses.Count -gt 0 } | 
        Select-Object InterfaceAlias, AddressFamily, @{Name='DNS Servers';Expression={$_.ServerAddresses -join ', '}}
    
    if ($currentConfig) {
        $currentConfig | Format-Table -AutoSize
    } else {
        Write-Info "  All interfaces using DHCP/automatic DNS"
    }
} catch {
    Write-Warn "Failed to display DNS configuration: $($_.Exception.Message)"
}

Write-Host ""
Write-Success "DNS flush and reset completed!"
Write-Info "You can now run UFO again."

