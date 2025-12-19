#!/usr/bin/env python3
"""
Collect basic system information for Windows machines.
Includes: username, system name, machine ID, Windows version, laptop brand/series,
MAC address, private IP, public IP, and geolocation (latitude/longitude).
"""

import json
import os
import platform
import socket
import subprocess
import sys
from typing import Dict, Optional

import psutil
import requests


def get_windows_username() -> str:
    """Get the current Windows username."""
    try:
        return os.getlogin()
    except (OSError, AttributeError):
        return os.environ.get("USERNAME", os.environ.get("USER", "Unknown"))


def get_windows_version() -> str:
    """Get Windows version information."""
    try:
        version_info = platform.platform()
        return version_info
    except Exception:
        return "Unknown"


def get_system_name() -> str:
    """Get the system/computer name (hostname)."""
    try:
        # Try platform.node() first
        hostname = platform.node()
        if hostname:
            return hostname
    except Exception:
        pass
    
    try:
        # Fallback to socket.gethostname()
        hostname = socket.gethostname()
        if hostname:
            return hostname
    except Exception:
        pass
    
    try:
        # Try WMI as last resort
        result = subprocess.run(
            ["wmic", "computersystem", "get", "name", "/format:list"],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode == 0:
            for line in result.stdout.split("\n"):
                if line.startswith("Name="):
                    name = line.split("=", 1)[1].strip()
                    if name:
                        return name
    except (subprocess.TimeoutExpired, subprocess.SubprocessError, FileNotFoundError):
        pass
    
    return "Unknown"


def get_machine_id() -> str:
    """Get the machine ID/UUID (unique identifier for the system)."""
    try:
        # Try WMI to get UUID from ComputerSystemProduct
        result = subprocess.run(
            ["wmic", "csproduct", "get", "uuid", "/format:list"],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode == 0:
            for line in result.stdout.split("\n"):
                if line.startswith("UUID="):
                    uuid = line.split("=", 1)[1].strip()
                    if uuid and uuid.upper() != "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF":
                        return uuid
    except (subprocess.TimeoutExpired, subprocess.SubprocessError, FileNotFoundError):
        pass
    
    try:
        # Try PowerShell to get MachineGuid from registry
        ps_cmd = (
            "Get-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Cryptography' "
            "-Name MachineGuid | Select-Object -ExpandProperty MachineGuid"
        )
        result = subprocess.run(
            ["powershell", "-Command", ps_cmd],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode == 0:
            machine_guid = result.stdout.strip()
            if machine_guid:
                return machine_guid
    except (subprocess.TimeoutExpired, subprocess.SubprocessError, FileNotFoundError):
        pass
    
    try:
        # Alternative: Try using wmic computersystem get UUID
        result = subprocess.run(
            ["wmic", "computersystem", "get", "UUID", "/format:list"],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode == 0:
            for line in result.stdout.split("\n"):
                if line.startswith("UUID="):
                    uuid = line.split("=", 1)[1].strip()
                    if uuid and uuid.upper() != "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF":
                        return uuid
    except (subprocess.TimeoutExpired, subprocess.SubprocessError, FileNotFoundError):
        pass
    
    return "Unknown"


def get_laptop_brand_series() -> Dict[str, str]:
    """Get laptop brand and series/model using WMI."""
    brand = "Unknown"
    series = "Unknown"
    
    try:
        # Try using wmic command
        result = subprocess.run(
            ["wmic", "computersystem", "get", "manufacturer,model", "/format:list"],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode == 0:
            output = result.stdout
            for line in output.split("\n"):
                if line.startswith("Manufacturer="):
                    brand = line.split("=", 1)[1].strip() or "Unknown"
                elif line.startswith("Model="):
                    series = line.split("=", 1)[1].strip() or "Unknown"
    except (subprocess.TimeoutExpired, subprocess.SubprocessError, FileNotFoundError):
        pass
    
    # If wmic didn't work, try alternative method
    if brand == "Unknown" or series == "Unknown":
        try:
            # Try using Get-CimInstance via PowerShell
            ps_cmd = (
                "Get-CimInstance -ClassName Win32_ComputerSystem | "
                "Select-Object -ExpandProperty Manufacturer,Model | "
                "ForEach-Object { $_.Manufacturer; $_.Model }"
            )
            result = subprocess.run(
                ["powershell", "-Command", ps_cmd],
                capture_output=True,
                text=True,
                timeout=5
            )
            if result.returncode == 0:
                lines = [l.strip() for l in result.stdout.strip().split("\n") if l.strip()]
                if len(lines) >= 2:
                    if brand == "Unknown":
                        brand = lines[0] or "Unknown"
                    if series == "Unknown":
                        series = lines[1] if len(lines) > 1 else "Unknown"
        except (subprocess.TimeoutExpired, subprocess.SubprocessError, FileNotFoundError):
            pass
    
    return {"brand": brand, "series": series}


def get_mac_address() -> str:
    """Get the MAC address of the primary network interface."""
    try:
        # Get all network interfaces
        interfaces = psutil.net_if_addrs()
        
        # Prefer Ethernet, then Wi-Fi, then any active interface
        for interface_name in ["Ethernet", "Wi-Fi", "Local Area Connection"]:
            if interface_name in interfaces:
                for addr in interfaces[interface_name]:
                    if addr.family == psutil.AF_LINK:  # MAC address
                        return addr.address
        
        # If preferred interfaces not found, get first available MAC
        for interface_name, addrs in interfaces.items():
            # Skip loopback and virtual interfaces
            if "Loopback" in interface_name or "Virtual" in interface_name:
                continue
            for addr in addrs:
                if addr.family == psutil.AF_LINK:
                    return addr.address
        
        return "Unknown"
    except Exception:
        return "Unknown"


def get_private_ip() -> str:
    """Get the private IP address of the primary network interface (like ipconfig)."""
    # Method 1: Use ipconfig command (most reliable, matches what user sees)
    try:
        result = subprocess.run(
            ["ipconfig"],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode == 0:
            output = result.stdout
            # Look for IPv4 Address in the output
            # Prefer non-autoconfiguration addresses
            lines = output.split("\n")
            ipv4_addresses = []
            for i, line in enumerate(lines):
                if "IPv4 Address" in line or "IPv4 地址" in line:
                    # Extract IP address
                    parts = line.split(":")
                    if len(parts) >= 2:
                        ip = parts[1].strip().split("(")[0].strip()  # Remove any trailing info in parentheses
                        if ip and ip != "127.0.0.1":
                            # Check if it's not an autoconfiguration address
                            if i + 1 < len(lines) and "Autoconfiguration" not in lines[i + 1]:
                                ipv4_addresses.append((ip, False))
                            else:
                                ipv4_addresses.append((ip, True))
            
            # Return first non-autoconfiguration IP, or first IP if all are autoconfig
            if ipv4_addresses:
                # Sort: non-autoconfig first
                ipv4_addresses.sort(key=lambda x: x[1])
                return ipv4_addresses[0][0]
    except (subprocess.TimeoutExpired, subprocess.SubprocessError, FileNotFoundError):
        pass
    
    # Method 2: Use PowerShell Get-NetIPAddress
    try:
        ps_cmd = (
            "Get-NetIPAddress -AddressFamily IPv4 | "
            "Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | "
            "Sort-Object InterfaceIndex | "
            "Select-Object -First 1 -ExpandProperty IPAddress"
        )
        result = subprocess.run(
            ["powershell", "-Command", ps_cmd],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode == 0:
            ip = result.stdout.strip()
            if ip and ip != "127.0.0.1":
                return ip
    except (subprocess.TimeoutExpired, subprocess.SubprocessError, FileNotFoundError):
        pass
    
    # Method 3: Use psutil (fallback)
    try:
        # Get all network interfaces with their stats
        interfaces = psutil.net_if_addrs()
        stats = psutil.net_if_stats()
        
        # Find active interfaces (prefer those with high speed/active status)
        active_interfaces = []
        for interface_name, addrs in interfaces.items():
            # Skip loopback and virtual interfaces
            if "Loopback" in interface_name or "Virtual" in interface_name or "Teredo" in interface_name:
                continue
            
            # Check if interface is up
            is_up = False
            if interface_name in stats:
                is_up = stats[interface_name].isup
            
            # Get IPv4 address
            for addr in addrs:
                if addr.family == psutil.AF_INET:  # IPv4
                    ip = addr.address
                    # Skip localhost and link-local addresses
                    if ip and ip != "127.0.0.1" and not ip.startswith("169.254."):
                        active_interfaces.append((interface_name, ip, is_up))
        
        # Prefer Ethernet, then Wi-Fi, then any active interface
        preferred_names = ["Ethernet", "Wi-Fi", "Local Area Connection", "Wireless", "WLAN"]
        for preferred in preferred_names:
            for iface_name, ip, is_up in active_interfaces:
                if preferred.lower() in iface_name.lower():
                    return ip
        
        # If no preferred interface found, get first active one
        for iface_name, ip, is_up in active_interfaces:
            if is_up:
                return ip
        
        # If no active interface, return first available
        if active_interfaces:
            return active_interfaces[0][1]
    except Exception:
        pass
    
    # Method 4: Fallback - try to get IP by connecting to a remote address
    try:
        # Connect to a remote address to determine local IP
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(0.1)
        try:
            # Doesn't actually connect, just determines local IP
            s.connect(("8.8.8.8", 80))
            ip = s.getsockname()[0]
            s.close()
            if ip and ip != "127.0.0.1":
                return ip
        except Exception:
            s.close()
    except Exception:
        pass
    
    return "Unknown"


def get_public_ip() -> str:
    """Get the public IP address using an external service."""
    services = [
        "https://api.ipify.org",
        "https://icanhazip.com",
        "https://ifconfig.me/ip",
    ]
    
    for service in services:
        try:
            response = requests.get(service, timeout=5)
            if response.status_code == 200:
                ip = response.text.strip()
                if ip:
                    return ip
        except (requests.RequestException, Exception):
            continue
    
    return "Unknown"


def get_geolocation(ip: Optional[str] = None) -> Dict:
    """Get geolocation data (latitude, longitude, regionName, city, zip, isp) based on IP address."""
    if not ip or ip == "Unknown":
        ip = get_public_ip()
    
    if ip == "Unknown":
        return {
            "latitude": None,
            "longitude": None,
            "regionName": None,
            "city": None,
            "zip": None,
            "isp": None,
        }
    
    services = [
        f"http://ip-api.com/json/{ip}",
        f"https://ipapi.co/{ip}/json/",
    ]
    
    for service in services:
        try:
            response = requests.get(service, timeout=5)
            if response.status_code == 200:
                data = response.json()
                
                # Try ip-api.com format
                if "lat" in data and "lon" in data:
                    lat = data.get("lat")
                    lon = data.get("lon")
                    if lat and lon:
                        return {
                            "latitude": float(lat),
                            "longitude": float(lon),
                            "regionName": data.get("regionName") or data.get("region") or None,
                            "city": data.get("city") or None,
                            "zip": data.get("zip") or data.get("postal") or None,
                            "isp": data.get("isp") or data.get("org") or None,
                        }
                
                # Try ipapi.co format
                if "latitude" in data and "longitude" in data:
                    lat = data.get("latitude")
                    lon = data.get("longitude")
                    if lat is not None and lon is not None:
                        return {
                            "latitude": float(lat),
                            "longitude": float(lon),
                            "regionName": data.get("region") or data.get("regionName") or None,
                            "city": data.get("city") or None,
                            "zip": data.get("postal") or data.get("zip") or None,
                            "isp": data.get("org") or data.get("isp") or None,
                        }
        except (requests.RequestException, ValueError, KeyError, Exception):
            continue
    
    return {
        "latitude": None,
        "longitude": None,
        "regionName": None,
        "city": None,
        "zip": None,
        "isp": None,
    }


def get_basic_stats() -> Dict:
    """Collect all basic system information."""
    print("Collecting system information...")
    
    username = get_windows_username()
    # print(f"  Username: {username}")
    
    system_name = get_system_name()
    # print(f"  System Name: {system_name}")
    
    machine_id = get_machine_id()
    # print(f"  Machine ID: {machine_id}")
    
    windows_version = get_windows_version()
    # print(f"  Windows Version: {windows_version}")
    
    laptop_info = get_laptop_brand_series()
    # print(f"  Brand: {laptop_info['brand']}, Series: {laptop_info['series']}")
    
    mac_address = get_mac_address()
    # print(f"  MAC Address: {mac_address}")
    
    private_ip = get_private_ip()
    # print(f"  Private IP: {private_ip}")
    
    public_ip = get_public_ip()
    # print(f"  Public IP: {public_ip}")
    
    location = get_geolocation(public_ip if public_ip != "Unknown" else None)
    # print(f"  Location: Lat {location['latitude']}, Lon {location['longitude']}")
    # print(f"  Region: {location['regionName']}, City: {location['city']}, ZIP: {location['zip']}")
    # print(f"  ISP: {location['isp']}")
    
    return {
        "username": username,
        "system_name": system_name,
        "machine_id": machine_id,
        "windows_version": windows_version,
        "laptop_brand": laptop_info["brand"],
        "laptop_series": laptop_info["series"],
        "mac_address": mac_address,
        "private_ip": private_ip,
        "public_ip": public_ip,
        "latitude": location["latitude"],
        "longitude": location["longitude"],
        "regionName": location["regionName"],
        "city": location["city"],
        "zip": location["zip"],
        "isp": location["isp"],
    }


def main():
    """Main function to collect and display/return basic stats."""
    try:
        stats = get_basic_stats()
        
        # Determine output directory
        script_dir = os.path.dirname(os.path.abspath(__file__))
        parent_dir = os.path.abspath(os.path.join(script_dir, os.pardir))
        results_dir = os.path.join(parent_dir, "results")
        os.makedirs(results_dir, exist_ok=True)
        
        # Save to JSON file
        output_path = os.path.join(results_dir, "basic_info.json")
        with open(output_path, "w", encoding="utf-8") as f:
            json.dump(stats, f, indent=2, ensure_ascii=False)
        
        # Print as JSON
        print("\n" + "=" * 50)
        print("System Information Summary:")
        print("=" * 50)
        print(json.dumps(stats, indent=2))
        print(f"\nResults saved to: {output_path}")
        
        return stats
    except Exception as e:
        print(f"Error collecting system information: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()

