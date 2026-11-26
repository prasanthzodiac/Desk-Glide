# Builds release\DeskGlide-<version>.zip (DeskGlide's files in a DeskGlide-<version> folder) and release\SHA256SUMS.txt.
# Everything at the top of the repository goes in except dot-files: no .git, no docs, no release folder.
# Upload both to a GitHub release tagged v<version>. Auto-update checks the zip against GitHub's own SHA256 digest.
param([string]$OutDir = (Join-Path $PSScriptRoot 'release'))
$ErrorActionPreference = 'Stop'
$ver = [regex]::Match((Get-Content -Raw (Join-Path $PSScriptRoot 'DeskGlide.ps1')), "(?m)^\`$Version = '([^']+)'").Groups[1].Value
if (-not $ver) { throw 'No $Version line in DeskGlide.ps1' }
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$name = "DeskGlide-$ver"; $zip = Join-Path $OutDir "$name.zip"
[void](New-Item -ItemType Directory -Force $OutDir)
if (Test-Path $zip) { Remove-Item $zip }
$z = [IO.Compression.ZipFile]::Open($zip, 'Create')
try {
  foreach ($f in Get-ChildItem -LiteralPath $PSScriptRoot -File | ? { $_.Name -notlike '.*' }) {
    [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $f.FullName, "$name/$($f.Name)")
  }
} finally { $z.Dispose() }
$sha = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
Set-Content (Join-Path $OutDir 'SHA256SUMS.txt') "$sha  $name.zip" -Encoding ASCII
"Built $zip"
"SHA256 $sha"
