# MEML CLI installer for Windows.
#
# Usage (PowerShell):
#   irm https://mindon.dev/meml/install.ps1 | iex
#   irm https://mindon.dev/meml/install.ps1 | iex -args <version>
#
# Installs meml.exe into %USERPROFILE%\.meml\bin and adds it to your user PATH.

param(
    [string]$Version = "latest"
)

$ErrorActionPreference = "Stop"

$Repo = "mindon/meml"
$BaseDir = if ($env:MEML_INSTALL_DIR) { $env:MEML_INSTALL_DIR } else { Join-Path $HOME ".meml" }
$BinDir = Join-Path $BaseDir "bin"

function Info($msg)  { Write-Host "[meml] " -NoNewline -ForegroundColor Cyan; Write-Host $msg }
function Success($msg) { Write-Host "[meml] " -NoNewline -ForegroundColor Green; Write-Host $msg }
function Warn($msg)  { Write-Host "[meml] " -NoNewline -ForegroundColor Yellow; Write-Host $msg }
function Error($msg) { Write-Host "[meml] " -NoNewline -ForegroundColor Red; Write-Host $msg }

# MEML ships a single x86_64 Windows build (runs on ARM64 via x64 emulation).
$Asset = "meml-x86_64-windows.zip"

if ($Version -eq "latest") {
    $Url = "https://github.com/$Repo/releases/latest/download/$Asset"
} else {
    $Url = "https://github.com/$Repo/releases/download/$Version/$Asset"
}

$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("meml-install-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null
$ZipPath = Join-Path $TempDir $Asset

try {
    Info "Downloading $Asset ..."
    Invoke-WebRequest -Uri $Url -OutFile $ZipPath -UseBasicParsing

    Info "Extracting ..."
    Expand-Archive -Path $ZipPath -DestinationPath $TempDir -Force

    New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
    $Exe = Get-ChildItem -Path $TempDir -Recurse -Filter "meml.exe" | Select-Object -First 1
    if (-not $Exe) {
        Error "meml.exe not found in the downloaded archive."
        exit 1
    }
    Copy-Item -Path $Exe.FullName -Destination (Join-Path $BinDir "meml.exe") -Force
    Success "Installed meml -> $(Join-Path $BinDir 'meml.exe')"
}
finally {
    Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
}

# Add %USERPROFILE%\.meml\bin to the user PATH (persistent, no admin required).
$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
if (-not $UserPath) { $UserPath = "" }

if ($UserPath -split ";" -notcontains $BinDir) {
    $NewPath = if ($UserPath.TrimEnd(';') -eq "") { $BinDir } else { "$UserPath;$BinDir" }
    [Environment]::SetEnvironmentVariable("Path", $NewPath, "User")
    # Refresh the current session's PATH so `meml` works right away.
    $env:Path = "$BinDir;" + $env:Path
    Info "Added $BinDir to the user PATH."
} else {
    Info "$BinDir is already on the user PATH."
}

Write-Host ""
Success "MEML CLI installed successfully."
Write-Host ""
Info "Try it out:"
Write-Host "  meml --help"
Write-Host "  meml '{\"op\":\"ping\"}'"
Write-Host ""
Info "Docs & integrations: https://github.com/mindon/meml"
