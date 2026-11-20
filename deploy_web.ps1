# Builds the web app WITHOUT the API key and deploys it to Vercel.
# The key lives only in the Vercel project (ANTHROPIC_API_KEY env var);
# the app calls /api/claude (vercel/api/claude.js), which adds it.
#
#   .\deploy_web.ps1          production deploy
#   .\deploy_web.ps1 -Preview preview deploy (separate test URL)
param([switch]$Preview)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

# Never --dart-define-from-file=.env here: that would put the key in the JS.
flutter build web --release --dart-define=CLAUDE_PROXY=/api/claude
if ($LASTEXITCODE -ne 0) { throw 'flutter build web failed' }

$public = Join-Path $PSScriptRoot 'vercel\public'
if (Test-Path $public) { Remove-Item $public -Recurse -Force }
Copy-Item build\web $public -Recurse

Set-Location vercel
if ($Preview) { npx vercel@latest deploy } else { npx vercel@latest deploy --prod }
