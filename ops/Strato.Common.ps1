Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$script:StratoTarget = 'root@h2769124.stratoserver.net'
$script:GatewayRoot = '/var/snap/docker/common/strato-apps/gateway'
$script:SshOptions = @(
    '-T',
    '-o', 'BatchMode=yes',
    '-o', 'PasswordAuthentication=no',
    '-o', 'KbdInteractiveAuthentication=no',
    '-o', 'StrictHostKeyChecking=yes',
    '-o', 'ConnectTimeout=10',
    '-o', 'ServerAliveInterval=15',
    '-o', 'ServerAliveCountMax=2'
)
$script:ScpOptions = @(
    '-q',
    '-o', 'BatchMode=yes',
    '-o', 'PasswordAuthentication=no',
    '-o', 'KbdInteractiveAuthentication=no',
    '-o', 'StrictHostKeyChecking=yes',
    '-o', 'ConnectTimeout=10',
    '-o', 'ServerAliveInterval=15',
    '-o', 'ServerAliveCountMax=2'
)

function Invoke-CheckedNative {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [Parameter()] [string[]] $ArgumentList = @(),
        [switch] $Capture
    )

    if ($Capture) {
        $output = & $FilePath @ArgumentList
        if ($LASTEXITCODE -ne 0) {
            throw "$FilePath exited with code $LASTEXITCODE."
        }
        return @($output)
    }

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath exited with code $LASTEXITCODE."
    }
}

function Get-RepositoryRoot {
    $root = (@(Invoke-CheckedNative -FilePath git -ArgumentList @('rev-parse', '--show-toplevel') -Capture))[0].Trim()
    return [System.IO.Path]::GetFullPath($root)
}

function Assert-CleanPushedRelease {
    param([Parameter(Mandatory)] [string] $RepositoryRoot)

    Push-Location $RepositoryRoot
    try {
        $dirty = @(Invoke-CheckedNative -FilePath git -ArgumentList @('status', '--porcelain=v1', '--untracked-files=all') -Capture)
        if ($dirty.Count -gt 0) {
            throw 'Production deployment requires a clean Git worktree.'
        }

        $commit = (@(Invoke-CheckedNative -FilePath git -ArgumentList @('rev-parse', 'HEAD') -Capture))[0].Trim()
        if ($commit -notmatch '^[0-9a-f]{40}$') {
            throw 'Could not resolve a full release commit.'
        }

        $branch = (@(Invoke-CheckedNative -FilePath git -ArgumentList @('symbolic-ref', '--quiet', '--short', 'HEAD') -Capture))[0].Trim()
        if ([string]::IsNullOrWhiteSpace($branch)) {
            throw 'Production deployment requires a named branch.'
        }

        $remoteNames = @(Invoke-CheckedNative -FilePath git -ArgumentList @('remote') -Capture)
        if ($remoteNames.Count -eq 0) {
            throw 'No Git remote is configured. Add the real repository remote and push this release before deploying.'
        }

        $upstream = (@(Invoke-CheckedNative -FilePath git -ArgumentList @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}') -Capture))[0].Trim()
        if ($upstream -notmatch '^([^/]+)/(.+)$') {
            throw 'The current branch has no usable upstream. Configure and push it before deploying.'
        }
        $remote = $Matches[1]
        Invoke-CheckedNative -FilePath git -ArgumentList @('fetch', '--quiet', '--prune', $remote)
        $upstreamCommit = (@(Invoke-CheckedNative -FilePath git -ArgumentList @('rev-parse', '@{upstream}') -Capture))[0].Trim()
        if ($upstreamCommit -ne $commit) {
            throw "Local HEAD is not the pushed upstream commit ($upstream)."
        }

        [pscustomobject]@{
            Commit = $commit
            Branch = $branch
            Upstream = $upstream
        }
    }
    finally {
        Pop-Location
    }
}

function Invoke-StratoSsh {
    param([Parameter(Mandatory)] [string] $RemoteCommand)

    Invoke-CheckedNative -FilePath ssh -ArgumentList @($script:SshOptions + @($script:StratoTarget, $RemoteCommand))
}
