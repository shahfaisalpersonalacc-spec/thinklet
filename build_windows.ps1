# Builds the Windows app. It signs in and talks to the Vercel backend, so
# no API key or password is put inside the .exe.
#
#   .\build_windows.ps1
#   .\build_windows.ps1 -Api https://my-other-deploy.vercel.app/api
param([string]$Api = 'https://thinklet-six.vercel.app/api')
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

Get-Process thinklet -ErrorAction SilentlyContinue | Stop-Process -Force
flutter build windows --release --dart-define=API_BASE=$Api
if ($LASTEXITCODE -ne 0) { throw 'flutter build windows failed' }
Write-Host "Built: build\windows\x64\runner\Release\thinklet.exe (backend: $Api)"
