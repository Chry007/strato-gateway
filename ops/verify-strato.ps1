[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'Strato.Common.ps1')

Invoke-StratoSsh -RemoteCommand "bash '$($script:GatewayRoot)/current/server/verify-gateway.sh'"
