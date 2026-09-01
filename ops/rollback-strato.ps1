[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9]{8}T[0-9]{6}Z$')]
    [string] $ReleaseId,

    [switch] $CheckOnly
)

. (Join-Path $PSScriptRoot 'Strato.Common.ps1')

$arguments = if ($CheckOnly) { "--check-only '$ReleaseId'" } else { "'$ReleaseId'" }
Invoke-StratoSsh -RemoteCommand "bash '$($script:GatewayRoot)/current/server/rollback-gateway.sh' $arguments"
