[CmdletBinding()]
param(
    [int]$Port = $(if ($env:CHROMEMCP_FOCUS_PORT) { [int]$env:CHROMEMCP_FOCUS_PORT } else { 9232 }),
    [string]$ProfileName = $(if ($env:CHROMEMCP_FOCUS_PROFILE_NAME) { $env:CHROMEMCP_FOCUS_PROFILE_NAME } else { 'ChromeMCP-Codex' })
)

$ErrorActionPreference = 'Stop'

& "$PSScriptRoot\Focus-Chrome.ps1" -Port $Port -ProfileName $ProfileName
