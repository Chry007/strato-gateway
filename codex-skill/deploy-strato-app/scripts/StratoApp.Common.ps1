Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$script:StratoHost = 'root@h2769124.stratoserver.net'
$script:SshOptions = @(
    '-o', 'BatchMode=yes',
    '-o', 'StrictHostKeyChecking=yes',
    '-o', 'ConnectTimeout=15',
    '-o', 'ServerAliveInterval=15',
    '-o', 'ServerAliveCountMax=2'
)

function Get-StratoProjectRoot {
    param([Parameter(Mandatory)][string] $Path)

    $root = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "Project root does not exist: $root"
    }
    return $root
}

function Invoke-StratoNative {
    param(
        [Parameter(Mandatory)][string] $Command,
        [Parameter(Mandatory)][string[]] $Arguments,
        [int[]] $AllowedExitCodes = @(0),
        [switch] $Capture
    )

    $output = @(& $Command @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -notin $AllowedExitCodes) {
        $detail = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = "exit code $exitCode" }
        throw "$Command failed: $detail"
    }
    if ($Capture) {
        return (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
    }
    $output | ForEach-Object { Write-Output $_ }
}

function Get-StratoManifest {
    param([Parameter(Mandatory)][string] $ProjectRoot)

    $validator = Join-Path $PSScriptRoot 'validate-project.ps1'
    $json = Invoke-StratoNative -Command 'pwsh' -Arguments @(
        '-NoProfile', '-File', $validator, '-ProjectRoot', $ProjectRoot
    ) -Capture
    return $json | ConvertFrom-Json -Depth 20
}

function Test-StratoSelectionContains {
    param(
        [Parameter(Mandatory)] $Manifest,
        [Parameter(Mandatory)][string] $Path
    )

    foreach ($entryValue in @($Manifest.releaseInclude)) {
        $entry = [string]$entryValue
        if ($entry -eq $Path -or $Path.StartsWith("$entry/", [StringComparison]::Ordinal)) {
            return $true
        }
    }
    return $false
}

function Assert-StratoGitRelease {
    param([Parameter(Mandatory)][string] $ProjectRoot)

    $inside = Invoke-StratoNative -Command 'git' -Arguments @(
        '-C', $ProjectRoot, 'rev-parse', '--is-inside-work-tree'
    ) -Capture
    if ($inside -ne 'true') { throw 'The application must be a Git working tree.' }

    $status = Invoke-StratoNative -Command 'git' -Arguments @(
        '-C', $ProjectRoot, 'status', '--porcelain=v1', '--untracked-files=normal'
    ) -Capture
    if (-not [string]::IsNullOrWhiteSpace($status)) {
        throw 'The application release must be clean, including untracked files.'
    }

    $branch = Invoke-StratoNative -Command 'git' -Arguments @(
        '-C', $ProjectRoot, 'symbolic-ref', '--quiet', '--short', 'HEAD'
    ) -Capture
    if ([string]::IsNullOrWhiteSpace($branch)) { throw 'Deploy from a named branch, not detached HEAD.' }

    $remote = Invoke-StratoNative -Command 'git' -Arguments @(
        '-C', $ProjectRoot, 'config', '--get', "branch.$branch.remote"
    ) -AllowedExitCodes @(0, 1) -Capture
    if ([string]::IsNullOrWhiteSpace($remote) -or $remote -eq '.') {
        throw 'The current branch needs a real upstream remote.'
    }
    Invoke-StratoNative -Command 'git' -Arguments @(
        '-C', $ProjectRoot, 'remote', 'get-url', $remote
    ) -Capture | Out-Null

    $upstream = Invoke-StratoNative -Command 'git' -Arguments @(
        '-C', $ProjectRoot, 'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}'
    ) -Capture
    Invoke-StratoNative -Command 'git' -Arguments @(
        '-C', $ProjectRoot, 'fetch', '--quiet', $remote
    )

    $head = Invoke-StratoNative -Command 'git' -Arguments @(
        '-C', $ProjectRoot, 'rev-parse', 'HEAD'
    ) -Capture
    $pushed = Invoke-StratoNative -Command 'git' -Arguments @(
        '-C', $ProjectRoot, 'rev-parse', $upstream
    ) -Capture
    if ($head -notmatch '^[0-9a-f]{40}$' -or $head -ne $pushed) {
        throw 'HEAD must equal the freshly fetched upstream commit before deployment.'
    }
    return $head
}

function Invoke-StratoProjectCheck {
    param(
        [Parameter(Mandatory)][string] $ProjectRoot,
        [Parameter(Mandatory)] $Manifest
    )

    $relative = 'ops/check-strato.ps1'
    $check = Join-Path $ProjectRoot $relative
    if (-not (Test-Path -LiteralPath $check -PathType Leaf)) {
        throw "Missing $relative. It must run this application's normal tests and build."
    }
    if (-not (Test-StratoSelectionContains -Manifest $Manifest -Path $relative)) {
        throw "$relative must be selected by releaseInclude."
    }

    Push-Location $ProjectRoot
    try {
        Invoke-StratoNative -Command 'pwsh' -Arguments @('-NoProfile', '-File', $check)
    }
    finally {
        Pop-Location
    }
}

function Invoke-StratoRemoteHelper {
    param(
        [Parameter(Mandatory)][string] $Action,
        [Parameter(Mandatory)][string[]] $Arguments
    )

    $helperPath = Join-Path $PSScriptRoot 'remote-app.sh'
    if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
        throw "Missing skill helper: $helperPath"
    }
    $helper = [System.IO.File]::ReadAllText($helperPath)
    $sshArguments = @($script:SshOptions) + @(
        $script:StratoHost, 'bash', '-s', '--', $Action
    ) + $Arguments
    $helper | & ssh @sshArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Remote STRATO $Action operation failed with exit code $LASTEXITCODE."
    }
}

function Invoke-StratoScp {
    param(
        [Parameter(Mandatory)][string] $LocalPath,
        [Parameter(Mandatory)][string] $RemotePath
    )

    $destination = "${script:StratoHost}:$RemotePath"
    Invoke-StratoNative -Command 'scp' -Arguments (@($script:SshOptions) + @(
        '--', $LocalPath, $destination
    ))
}

function Remove-StratoRemoteUpload {
    param([Parameter(Mandatory)][string] $RemotePath)

    if ($RemotePath -notmatch '^/var/snap/docker/common/strato-apps/incoming/[a-z][a-z0-9-]{1,30}-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{32}\.tar$') {
        throw 'Refusing to clean an unexpected remote upload path.'
    }
    & ssh @script:SshOptions $script:StratoHost rm -f -- $RemotePath *> $null
}
