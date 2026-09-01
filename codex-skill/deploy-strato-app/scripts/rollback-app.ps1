[CmdletBinding()]
param(
    [string] $ProjectRoot = '.',
    [Parameter(Mandatory)][string] $Release
)

. (Join-Path $PSScriptRoot 'StratoApp.Common.ps1')

if ($Release -notmatch '^[0-9]{8}T[0-9]{6}Z$') {
    throw 'Release must have the UTC yyyyMMddTHHmmssZ form.'
}
$root = Get-StratoProjectRoot -Path $ProjectRoot
$manifest = Get-StratoManifest -ProjectRoot $root
Invoke-StratoRemoteHelper -Action 'rollback' -Arguments @([string]$manifest.slug, $Release)
