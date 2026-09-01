[CmdletBinding()]
param(
    [string] $ProjectRoot = '.'
)

. (Join-Path $PSScriptRoot 'StratoApp.Common.ps1')

$root = Get-StratoProjectRoot -Path $ProjectRoot
$manifest = Get-StratoManifest -ProjectRoot $root

# Check once before and once after the app-owned test/build step. This keeps generated
# or accidentally edited files out of the release without dictating the app's toolchain.
Assert-StratoGitRelease -ProjectRoot $root | Out-Null
Invoke-StratoProjectCheck -ProjectRoot $root -Manifest $manifest
$commit = Assert-StratoGitRelease -ProjectRoot $root

# Refuse before packaging or upload when the gateway or the separate Mobikit bridge
# is not ready. The server rechecks this under the operation lock before mutation.
Invoke-StratoRemoteHelper -Action 'preflight' -Arguments @([string]$manifest.slug)

$release = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ', [Globalization.CultureInfo]::InvariantCulture)
$nonce = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(16)).ToLowerInvariant()
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("strato-app-" + [Guid]::NewGuid().ToString('N'))
$archive = Join-Path $temporaryRoot "$($manifest.slug)-$release.tar"
$remoteArchive = "/var/snap/docker/common/strato-apps/incoming/$($manifest.slug)-$release-$nonce.tar"

try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    $archiveArguments = @(
        '-C', $root, 'archive', '--format=tar', "--output=$archive", 'HEAD', '--'
    ) + @($manifest.releaseInclude | ForEach-Object { ":(literal)$([string]$_)" })
    Invoke-StratoNative -Command 'git' -Arguments $archiveArguments
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
        throw 'git archive did not create the release archive.'
    }
    $archiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()

    Invoke-StratoScp -LocalPath $archive -RemotePath $remoteArchive
    Invoke-StratoRemoteHelper -Action 'deploy' -Arguments @(
        [string]$manifest.slug,
        $release,
        $commit,
        [string]$manifest.internalPort,
        [string]$manifest.healthPath,
        [string]$manifest.pathMode,
        $remoteArchive,
        $archiveHash
    )
}
finally {
    try { Remove-StratoRemoteUpload -RemotePath $remoteArchive } catch { }
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolved = [IO.Path]::GetFullPath($temporaryRoot)
        $temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($resolved.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Path]::GetFileName($resolved) -match '^strato-app-[0-9a-f]{32}$') {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
