<#
.SYNOPSIS
    Bridges Chrome's CDP port (default 9222) from Windows loopback to a
    WSL-reachable address, with a Defender firewall rule scoped to the
    WSL subnet only.

.DESCRIPTION
    WSL2 has its own network namespace, so Windows-side 127.0.0.1 is
    invisible from WSL by default. This script:
      1. Detects the vEthernet (WSL) adapter on Windows
      2. Adds a netsh portproxy entry on that adapter's IP forwarding 9222
         to 127.0.0.1:9222 (where Chrome's CDP actually listens)
      3. Adds an inbound Defender rule allowing TCP 9222 only from the
         WSL distro's subnet, on that local interface only
    All operations are idempotent and survive reboots. Run with -Remove
    to cleanly tear everything back down.

.PARAMETER Port
    CDP port to bridge. Default 9222. Match whatever your launcher uses.

.PARAMETER Remove
    Remove the portproxy entry and firewall rule, then exit.

.NOTES
    Requires Administrator. The .cmd wrapper handles UAC elevation.
#>
[CmdletBinding()]
param(
    [int]$Port = 9222,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

# --- Admin check ---------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "This script must be run as Administrator. Use Setup-Bridge.cmd which auto-elevates."
    exit 1
}

# --- Detect WSL vEthernet adapter ----------------------------------------
function Get-WslAdapterIP {
    $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
        $_.InterfaceAlias -like 'vEthernet (WSL*'
    } | Select-Object -First 1
    if (-not $adapter) { return $null }
    $ip = (Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
    if (-not $ip) { return $null }
    [pscustomobject]@{
        Name      = $adapter.Name
        Index     = $adapter.ifIndex
        IPAddress = $ip
        Subnet    = ($ip -replace '\.\d+$', '.0') + '/20'  # WSL2 default /20 mask
    }
}

$wsl = Get-WslAdapterIP
if (-not $wsl) {
    Write-Error "Could not find vEthernet (WSL) adapter. Is WSL2 currently running? Try 'wsl -d <distro>' first."
    exit 1
}

$ruleName = "ChromeMCP CDP from WSL ($Port)"

Write-Host ""
Write-Host "ChromeMCP WSL bridge" -ForegroundColor Cyan
Write-Host "  WSL adapter   : $($wsl.Name)"
Write-Host "  Adapter IP    : $($wsl.IPAddress)"
Write-Host "  WSL subnet    : $($wsl.Subnet)"
Write-Host "  CDP port      : $Port"
Write-Host "  Firewall rule : $ruleName"
Write-Host ""

# --- Removal path --------------------------------------------------------
if ($Remove) {
    Write-Host "Removing portproxy entries on port $Port..."
    # netsh delete is noisy when the entry doesn't exist; suppress and ignore.
    & netsh interface portproxy delete v4tov4 listenaddress=$($wsl.IPAddress) listenport=$Port 2>&1 | Out-Null
    & netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0           listenport=$Port 2>&1 | Out-Null

    Write-Host "Removing firewall rule '$ruleName'..."
    Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule

    Write-Host ""
    Write-Host "Bridge removed." -ForegroundColor Green
    exit 0
}

# --- Install path: portproxy ---------------------------------------------
# Always remove first so we don't get duplicate entries on re-run.
& netsh interface portproxy delete v4tov4 listenaddress=$($wsl.IPAddress) listenport=$Port 2>&1 | Out-Null

Write-Host "Adding portproxy: $($wsl.IPAddress):$Port -> 127.0.0.1:$Port"
$proxyOut = & netsh interface portproxy add v4tov4 `
    listenaddress=$($wsl.IPAddress) listenport=$Port `
    connectaddress=127.0.0.1        connectport=$Port 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "netsh portproxy add failed: $proxyOut"
    exit 1
}

# --- Install path: firewall rule -----------------------------------------
Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
Write-Host "Adding inbound firewall rule (TCP $Port, from $($wsl.Subnet) only)..."
New-NetFirewallRule `
    -DisplayName  $ruleName `
    -Description  "Allow CDP access from WSL2 to Chrome's debug port. Created by ChromeMCP project." `
    -Direction    Inbound `
    -Action       Allow `
    -Protocol     TCP `
    -LocalPort    $Port `
    -LocalAddress $wsl.IPAddress `
    -RemoteAddress $wsl.Subnet `
    -Profile      Any | Out-Null

# --- Verify --------------------------------------------------------------
Write-Host ""
Write-Host "Self-test (Windows side): hitting http://$($wsl.IPAddress):$Port/json/version ..."
try {
    $resp = Invoke-RestMethod -Uri "http://$($wsl.IPAddress):$Port/json/version" -TimeoutSec 3 -ErrorAction Stop
    Write-Host "Bridge live. Chrome reachable via portproxy:" -ForegroundColor Green
    Write-Host "  Browser : $($resp.Browser)"
    Write-Host "  WS URL  : $($resp.webSocketDebuggerUrl)"
} catch {
    Write-Warning "Self-test failed. Make sure Chrome is running with --remote-debugging-port=$Port (run .\chrome first)."
    Write-Warning "Error: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "From WSL, MCP servers should target:  http://$($wsl.IPAddress):$Port" -ForegroundColor Yellow
Write-Host ""
Write-Host "To revert: re-run this with -Remove (or Setup-Bridge.cmd /remove)."
