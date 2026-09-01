[CmdletBinding()]
param(
    [string] $SkillsRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$repositoryRoot = [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$source = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot 'codex-skill/deploy-strato-app'))
if (-not (Test-Path -LiteralPath (Join-Path $source 'SKILL.md') -PathType Leaf)) {
    throw 'Canonical deploy-strato-app skill source is missing.'
}

if ([string]::IsNullOrWhiteSpace($SkillsRoot)) {
    $codexRoot = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        [System.IO.Path]::GetFullPath($env:CODEX_HOME)
    }
    else {
        [System.IO.Path]::GetFullPath((Join-Path $env:USERPROFILE '.codex'))
    }
    $SkillsRoot = Join-Path $codexRoot 'skills'
}
$skillsRootPath = [System.IO.Path]::GetFullPath($SkillsRoot)
if ([System.IO.Path]::GetPathRoot($skillsRootPath) -eq $skillsRootPath) {
    throw 'The skills root may not be a filesystem root.'
}
New-Item -ItemType Directory -Force -Path $skillsRootPath | Out-Null

$nonce = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(16)).ToLowerInvariant()
$destination = Join-Path $skillsRootPath 'deploy-strato-app'
$stage = Join-Path $skillsRootPath ".deploy-strato-app.stage.$nonce"
$backup = Join-Path $skillsRootPath ".deploy-strato-app.backup.$nonce"
$destinationMoved = $false
$stageInstalled = $false

function Assert-SafeSiblingPath {
    param([Parameter(Mandatory)] [string] $Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    if ([System.IO.Path]::GetDirectoryName($full) -ne $skillsRootPath) {
        throw "Refusing a skill path outside $skillsRootPath."
    }
}

function Get-TreeHashes {
    param([Parameter(Mandatory)] [string] $Root)
    $map = [ordered]@{}
    Get-ChildItem -LiteralPath $Root -Recurse -File | Sort-Object FullName | ForEach-Object {
        $relative = [System.IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/')
        $map[$relative] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }
    return $map
}

function Assert-SameTree {
    param([string] $Left, [string] $Right)
    $leftHashes = Get-TreeHashes -Root $Left
    $rightHashes = Get-TreeHashes -Root $Right
    if (($leftHashes | ConvertTo-Json -Compress) -ne ($rightHashes | ConvertTo-Json -Compress)) {
        throw 'Installed skill does not exactly match the canonical repository copy.'
    }
}

Assert-SafeSiblingPath -Path $destination
Assert-SafeSiblingPath -Path $stage
Assert-SafeSiblingPath -Path $backup

$validator = Join-Path $skillsRootPath '.system/skill-creator/scripts/quick_validate.py'
if (-not (Test-Path -LiteralPath $validator -PathType Leaf)) {
    $validator = Join-Path ([System.IO.Path]::GetDirectoryName($skillsRootPath)) 'skills/.system/skill-creator/scripts/quick_validate.py'
}

try {
    if (Test-Path -LiteralPath $validator -PathType Leaf) {
        & python $validator $source
        if ($LASTEXITCODE -ne 0) { throw 'Canonical skill validation failed.' }
    }

    Copy-Item -LiteralPath $source -Destination $stage -Recurse
    Assert-SameTree -Left $source -Right $stage
    if (Test-Path -LiteralPath $validator -PathType Leaf) {
        & python $validator $stage
        if ($LASTEXITCODE -ne 0) { throw 'Staged skill validation failed.' }
    }

    if (Test-Path -LiteralPath $destination) {
        Move-Item -LiteralPath $destination -Destination $backup
        $destinationMoved = $true
    }
    Move-Item -LiteralPath $stage -Destination $destination
    $stageInstalled = $true
    Assert-SameTree -Left $source -Right $destination

    if ($destinationMoved -and (Test-Path -LiteralPath $backup)) {
        Remove-Item -LiteralPath $backup -Recurse -Force
        $destinationMoved = $false
    }

    [pscustomobject]@{
        Status = 'installed'
        Source = $source
        Destination = $destination
        Files = (Get-ChildItem -LiteralPath $destination -Recurse -File).Count
    } | ConvertTo-Json -Compress
}
catch {
    if ($stageInstalled -and (Test-Path -LiteralPath $destination)) {
        Remove-Item -LiteralPath $destination -Recurse -Force
    }
    if ($destinationMoved -and (Test-Path -LiteralPath $backup)) {
        Move-Item -LiteralPath $backup -Destination $destination
        $destinationMoved = $false
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
}
