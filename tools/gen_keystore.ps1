# 生成 release 签名 keystore（仅首次；之后复用）。
# 口令不写进任何脚本/仓库——构建时经 key.properties（已 gitignore）读取。
$ErrorActionPreference = "Stop"
if ($args.Count -lt 4) {
  Write-Host "用法: gen_keystore.ps1 <输出路径> <别名> <口令> <有效天数(默认 10950)>"
  exit 1
}
$out = $args[0]; $alias = $args[1]; $storepass = $args[2]
 $validity = if ($args.Count -ge 4) { $args[3] } else { 10950 }
# keytool 的位置：优先 $env:JAVA_HOME\bin\keytool.exe，否则用 PATH 里的 keytool。
$jdk = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME "bin\keytool.exe" } else { "keytool" }
& $jdk -genkeypair -v `
  -keystore $out -alias $alias `
  -keyalg RSA -keysize 2048 -validity $validity `
  -storepass $storepass -keypass $storepass `
  -dname "CN=QuizSync AI, OU=Personal, O=Personal, C=CN"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host "keystore 已生成：$out"
Write-Host "请把口令保存在密码管理器中；keystore 备份说明见 README。"
