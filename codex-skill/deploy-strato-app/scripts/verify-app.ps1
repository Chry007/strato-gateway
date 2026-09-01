[CmdletBinding()]
param(
    [string] $ProjectRoot = '.'
)

. (Join-Path $PSScriptRoot 'StratoApp.Common.ps1')

$root = Get-StratoProjectRoot -Path $ProjectRoot
$manifest = Get-StratoManifest -ProjectRoot $root
Invoke-StratoRemoteHelper -Action 'verify' -Arguments @([string]$manifest.slug)
