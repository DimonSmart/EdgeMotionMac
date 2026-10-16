param(
    [string] $Remote = "origin",
    [string] $Branch = "main",
    [string] $FirstVersion = "0.1.0",
    [ValidateSet("Patch", "Minor", "Major")]
    [string] $Bump = "Patch"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Invoke-Git {
    param([Parameter(Mandatory = $true)][string[]] $Arguments)

    $output = & git @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed (exit $LASTEXITCODE)."
    }
    return $output
}

if ($FirstVersion -notmatch '^\d+\.\d+\.\d+$') {
    throw "FirstVersion must be MAJOR.MINOR.PATCH."
}

$root = (Invoke-Git -Arguments @("rev-parse", "--show-toplevel")).Trim()
Push-Location $root
try {
    if (Invoke-Git -Arguments @("status", "--porcelain")) {
        throw "Working tree is not clean. Commit or stash changes first."
    }

    Invoke-Git -Arguments @("fetch", "--prune", "--tags", $Remote) | Out-Null
    Invoke-Git -Arguments @("switch", $Branch) | Out-Null
    Invoke-Git -Arguments @("pull", "--ff-only", $Remote, $Branch) | Out-Null

    $versions = @(Invoke-Git -Arguments @("tag", "--list", "v*") |
        ForEach-Object {
            if ($_ -match '^v(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)$') {
                [pscustomobject]@{
                    Major = [int]$Matches.major
                    Minor = [int]$Matches.minor
                    Patch = [int]$Matches.patch
                }
            }
        } | Sort-Object Major, Minor, Patch)

    if ($versions.Count -eq 0) {
        $nextVersion = $FirstVersion
    }
    else {
        $last = $versions[-1]
        switch ($Bump) {
            "Major" { $nextVersion = "$($last.Major + 1).0.0" }
            "Minor" { $nextVersion = "$($last.Major).$($last.Minor + 1).0" }
            default { $nextVersion = "$($last.Major).$($last.Minor).$($last.Patch + 1)" }
        }
    }

    $tag = "v$nextVersion"
    if (Invoke-Git -Arguments @("tag", "--list", $tag)) {
        throw "Tag $tag already exists."
    }

    Write-Host "Publishing $tag from $Branch..."
    Invoke-Git -Arguments @("tag", "-a", $tag, "-m", "Release $tag") | Out-Null
    Invoke-Git -Arguments @("push", $Remote, "refs/tags/$tag") | Out-Null
    Write-Host "Pushed $tag. GitHub Actions will publish the unsigned app and update Homebrew."
}
finally {
    Pop-Location
}
