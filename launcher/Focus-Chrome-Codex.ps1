[CmdletBinding()]
param(
    [int]$Port = 9232
)

$ErrorActionPreference = 'Stop'

& "$PSScriptRoot\Focus-Chrome.ps1" -Port $Port -ProfileName 'ChromeMCP-Codex'
