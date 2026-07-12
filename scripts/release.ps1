# Build and package release artifacts locally, mirroring .github/workflows/release.yml.
# Prints SHA256 hashes for the winget manifest.
param([string]$Version)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

if (-not $Version) {
    $zon = Get-Content (Join-Path $root 'build.zig.zon') -Raw
    $Version = [regex]::Match($zon, '\.version\s*=\s*"([^"]+)"').Groups[1].Value
    if (-not $Version) { throw 'Could not read .version from build.zig.zon' }
}

Push-Location $root
try {
    zig build release
    if ($LASTEXITCODE -ne 0) { throw "zig build release failed ($LASTEXITCODE)" }

    $dist = Join-Path $root 'dist'
    New-Item -ItemType Directory -Force $dist | Out-Null

    $zip = Join-Path $dist "dygmate-$Version-windows-x86_64.zip"
    Compress-Archive -Force -DestinationPath $zip -Path @(
        (Join-Path $root 'zig-out\windows\dygmate.exe'),
        (Join-Path $root 'zig-out\windows\dygmate-tray.exe')
    )

    $tarball = Join-Path $dist "dygmate-$Version-linux-x86_64.tar.gz"
    tar -czf $tarball -C (Join-Path $root 'zig-out\linux') dygmate dygmate-tray
    if ($LASTEXITCODE -ne 0) { throw "tar failed ($LASTEXITCODE)" }

    Get-FileHash -Algorithm SHA256 $zip, $tarball |
        ForEach-Object { "$($_.Hash)  $(Split-Path -Leaf $_.Path)" } |
        Tee-Object -FilePath (Join-Path $dist 'SHA256SUMS.txt')
} finally {
    Pop-Location
}
