[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$root = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$script:Passed = 0
$script:Skipped = 0

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
    $script:Passed++
}

function Assert-Contains {
    param([string] $Text, [string] $Pattern, [string] $Message)
    Assert-True -Condition ($Text -match $Pattern) -Message $Message
}

function Assert-NotContains {
    param([string] $Text, [string] $Pattern, [string] $Message)
    Assert-True -Condition ($Text -notmatch $Pattern) -Message $Message
}

function Read-RepoFile {
    param([string] $Path)
    Get-Content -LiteralPath (Join-Path $root $Path) -Raw
}

function Invoke-ExpectSuccess {
    param([string] $FilePath, [string[]] $Arguments)
    $output = & $FilePath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Expected success from $FilePath. Output: $($output -join [Environment]::NewLine)"
    }
    return ($output -join [Environment]::NewLine)
}

function Invoke-ExpectFailure {
    param([string] $FilePath, [string[]] $Arguments)
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @Arguments *> $null
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }
    Assert-True -Condition ($code -ne 0) -Message "Expected $FilePath to reject invalid input."
}

$composeText = Read-RepoFile 'gateway/compose.gateway.yaml'
$caddyText = Read-RepoFile 'gateway/Caddyfile'
$commonText = Read-RepoFile 'ops/server/common.sh'
$deployText = Read-RepoFile 'ops/server/deploy-gateway.sh'
$verifyText = Read-RepoFile 'ops/server/verify-gateway.sh'
$rollbackText = Read-RepoFile 'ops/server/rollback-gateway.sh'
$routeText = Read-RepoFile 'ops/server/manage-route.sh'
$renderText = Read-RepoFile 'ops/server/render-route.sh'
$allServerText = $commonText + $deployText + $verifyText + $rollbackText + $routeText + $renderText
$appRemoteText = Read-RepoFile 'codex-skill/deploy-strato-app/scripts/remote-app.sh'
$appDeployText = Read-RepoFile 'codex-skill/deploy-strato-app/scripts/deploy-app.ps1'

# Compose/network/port invariants.
$oldGatewayRoot = $env:GATEWAY_ROOT
$oldReleaseDir = $env:GATEWAY_RELEASE_DIR
try {
    $env:GATEWAY_ROOT = '/var/snap/docker/common/strato-apps/gateway'
    $env:GATEWAY_RELEASE_DIR = '/var/snap/docker/common/strato-apps/gateway/releases/20000101T000000Z'
    $composeJsonRaw = Invoke-ExpectSuccess docker @(
        'compose', '--project-name', 'strato-app-gateway',
        '--file', (Join-Path $root 'gateway/compose.gateway.yaml'),
        'config', '--format', 'json'
    )
}
finally {
    $env:GATEWAY_ROOT = $oldGatewayRoot
    $env:GATEWAY_RELEASE_DIR = $oldReleaseDir
}
$compose = $composeJsonRaw | ConvertFrom-Json -Depth 40
Assert-True ($compose.name -eq 'strato-app-gateway') 'Compose project name must be fixed.'
$serviceNames = @($compose.services.PSObject.Properties.Name)
Assert-True ($serviceNames.Count -eq 1 -and $serviceNames[0] -eq 'gateway') 'Compose must contain only the gateway service.'
$service = $compose.services.gateway
Assert-True ($service.image -match '^docker\.io/library/caddy:2\.10\.2-alpine@sha256:[0-9a-f]{64}$') 'Caddy image must be immutable.'
Assert-True ('ports' -notin @($service.PSObject.Properties.Name)) 'Gateway must publish no host ports.'
Assert-True (@($service.expose) -contains '8080') 'Gateway must expose only internal port 8080.'
Assert-NotContains $composeText '(?m)^\s*-\s*no-new-privileges' 'Snap Docker must be able to execute the official file-capability Caddy binary.'
Assert-NotContains $allServerText '--security-opt\s+no-new-privileges' 'Server validators must stay compatible with Snap Docker Caddy execution.'
Assert-True ((@($service.networks.PSObject.Properties.Name | Sort-Object) -join ',') -eq 'strato-app-edge,strato-ingress') 'Gateway network membership must be exact.'
Assert-True ($compose.networks.'strato-ingress'.external -eq $true) 'strato-ingress must be external.'
Assert-True ($compose.networks.'strato-app-edge'.external -eq $true) 'strato-app-edge must be external.'

# Caddy behavior and ordering.
Assert-Contains $caddyText '(?m)^:8080 \{' 'Caddy must listen on 8080.'
Assert-NotContains $caddyText '(?m)^:?(80|443)\b' 'Transitional Caddy config must not listen on 80/443.'
Assert-Contains $caddyText 'X-Strato-App-Gateway' 'Gateway identity header is required.'
Assert-Contains $caddyText 'import /etc/caddy/routes/\*\.caddy' 'Stable route import is required.'
Assert-Contains $caddyText 'handle /apps/\*' 'Unknown app routes need an explicit fallback.'
Assert-True ($caddyText.IndexOf('import /etc/caddy/routes/*.caddy', [StringComparison]::Ordinal) -lt $caddyText.IndexOf('handle /apps/*', [StringComparison]::Ordinal)) 'Generated routes must precede the unknown-app 404.'
Assert-Contains $caddyText 'respond "not found\\n" 404' 'Unknown paths must return 404.'

# Locking, fixed identity, validation-before-install, and rollback behavior.
Assert-Contains $commonText 'STRATO_ROOT="/var/snap/docker/common/strato-apps"' 'Shared root is fixed.'
Assert-Contains $commonText 'GLOBAL_LOCK="\$\{STRATO_ROOT\}/\.operation\.lock"' 'Global lock path is fixed.'
Assert-Contains $commonText 'flock -w' 'Global mutations need a finite flock wait.'
Assert-Contains $deployText 'acquire_global_lock' 'Gateway deployment must acquire the global lock.'
Assert-Contains $rollbackText 'acquire_global_lock' 'Gateway rollback must acquire the global lock.'
Assert-Contains $routeText 'use_inherited_or_acquire_global_lock' 'Route changes must prove or acquire the global lock.'
Assert-Contains $commonText 'GATEWAY_PROJECT="strato-app-gateway"' 'Compose identity must be fixed.'
Assert-Contains $verifyText 'Gateway unexpectedly publishes a host port' 'Verification must fail on host ports.'
Assert-Contains $verifyText 'Gateway must join exactly two networks' 'Verification must enforce exact networks.'
Assert-Contains $commonText 'gateway_http_response' 'Gateway probes must retain headers for non-2xx responses.'
Assert-Contains $commonText 'timeout 12 nc' 'Gateway probes need a hard response deadline.'
Assert-Contains $commonText 'head -c 16384' 'Gateway probes must bound response buffering.'
Assert-NotContains $verifyText 'wget[^\n]*__gateway_unknown__' 'Unknown-route verification must not rely on wget error headers.'
Assert-True ($routeText.IndexOf('Validate the complete candidate configuration', [StringComparison]::Ordinal) -lt $routeText.IndexOf('installed=false', [StringComparison]::Ordinal)) 'Complete Caddy validation must precede installation.'
Assert-True ($routeText.IndexOf('installed=false', [StringComparison]::Ordinal) -lt $routeText.IndexOf('mv -Tf -- "${next_route}"', [StringComparison]::Ordinal)) 'Recovery must be armed before route activation.'
Assert-Contains $routeText 'restore_previous_pair' 'Route failure must restore the prior allocation.'
Assert-Contains $routeText 'reload_gateway' 'Route activation must reload only the gateway.'
Assert-True ($rollbackText.IndexOf('verify-gateway.sh" --release "${target_dir}"', [StringComparison]::Ordinal) -lt $rollbackText.IndexOf('switch_current_release "${target_dir}"', [StringComparison]::Ordinal)) 'Rollback must verify before switching current.'
Assert-Contains $rollbackText 'restoring \$\{current_id\}' 'Failed rollback must restore the original release.'

# The reusable app transaction keeps the same shared boundaries without becoming app-specific.
Assert-Contains $appRemoteText 'GLOBAL_LOCK="\$\{STRATO_ROOT\}/\.operation\.lock"' 'App mutations must use the host-global lock.'
Assert-Contains $appRemoteText 'App unexpectedly publishes a host port' 'App verification must reject published host ports.'
Assert-Contains $appRemoteText 'App web container joined strato-ingress' 'Apps must never join the public ingress network.'
Assert-Contains $appRemoteText 'up -d --no-build --pull never' 'Activation and rollback must use retained release images.'
Assert-Contains $appRemoteText 'trap recover_deploy EXIT' 'App deployment recovery must cover ordinary and signal exits.'
Assert-Contains $appRemoteText 'switch_current "\$\{previous_dir\}"' 'Failed app deployment must restore the previous current pointer.'
Assert-True ($appDeployText.IndexOf("-Action 'preflight'", [StringComparison]::Ordinal) -lt $appDeployText.IndexOf('Invoke-StratoScp', [StringComparison]::Ordinal)) 'Gateway and bridge preflight must precede app upload.'

# Prohibited operational machinery and destructive patterns.
Assert-NotContains $allServerText '(?i)docker\s+(system|image|container|volume|network)?\s*prune' 'Docker pruning is forbidden.'
Assert-NotContains $allServerText '(?i)compose[^\n]*down\s+-v' 'down -v is forbidden.'
Assert-NotContains $appRemoteText '(?i)compose[^\n]*down\s+-v' 'App lifecycle must not use down -v.'
Assert-NotContains $composeText '(?m)^\s*ports\s*:' 'Compose must not declare ports.'
Assert-NotContains $allServerText '(?i)kubectl|kubernetes|consul|nomad|swarm' 'General platform/service discovery machinery is out of scope.'
Assert-NotContains $deployText '(?i)/var/snap/docker/common/mobikitcrm/' 'Gateway deploy must not touch Mobikit files.'
Assert-NotContains $rollbackText '(?i)/var/snap/docker/common/mobikitcrm/' 'Gateway rollback must not touch Mobikit files.'

# Route renderer validation and both path modes.
$gitBash = @(
    'C:\Program Files\Git\bin\bash.exe',
    'C:\Program Files\Git\usr\bin\bash.exe'
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($gitBash) {
    Get-ChildItem -LiteralPath (Join-Path $root 'ops/server') -Filter '*.sh' | ForEach-Object {
        Invoke-ExpectSuccess $gitBash @('-n', $_.FullName) | Out-Null
        $script:Passed++
    }
    Invoke-ExpectSuccess $gitBash @('-n', (Join-Path $root 'codex-skill/deploy-strato-app/scripts/remote-app.sh')) | Out-Null
    $script:Passed++
    $renderScript = Join-Path $root 'ops/server/render-route.sh'
    $stripRoute = Invoke-ExpectSuccess $gitBash @($renderScript, 'example', 'strato-example-web', '3000', 'strip')
    Assert-Contains $stripRoute 'handle_path /apps/example/\*' 'Strip route must use handle_path.'
    Assert-Contains $stripRoute 'reverse_proxy strato-example-web:3000' 'Route must use the validated alias and port.'
    $preserveRoute = Invoke-ExpectSuccess $gitBash @($renderScript, 'example', 'strato-example-web', '3000', 'preserve')
    Assert-Contains $preserveRoute '(?m)^handle /apps/example/\*' 'Preserve route must use handle.'
    Invoke-ExpectFailure $gitBash @($renderScript, '../bad', 'strato-bad-web', '3000', 'strip')
    Invoke-ExpectFailure $gitBash @($renderScript, 'example', 'other-alias', '3000', 'strip')
    Invoke-ExpectFailure $gitBash @($renderScript, 'example', 'strato-example-web', '70000', 'strip')
    Invoke-ExpectFailure $gitBash @($renderScript, 'example', 'strato-example-web', '3000', 'unknown')
}
else {
    $script:Skipped++
}

# The small manifest validator derives trusted identities and rejects dangerous input.
$fixtureNonce = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(8)).ToLowerInvariant()
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "strato-static-tests-$fixtureNonce"
try {
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot '.strato') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'src') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'ops') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $fixtureRoot 'Dockerfile') -Value 'FROM scratch'
    Set-Content -LiteralPath (Join-Path $fixtureRoot 'compose.strato.yaml') -Value 'services: {}'
    $validManifest = [ordered]@{
        schemaVersion = 1
        slug = 'example'
        internalPort = 3000
        healthPath = '/health'
        persistence = 'stateless'
        releaseInclude = @('.strato/deploy.json', 'Dockerfile', 'compose.strato.yaml', 'src', 'ops')
    }
    $validManifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $fixtureRoot '.strato/deploy.json')
    $validatorOutput = & pwsh -NoProfile -File (Join-Path $root 'codex-skill/deploy-strato-app/scripts/validate-project.ps1') -ProjectRoot $fixtureRoot
    if ($LASTEXITCODE -ne 0) { throw 'Valid manifest fixture was rejected.' }
    $derived = ($validatorOutput -join [Environment]::NewLine) | ConvertFrom-Json
    Assert-True ($derived.composeProject -eq 'strato-example') 'Manifest must derive the app Compose project.'
    Assert-True ($derived.networkAlias -eq 'strato-example-web') 'Manifest must derive the unique edge alias.'
    Assert-True ($derived.pathMode -eq 'strip') 'Manifest path mode must default to strip.'

    $badManifest = $validManifest | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
    $badManifest.slug = 'mobikitcrm'
    $badManifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $fixtureRoot '.strato/deploy.json')
    Invoke-ExpectFailure pwsh @('-NoProfile', '-File', (Join-Path $root 'codex-skill/deploy-strato-app/scripts/validate-project.ps1'), '-ProjectRoot', $fixtureRoot)

    $badManifest = $validManifest | ConvertTo-Json -Depth 5 | ConvertFrom-Json -AsHashtable
    $badManifest.releaseInclude = @('.strato/deploy.json', 'Dockerfile', 'compose.strato.yaml', '.env')
    Set-Content -LiteralPath (Join-Path $fixtureRoot '.env') -Value 'SECRET=not-a-real-secret'
    $badManifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $fixtureRoot '.strato/deploy.json')
    Invoke-ExpectFailure pwsh @('-NoProfile', '-File', (Join-Path $root 'codex-skill/deploy-strato-app/scripts/validate-project.ps1'), '-ProjectRoot', $fixtureRoot)

    # Installer replacement test: obsolete files must not survive an update.
    $skillsRoot = Join-Path $fixtureRoot 'skills'
    $oldSkill = Join-Path $skillsRoot 'deploy-strato-app'
    New-Item -ItemType Directory -Path $oldSkill -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $oldSkill 'obsolete-sentinel.txt') -Value 'remove me'
    & pwsh -NoProfile -File (Join-Path $root 'ops/install-global-skill.ps1') -SkillsRoot $skillsRoot *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Skill installer fixture failed.' }
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $oldSkill 'obsolete-sentinel.txt'))) 'Skill update must replace, not overlay, the prior copy.'
    $sourceFiles = @(Get-ChildItem -LiteralPath (Join-Path $root 'codex-skill/deploy-strato-app') -Recurse -File)
    $installedFiles = @(Get-ChildItem -LiteralPath $oldSkill -Recurse -File)
    Assert-True ($sourceFiles.Count -eq $installedFiles.Count) 'Installed skill file set must match canonical source.'
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
        $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolvedFixture.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolvedFixture) -notmatch '^strato-static-tests-[0-9a-f]{16}$') {
            throw 'Refusing unsafe test fixture cleanup.'
        }
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}

# Handoffs preserve the transitional public-edge boundary.
$mobikitHandoff = Read-RepoFile 'docs/MOBIKIT_BRIDGE_HANDOFF.md'
$cutoverHandoff = Read-RepoFile 'docs/PUBLIC_EDGE_CUTOVER.md'
Assert-Contains $mobikitHandoff 'later, separate Mobikit task' 'Bridge must remain a separate Mobikit task.'
Assert-Contains $mobikitHandoff 'reverse_proxy strato-app-gateway:8080' 'Handoff must give the exact bridge target.'
Assert-Contains $cutoverHandoff 'future migration' 'Public edge cutover must be explicitly deferred.'
Assert-Contains (Read-RepoFile 'AGENTS.md') 'publishes no host ports' 'Project authority must preserve the transitional port boundary.'

Write-Output "Static tests passed: $script:Passed assertions; skipped groups: $script:Skipped."
