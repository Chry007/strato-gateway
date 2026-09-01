[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'Strato.Common.ps1')

$repositoryRoot = Get-RepositoryRoot
if ($repositoryRoot -ne [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))) {
    throw 'Run the deployment helper from this gateway repository.'
}

Invoke-CheckedNative -FilePath pwsh -ArgumentList @(
    '-NoProfile', '-File', (Join-Path $repositoryRoot 'tests/Run-StaticTests.ps1')
)

$release = Assert-CleanPushedRelease -RepositoryRoot $repositoryRoot
$releaseId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$nonce = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(16)).ToLowerInvariant()
$taskRoot = Join-Path ([System.IO.Path]::GetTempPath()) "strato-gateway-$releaseId-$nonce"
$archivePath = Join-Path $taskRoot 'gateway.tar.gz'
$extractPath = Join-Path $taskRoot 'payload'
$remoteArchive = "/var/tmp/strato-app-gateway-$releaseId-$nonce.tar.gz"
$remoteHelperDir = "/var/tmp/strato-app-gateway-helper-$releaseId-$nonce"
$remoteTouched = $false

$payload = @(
    'gateway/Caddyfile',
    'gateway/compose.gateway.yaml',
    'ops/server/common.sh',
    'ops/server/deploy-gateway.sh',
    'ops/server/verify-gateway.sh',
    'ops/server/rollback-gateway.sh',
    'ops/server/manage-route.sh',
    'ops/server/render-route.sh',
    'ops/server/verify-app-prerequisites.sh'
)

New-Item -ItemType Directory -Path $taskRoot | Out-Null
New-Item -ItemType Directory -Path $extractPath | Out-Null
try {
    Push-Location $repositoryRoot
    try {
        Invoke-CheckedNative -FilePath git -ArgumentList (@(
            'archive', '--format=tar.gz', "--output=$archivePath", $release.Commit, '--'
        ) + $payload)
    }
    finally {
        Pop-Location
    }

    Invoke-CheckedNative -FilePath tar -ArgumentList @('-xzf', $archivePath, '-C', $extractPath)
    $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()

    $createHelperCommand = "install -d -m 0700 '$remoteHelperDir'"
    Invoke-StratoSsh -RemoteCommand $createHelperCommand
    $remoteTouched = $true

    Invoke-CheckedNative -FilePath scp -ArgumentList @(
        $script:ScpOptions + @(
            $archivePath,
            "$($script:StratoTarget):$remoteArchive"
        )
    )
    Invoke-CheckedNative -FilePath scp -ArgumentList @(
        $script:ScpOptions + @(
            (Join-Path $extractPath 'ops/server/common.sh'),
            (Join-Path $extractPath 'ops/server/deploy-gateway.sh'),
            "$($script:StratoTarget):$remoteHelperDir/"
        )
    )

    $remoteCommand = "cleanup() { rm -f -- '$remoteArchive'; rm -rf -- '$remoteHelperDir'; }; trap cleanup EXIT HUP INT TERM; bash '$remoteHelperDir/deploy-gateway.sh' '$remoteArchive' '$releaseId' '$($release.Commit)' '$archiveHash'"
    Invoke-StratoSsh -RemoteCommand $remoteCommand

    Invoke-CheckedNative -FilePath pwsh -ArgumentList @(
        '-NoProfile', '-File', (Join-Path $PSScriptRoot 'verify-strato.ps1')
    )
}
finally {
    if ($remoteTouched) {
        try {
            Invoke-StratoSsh -RemoteCommand "rm -f -- '$remoteArchive'; rm -rf -- '$remoteHelperDir'"
        }
        catch {
            Write-Warning "Could not remove the exact remote upload staging paths: $($_.Exception.Message)"
        }
    }
    if (Test-Path -LiteralPath $taskRoot) {
        $resolvedTaskRoot = [System.IO.Path]::GetFullPath($taskRoot)
        $resolvedTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        if (-not $resolvedTaskRoot.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase) -or
            [System.IO.Path]::GetFileName($resolvedTaskRoot) -notmatch '^strato-gateway-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{32}$') {
            throw 'Refusing unsafe local artifact cleanup.'
        }
        Remove-Item -LiteralPath $resolvedTaskRoot -Recurse -Force
    }
}
