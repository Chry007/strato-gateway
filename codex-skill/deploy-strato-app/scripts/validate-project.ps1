[CmdletBinding()]
param(
    [string] $ProjectRoot = '.'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath($ProjectRoot)
$manifestPath = Join-Path $root '.strato/deploy.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw 'Missing .strato/deploy.json.'
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -Depth 20
$allowed = @('schemaVersion', 'slug', 'internalPort', 'healthPath', 'pathMode', 'persistence', 'releaseInclude')
$properties = @($manifest.PSObject.Properties.Name)
$unknown = @($properties | Where-Object { $_ -notin $allowed })
if ($unknown.Count -gt 0) {
    throw "Unknown manifest properties: $($unknown -join ', ')."
}
foreach ($required in @('schemaVersion', 'slug', 'internalPort', 'healthPath', 'persistence', 'releaseInclude')) {
    if ($required -notin $properties) { throw "Missing manifest property: $required." }
}

if ($manifest.schemaVersion -ne 1) { throw 'schemaVersion must be 1.' }
$slug = [string]$manifest.slug
if ($slug -notmatch '^[a-z][a-z0-9-]{1,30}$') { throw 'Invalid app slug.' }
if ($slug -in @('mobikitcrm', 'gateway', 'infra', 'system')) { throw 'Reserved app slug.' }

$port = [int]$manifest.internalPort
if ($port -lt 1 -or $port -gt 65535) { throw 'internalPort must be between 1 and 65535.' }

$healthPath = [string]$manifest.healthPath
if ($healthPath -notmatch '^/[A-Za-z0-9._~/:@+-]*$' -or
    $healthPath.Contains('..') -or $healthPath.Contains('//') -or
    $healthPath.Contains('?') -or $healthPath.Contains('#')) {
    throw 'healthPath must be a canonical absolute path without query, fragment, or traversal.'
}

$pathMode = if ('pathMode' -in $properties) { [string]$manifest.pathMode } else { 'strip' }
if ($pathMode -notin @('strip', 'preserve')) { throw 'pathMode must be strip or preserve.' }
$persistence = [string]$manifest.persistence
if ($persistence -notin @('stateless', 'stateful')) { throw 'persistence must be stateless or stateful.' }

$releaseInclude = @($manifest.releaseInclude)
if ($releaseInclude.Count -eq 0) { throw 'releaseInclude must not be empty.' }
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$forbiddenTopLevel = '(?i)^(\.env(\..*)?|.*\.env|\.envrc|compose\.env|production\.env|env\.production|secrets?|credentials?|data|uploads?|backups?|node_modules|\.git|\.idea|\.vscode)$'
foreach ($entryValue in $releaseInclude) {
    $entry = [string]$entryValue
    if ([string]::IsNullOrWhiteSpace($entry) -or [IO.Path]::IsPathRooted($entry) -or
        $entry.Contains('\') -or $entry.StartsWith('/') -or $entry.EndsWith('/') -or
        $entry -match '[\x00-\x1f]' -or $entry -match '(^|/)\.\.?(?:/|$)' -or $entry -match '[*?\[\]]') {
        throw "Invalid literal releaseInclude path: $entry"
    }
    $topLevel = $entry.Split('/')[0]
    if ($topLevel -match $forbiddenTopLevel -and $entry -ne '.env.example') {
        throw "Forbidden releaseInclude path: $entry"
    }
    if (-not $seen.Add($entry)) { throw "Duplicate releaseInclude path: $entry" }
    if (-not (Test-Path -LiteralPath (Join-Path $root $entry))) { throw "releaseInclude path does not exist: $entry" }
    if (Test-Path -LiteralPath (Join-Path $root '.git')) {
        $tracked = @(& git -C $root ls-files -- ":(literal)$entry")
        if ($LASTEXITCODE -ne 0 -or $tracked.Count -eq 0) {
            throw "releaseInclude path has no tracked files: $entry"
        }
    }
}

foreach ($requiredSelection in @('.strato/deploy.json', 'Dockerfile', 'compose.strato.yaml')) {
    $selected = $releaseInclude | Where-Object {
        $_ -eq $requiredSelection -or $requiredSelection.StartsWith("$_/", [StringComparison]::Ordinal)
    }
    if (-not $selected) { throw "releaseInclude must select $requiredSelection." }
}

[pscustomobject]@{
    schemaVersion = 1
    slug = $slug
    publicUrl = "https://h2769124.stratoserver.net/apps/$slug/"
    publicPath = "/apps/$slug/"
    composeProject = "strato-$slug"
    appRoot = "/var/snap/docker/common/strato-apps/apps/$slug"
    releasesRoot = "/var/snap/docker/common/strato-apps/apps/$slug/releases"
    dataRoot = "/var/snap/docker/common/strato-apps/apps/$slug/data"
    secretsRoot = "/var/snap/docker/common/strato-apps/apps/$slug/secrets"
    appLock = "/var/snap/docker/common/strato-apps/apps/$slug/.operation.lock"
    networkAlias = "strato-$slug-web"
    internalPort = $port
    healthPath = $healthPath
    publicHealthPath = "/apps/$slug$healthPath"
    upstreamHealthPath = if ($pathMode -eq 'strip') { $healthPath } else { "/apps/$slug$healthPath" }
    pathMode = $pathMode
    persistence = $persistence
    releaseInclude = $releaseInclude
} | ConvertTo-Json -Depth 5
