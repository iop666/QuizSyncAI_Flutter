# QuizSync AI one-shot build: pub get + analyze + tests (if present) + both release builds.
# Any failure aborts with non-zero exit. Usage: powershell -File tools\build_all.ps1
$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
# Flutter / Dart 的位置：优先环境变量 FLUTTER / DART，否则用 PATH 里的 flutter / dart。
# （发布源码不写死任何本机路径。）
$Flutter = if ($env:FLUTTER) { $env:FLUTTER } else { "flutter" }
$Dart = if ($env:DART) { $env:DART } else { "dart" }

function Run-Step([string]$name, [string]$workDir, [string[]]$argv) {
  Write-Host ("==> " + $name) -ForegroundColor Cyan
  $prev = Get-Location
  try {
    Set-Location $workDir
    & $argv[0] $argv[1..($argv.Length - 1)]
    if ($LASTEXITCODE -ne 0) {
      Write-Host ("FAILED: " + $name + " (exit " + $LASTEXITCODE + ")") -ForegroundColor Red
      exit $LASTEXITCODE
    }
  } finally {
    Set-Location $prev
  }
}

Run-Step "core: pub get"    (Join-Path $RepoRoot "packages\quizsync_core") @($Flutter, "pub", "get")
Run-Step "ui: pub get"      (Join-Path $RepoRoot "packages\quizsync_ui") @($Flutter, "pub", "get")
Run-Step "desktop: pub get" (Join-Path $RepoRoot "apps\desktop") @($Flutter, "pub", "get")
Run-Step "android: pub get" (Join-Path $RepoRoot "apps\android") @($Flutter, "pub", "get")

Run-Step "core: analyze"    (Join-Path $RepoRoot "packages\quizsync_core") @($Flutter, "analyze")
Run-Step "ui: analyze"      (Join-Path $RepoRoot "packages\quizsync_ui") @($Flutter, "analyze")
Run-Step "desktop: analyze" (Join-Path $RepoRoot "apps\desktop") @($Flutter, "analyze")
Run-Step "android: analyze" (Join-Path $RepoRoot "apps\android") @($Flutter, "analyze")

# 发布源码不含测试：没有 test 目录时跳过这一步（开发版带测试，会正常执行）。
function Run-Tests([string]$name, [string]$workDir, [string]$exe) {
  if (-not (Test-Path (Join-Path $workDir "test"))) {
    Write-Host ("==> " + $name + "（无 test 目录，跳过）") -ForegroundColor DarkGray
    return
  }
  Run-Step $name $workDir @($exe, "test")
}

Run-Tests "core: test"    (Join-Path $RepoRoot "packages\quizsync_core") $Dart
Run-Tests "ui: test"      (Join-Path $RepoRoot "packages\quizsync_ui") $Flutter
Run-Tests "desktop: test" (Join-Path $RepoRoot "apps\desktop") $Flutter
Run-Tests "android: test" (Join-Path $RepoRoot "apps\android") $Flutter

# 图标字体**不做 tree-shake**（用户反馈 4：应用内大量图标丢失/显示异常）。
# Flutter 的图标 tree-shaking 在本项目上只保留了约 4.5KB 字形（完整字体 1.6MB），
# 结果是设置页、关于页等处的图标变成空白/豆腐块。多带 1.6MB 换取「图标一定在」。
Run-Step "desktop: build windows release" (Join-Path $RepoRoot "apps\desktop") @($Flutter, "build", "windows", "--release", "--no-tree-shake-icons")
Run-Step "android: build apk release"     (Join-Path $RepoRoot "apps\android") @($Flutter, "build", "apk", "--split-per-abi", "--release", "--no-tree-shake-icons")

# 打包交付物：安卓 APK → dist\（quizsync-android-<abi>-<版本>.apk）
# + 便携版 zip + Inno Setup 安装包（安装版一律走 Inno Setup 封装）。
# 机器上没装 ISCC.exe 时 package_windows 只出 zip 并打印跳过说明，不算失败。
Write-Host "==> package: android apks" -ForegroundColor Cyan
& powershell -NoProfile -File (Join-Path $PSScriptRoot "package_android.ps1")
if ($LASTEXITCODE -ne 0) {
  Write-Host "FAILED: package_android.ps1" -ForegroundColor Red
  exit $LASTEXITCODE
}

# M24：交付物安全审计（包名/版本/权限白名单/备份策略/明文开关/签名/包内红线）。
# 放在 package 之后、Windows 打包之前：APK 一定已经落到 dist\ 了。
Write-Host "==> audit: android apks (M24)" -ForegroundColor Cyan
& powershell -NoProfile -File (Join-Path $PSScriptRoot "audit_android.ps1")
if ($LASTEXITCODE -ne 0) {
  Write-Host "FAILED: audit_android.ps1（安卓交付物未通过安全审计）" -ForegroundColor Red
  exit $LASTEXITCODE
}

Write-Host "==> package: portable zip + Inno Setup installer" -ForegroundColor Cyan
& powershell -NoProfile -File (Join-Path $PSScriptRoot "package_windows.ps1")
if ($LASTEXITCODE -ne 0) {
  Write-Host "FAILED: package_windows.ps1" -ForegroundColor Red
  exit $LASTEXITCODE
}

Write-Host "ALL GREEN" -ForegroundColor Green
exit 0
