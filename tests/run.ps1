# 自動のテスト（Qpen・copathy・M04 で同じファイル）。ファイルの決まり、更新の確かめ方、ログの書き方を試す。
# 更新の確かめ方とログは、本体から $checkUpdate と Write-Log を取り出し、ネットの代わりに手元の文字を返して動かす。
# 使い方: powershell -NoProfile -ExecutionPolicy Bypass -File tests\run.ps1（失敗があれば終了コード 1）
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$main = (Get-ChildItem $root -Filter *.ps1 | Where-Object Name -ne 'install.ps1' | Select-Object -First 1).FullName
$script:failures = 0

function Check($name, [scriptblock]$test) {
    try { $ok = & $test } catch { $ok = $false; $name += " ($_)" }
    if ($ok) { Write-Host "OK $name" } else { Write-Host "NG $name"; $script:failures++ }
}

# ---- ファイルの決まり ----
foreach ($f in Get-ChildItem $root, $PSScriptRoot, (Join-Path $root 'tools') -File -ErrorAction SilentlyContinue | Where-Object Extension -in '.ps1', '.vbs') {
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    Check "$($f.Name): 改行が CRLF" { ([regex]::Matches($text, "`n").Count) -eq ([regex]::Matches($text, "`r`n").Count) }
    if ($f.Extension -ne '.ps1') { continue }
    Check "$($f.Name): UTF-8 BOM 付き" { $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF }
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
    Check "$($f.Name): 構文エラーが無い" { $errors.Count -eq 0 }
}
Check '$Version の書き方' { [IO.File]::ReadAllText($main) -match "(?m)^\`$Version\s*=\s*'\d+\.\d+\.\d+'" }

$ast = [Management.Automation.Language.Parser]::ParseFile($main, [ref]$null, [ref]$null)
$checkUpdate = $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$checkUpdate' }, $true).Right.Expression.ScriptBlock.GetScriptBlock()
$writeLog = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Write-Log' }, $true).Extent.Text

# ---- 更新の確かめ方 ----
# $served が配っている版の中身。$null なら通信の失敗にする
$script:served = $null
function Invoke-RestMethod { if ($null -eq $script:served) { throw '通信の失敗' }; [pscustomobject]@{ tag_name = 'v0.0.0' } }
function Invoke-WebRequest {
    param($Uri, $OutFile, [switch]$UseBasicParsing, $TimeoutSec, $Headers)
    if ($null -eq $script:served) { throw '通信の失敗' }
    [IO.File]::WriteAllText($OutFile, $script:served, (New-Object Text.UTF8Encoding $true))
}
function Serve($version) { $script:served = "`$Version = '$version'`r`nWrite-Host 'テスト'`r`n" }
# 見つかった版を返し、無ければ 空。1つ目の引数（M04 は URL、Qpen・copathy はリポジトリ名）はまねた通信では使わない
function Find-Update($current, $skip = '', $manual = $false) {
    $r = & $checkUpdate 'test' $current $skip $manual
    if ($r.Path) { Remove-Item $r.Path -ErrorAction SilentlyContinue }
    if ($r) { $r.Version } else { '' }
}

Serve '1.6.0'; Check '新しい版を受け取る' { (Find-Update '1.5.0') -eq '1.6.0' }
Serve '1.5.0'; Check '同じ版は受け取らない' { (Find-Update '1.5.0') -eq '' }
Serve '1.4.0'; Check '古い版は受け取らない' { (Find-Update '1.5.0') -eq '' }
Serve '1.10.0'; Check '版を数として比べる（1.10.0 > 1.9.0）' { (Find-Update '1.9.0') -eq '1.10.0' }
Serve '1.6.0'; Check '飛ばす版は自動では受け取らない' { (Find-Update '1.5.0' '1.6.0') -eq '' }
Serve '1.6.0'; Check '飛ばす版も手動なら受け取る' { (Find-Update '1.5.0' '1.6.0' $true) -eq '1.6.0' }
$script:served = "`$Version = '9.0.0'`r`nif ( {`r`n"; Check '構文の壊れた版はエラーにする' { try { Find-Update '1.5.0'; $false } catch { $true } }
$script:served = "Write-Host 'テスト'`r`n"; Check '版の書かれていないものはエラーにする' { try { Find-Update '1.5.0'; $false } catch { $true } }
$script:served = $null; Check '通信の失敗はエラーにする' { try { Find-Update '1.5.0'; $false } catch { $true } }

# ---- ログ ----
# Qpen・copathy は $appDir・$logFile、M04 は $InstallDir・$LogFile を使う（大文字と小文字は区別されない）
$appDir = $InstallDir = Join-Path $env:TEMP "test-log-$PID"
New-Item -ItemType Directory -Force $appDir | Out-Null
$logFile = Join-Path $appDir 'log.txt'
. ([scriptblock]::Create($writeLog))
try {
    Write-Log "1行目`r`n2行目"
    Check 'ログは改行を | にして1行で書く' { (Get-Content $logFile -Encoding UTF8 -Tail 1) -match "\[$PID\] 1行目 \| 2行目$" }
    [IO.File]::WriteAllText($logFile, ('x' * 110KB))
    Write-Log '回したあと'
    Check 'ログは 100KB を超えたら log.old.txt に回す' { (Test-Path (Join-Path $appDir 'log.old.txt')) -and (Get-Item $logFile).Length -lt 1KB }
} finally { Remove-Item $appDir -Recurse -Force }

# ---- ツールごとのテスト（tests\<本体の名前>.ps1 があれば読み込む。$main・$ast・Check を使える） ----
$own = Join-Path $PSScriptRoot (Split-Path $main -Leaf)
if (Test-Path $own) { . $own }

Write-Host "`n失敗 $script:failures 件"
exit [int]($script:failures -gt 0)
