<#
.SYNOPSIS
  Git helper for the "Review My Changes" workflow.

.DESCRIPTION
  Status  - read-only. Lists local changes grouped by type and flags Unity-specific
            problems (missing .meta pairs, large files outside LFS, main behind origin).
  Publish - stages ONLY the files in -FileList, commits them on a feature branch,
            pushes, and opens a pull request to main. Refuses to run without -Approved
            and refuses to publish to main/master.

  Nothing in this script runs on file save. Publishing always needs an explicit call.

.EXAMPLE
  ./Tools/Git/ReviewMyChanges.ps1 -Mode Status

.EXAMPLE
  ./Tools/Git/ReviewMyChanges.ps1 -Mode Publish -Approved -Branch aryan/player-movement `
      -FileList files.txt -MessageFile msg.txt -Title "Add player movement" -BodyFile body.md
#>
param(
    [Parameter(Mandatory)][ValidateSet('Status', 'Publish')][string]$Mode,
    [string]$Branch,
    [string]$FileList,
    [string]$MessageFile,
    [string]$Title,
    [string]$BodyFile,
    [string]$Base = 'main',
    [switch]$Approved
)

$ErrorActionPreference = 'Stop'
$repoRoot = (git rev-parse --show-toplevel).Trim()
Set-Location $repoRoot

function Find-Gh {
    $cmd = Get-Command gh -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $default = 'C:\Program Files\GitHub CLI\gh.exe'
    if (Test-Path $default) { return $default }
    throw 'GitHub CLI (gh) not found. Install it with: winget install --id GitHub.cli'
}

function Invoke-Git {
    git @args
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed (exit $LASTEXITCODE)" }
}

function Get-Category([string]$path) {
    switch -Regex ($path) {
        '\.cs$'                                   { return 'C# script' }
        '\.meta$'                                 { return 'Meta file' }
        '\.(unity)$'                              { return 'Scene' }
        '\.(prefab)$'                             { return 'Prefab' }
        '\.(asmdef|asmref|inputactions)$'         { return 'Config (asmdef/input)' }
        '^ProjectSettings/'                       { return 'Project settings' }
        '^Packages/'                              { return 'Packages' }
        '^Assets/'                                { return 'Asset' }
        default                                   { return 'Other' }
    }
}

if ($Mode -eq 'Status') {
    git fetch --quiet origin 2>$null
    $branch = (git branch --show-current).Trim()
    Write-Output "Branch: $branch"

    $counts = (git rev-list --left-right --count "HEAD...origin/$Base" 2>$null)
    if ($counts) {
        $ahead, $behind = $counts -split '\s+'
        Write-Output "Compared with origin/${Base}: $ahead commit(s) ahead, $behind behind"
    }

    $lines = git -c core.quotepath=off status --porcelain=v1 --untracked-files=all
    if (-not $lines) { Write-Output 'No local changes.'; return }

    $changes = foreach ($line in $lines) {
        $code = $line.Substring(0, 2)
        $path = $line.Substring(3).Trim('"')
        if ($path -like '* -> *') { $path = ($path -split ' -> ')[1] }
        $state = switch -Regex ($code) {
            '\?\?' { 'added' } 'D' { 'deleted' } 'R' { 'renamed' } 'A' { 'added' } default { 'modified' }
        }
        [pscustomobject]@{ State = $state; Category = Get-Category $path; Path = $path }
    }

    Write-Output ''
    $changes | Sort-Object Category, Path | Format-Table -AutoSize | Out-String -Width 300 | Write-Output

    # Unity needs a .meta next to every asset under Assets/ (and vice versa).
    $paths = $changes.Path
    $warnings = @()
    foreach ($c in $changes | Where-Object { $_.Path -like 'Assets/*' }) {
        if ($c.Path -like '*.meta') {
            $asset = $c.Path.Substring(0, $c.Path.Length - 5)
            if ($c.State -eq 'added' -and $paths -notcontains $asset -and -not (Test-Path $asset)) {
                $warnings += "Orphan meta (asset missing): $($c.Path)"
            }
        } elseif ($c.State -in 'added', 'deleted' -and $paths -notcontains "$($c.Path).meta") {
            $warnings += "Missing .meta change for $($c.State) asset: $($c.Path)"
        }
    }
    foreach ($c in $changes | Where-Object { $_.State -ne 'deleted' -and (Test-Path -LiteralPath $_.Path -PathType Leaf) }) {
        $size = (Get-Item -LiteralPath $c.Path).Length
        if ($size -gt 10MB) {
            $filter = (git check-attr filter -- $c.Path) -replace '.*: filter: ', ''
            if ($filter -ne 'lfs') { $warnings += "Large file NOT in LFS ($([math]::Round($size / 1MB, 1)) MB): $($c.Path)" }
        }
    }
    if ($warnings) {
        Write-Output 'Warnings:'
        $warnings | ForEach-Object { Write-Output "  - $_" }
    }
    return
}

# ---------------- Publish ----------------
if (-not $Approved) { throw 'Refusing to publish: -Approved was not given. Changes must be approved first.' }
foreach ($p in 'Branch', 'FileList', 'MessageFile', 'Title', 'BodyFile') {
    if (-not (Get-Variable $p -ValueOnly)) { throw "-$p is required for Publish." }
}
if ($Branch -in 'main', 'master', $Base) { throw "Refusing to publish directly to '$Branch'. Use a feature branch." }
if ($Branch -notmatch '^[a-z0-9]+/[a-z0-9][a-z0-9._-]*$') { throw "Branch '$Branch' should look like name/short-feature (lowercase)." }

$files = Get-Content -LiteralPath $FileList | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() }
if (-not $files) { throw 'File list is empty.' }

$gh = Find-Gh

$current = (git branch --show-current).Trim()
if ($current -ne $Branch) {
    git show-ref --verify --quiet "refs/heads/$Branch"
    if ($LASTEXITCODE -eq 0) { Invoke-Git switch $Branch }   # uncommitted changes carry over
    else { Invoke-Git switch -c $Branch }
}

# Stage exactly the approved files, nothing else.
Invoke-Git reset -q
foreach ($f in $files) { Invoke-Git add -A -- $f }

$staged = git -c core.quotepath=off diff --cached --name-only
if (-not $staged) { throw 'Nothing staged. Check the file list.' }
$unexpected = $staged | Where-Object { $files -notcontains $_ }
if ($unexpected) { throw "Unexpected files staged: $($unexpected -join ', ')" }

Write-Output 'Committing:'
git diff --cached --stat | Write-Output
Invoke-Git commit -q -F $MessageFile
Invoke-Git push -u origin $Branch

$existing = & $gh pr list --head $Branch --base $Base --state open --json url --jq '.[0].url'
if ($existing) {
    Write-Output "Pushed to existing pull request: $existing"
} else {
    & $gh pr create --base $Base --head $Branch --title $Title --body-file $BodyFile
    if ($LASTEXITCODE -ne 0) { throw 'gh pr create failed.' }
}
