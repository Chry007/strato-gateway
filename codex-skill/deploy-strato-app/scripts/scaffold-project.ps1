[CmdletBinding()]
param(
    [string] $ProjectRoot = '.',
    [Parameter(Mandatory)][string] $Slug,
    [Parameter(Mandatory)][ValidateRange(1, 65535)][int] $InternalPort,
    [string] $HealthPath = '/health',
    [ValidateSet('strip', 'preserve')][string] $PathMode = 'strip',
    [ValidateSet('stateless', 'stateful')][string] $Persistence = 'stateless',
    [string[]] $ReleaseInclude = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath($ProjectRoot)
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    throw "Project root does not exist: $root"
}
if ($Slug -notmatch '^[a-z][a-z0-9-]{1,30}$' -or $Slug -in @('mobikitcrm', 'gateway', 'infra', 'system')) {
    throw 'Slug must be a non-reserved lowercase app slug.'
}
if ($HealthPath -notmatch '^/[A-Za-z0-9._~/:@+-]*$' -or
    $HealthPath.Contains('..') -or $HealthPath.Contains('//') -or
    $HealthPath.Contains('?') -or $HealthPath.Contains('#')) {
    throw 'HealthPath must be a canonical absolute path.'
}

$dockerfile = Join-Path $root 'Dockerfile'
if (-not (Test-Path -LiteralPath $dockerfile -PathType Leaf)) {
    throw 'Create the application Dockerfile before scaffolding STRATO deployment files.'
}

$manifestDirectory = Join-Path $root '.strato'
$manifestPath = Join-Path $manifestDirectory 'deploy.json'
$composePath = Join-Path $root 'compose.strato.yaml'
$opsDirectory = Join-Path $root 'ops'
$checkPath = Join-Path $opsDirectory 'check-strato.ps1'
if (Test-Path -LiteralPath $manifestPath) {
    throw '.strato/deploy.json already exists; edit it instead of overwriting it.'
}

New-Item -ItemType Directory -Path $manifestDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $opsDirectory -Force | Out-Null

if (-not (Test-Path -LiteralPath $composePath)) {
    $compose = @"
services:
  web:
    image: strato-$Slug-web:`${STRATO_RELEASE:?}
    build:
      context: .
    restart: unless-stopped
    expose:
      - "$InternalPort"
    networks:
      strato-app-edge:
        aliases:
          - strato-$Slug-web

networks:
  strato-app-edge:
    external: true
    name: strato-app-edge
"@
    Set-Content -LiteralPath $composePath -Value $compose -Encoding utf8NoBOM
}

if (-not (Test-Path -LiteralPath $checkPath)) {
    $check = @'
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Replace this line with this project's normal test and production-build commands.
throw 'Tailor ops/check-strato.ps1 before the first deployment.'
'@
    Set-Content -LiteralPath $checkPath -Value $check -Encoding utf8NoBOM
}

$normalizedReleaseInclude = [Collections.Generic.List[string]]::new()
foreach ($argument in $ReleaseInclude) {
    foreach ($candidate in $argument.Split(',', [StringSplitOptions]::RemoveEmptyEntries)) {
        $entry = $candidate.Trim()
        if (-not [string]::IsNullOrWhiteSpace($entry)) { $normalizedReleaseInclude.Add($entry) }
    }
}

$selected = [Collections.Generic.List[string]]::new()
foreach ($entry in @('.strato/deploy.json', 'Dockerfile', 'compose.strato.yaml', 'ops/check-strato.ps1') + @($normalizedReleaseInclude)) {
    if (-not $selected.Contains($entry)) { $selected.Add($entry) }
}
$manifest = [ordered]@{
    schemaVersion = 1
    slug = $Slug
    internalPort = $InternalPort
    healthPath = $HealthPath
    pathMode = $PathMode
    persistence = $Persistence
    releaseInclude = @($selected)
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM

Write-Output "Created .strato/deploy.json for https://h2769124.stratoserver.net/apps/$Slug/."
Write-Output 'Tailor ops/check-strato.ps1 and releaseInclude, then run validate-project.ps1.'
