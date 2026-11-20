# Copies the Thinklet login settings from .env to the Vercel project.
# Run it yourself after editing .env:   .\set_vercel_env.ps1
#
# - Needs APP_USERNAME and APP_PASSWORD in .env.
# - Adds a random AUTH_SECRET to .env if it has none.
# - Never prints the values. Then redeploy (push) so they take effect.
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$envFile = Join-Path $PSScriptRoot '.env'
if (-not (Test-Path $envFile)) { throw '.env not found next to this script.' }

function Read-DotEnv {
  $vals = @{}
  foreach ($line in Get-Content $envFile) {
    if ($line -match '^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$') {
      $vals[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
    }
  }
  return $vals
}

$vals = Read-DotEnv
foreach ($name in 'APP_USERNAME', 'APP_PASSWORD') {
  if (-not $vals[$name]) { throw "Add $name=... to .env first." }
}
if (-not $vals['AUTH_SECRET']) {
  $bytes = New-Object byte[] 48
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  $secret = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
  Add-Content $envFile "`nAUTH_SECRET=$secret"
  $vals['AUTH_SECRET'] = $secret
  Write-Host 'Created a new AUTH_SECRET in .env.'
}

Set-Location (Join-Path $PSScriptRoot 'vercel')
foreach ($name in 'APP_USERNAME', 'APP_PASSWORD', 'AUTH_SECRET') {
  # Replace any old value, then add the new one (read from stdin, not shown).
  npx --yes vercel@latest env rm $name production --yes *> $null
  $vals[$name] | npx --yes vercel@latest env add $name production *> $null
  if ($LASTEXITCODE -ne 0) { throw "Could not set $name on Vercel." }
  Write-Host "Set $name on Vercel."
}
Write-Host 'Done. Push (or redeploy) so the new settings take effect.'
