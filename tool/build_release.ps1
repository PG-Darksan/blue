# アプリをビルドして、リリース用ファイルを dist/ に出力するスクリプト
#   pwsh tool/build_release.ps1            # Android と Windows
#   pwsh tool/build_release.ps1 android    # Android だけ
#   pwsh tool/build_release.ps1 windows    # Windows だけ
param([ValidateSet('all', 'android', 'windows')][string]$Target = 'all')

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root

$version = (Select-String -Path pubspec.yaml -Pattern '^version:\s*([0-9.]+)').Matches[0].Groups[1].Value
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null

if ($Target -in 'all', 'android') {
    flutter build apk --release
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
    Copy-Item build/app/outputs/flutter-apk/app-release.apk (Join-Path $dist "blue-$version-android.apk") -Force
}
if ($Target -in 'all', 'windows') {
    flutter build windows --release
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
    Compress-Archive -Path build/windows/x64/runner/Release/* `
        -DestinationPath (Join-Path $dist "blue-$version-windows-x64.zip") -Force
}

Get-ChildItem $dist -Filter "blue-$version-*" | Format-Table Name, Length
