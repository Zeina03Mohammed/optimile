# Build Flutter web and copy into backend static/ for deployment.
# Run from repo root: .\scripts\build_web_for_deploy.ps1
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$flutterDir = Join-Path $root "flutter_application_1"
$staticDir = Join-Path $root "static"

if (-not (Test-Path $flutterDir)) {
    Write-Error "Flutter app not found at $flutterDir"
}
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    Write-Error "Flutter not in PATH. Install Flutter and run from a shell that has 'flutter'."
}

Write-Host "Building Flutter web..."
Set-Location $flutterDir
flutter pub get
flutter build web
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Copying build to static/..."
if (Test-Path $staticDir) { Remove-Item $staticDir -Recurse -Force }
New-Item -ItemType Directory -Path $staticDir | Out-Null
Copy-Item -Path (Join-Path $flutterDir "build\web\*") -Destination $staticDir -Recurse

Set-Location $root
Write-Host "Done. static/ is ready. Commit and push to deploy."
Write-Host "  git add static/"
Write-Host "  git commit -m 'Update web build for deploy'"
Write-Host "  git push"
