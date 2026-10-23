# 自動のテスト。ファイルの決まり、更新の確かめ方、ログの書き方を試す。
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
# *.ps1 は BOM 付き（無いと日本語が化ける）。改行は LF でも CRLF でも動く
foreach ($f in Get-ChildItem $root, $PSScriptRoot, (Join-Path $root 'tools'), (Join-Path $root '.github\scripts') -File -ErrorAction SilentlyContinue | Where-Object Extension -eq '.ps1') {
    $name = $f.FullName.Substring($root.Length + 1)
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    Check "$($name): UTF-8 BOM 付き" { $bom }
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
    Check "$($name): 構文エラーが無い" { $errors.Count -eq 0 }
}
Check '$Version の書き方' { [IO.File]::ReadAllText($main) -match "(?m)^\`$Version\s*=\s*'\d+\.\d+\.\d+'" }

$ast = [Management.Automation.Language.Parser]::ParseFile($main, [ref]$null, [ref]$null)

# C# の部分がコンパイルできる（別のプロセスで。同じ型を二度読み込めないため）
$cs = $ast.Find({ param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -match '(?m)^using System;' }, $true).Value
Check 'C# の部分がコンパイルできる' {
    $csFile = Join-Path $env:TEMP "test-cs-$PID.cs"  # コマンドの長さに収まらないのでファイルで渡す
    [IO.File]::WriteAllText($csFile, $cs)
    try {
        $out = powershell -NoProfile -Command {
            param($path)
            Add-Type -AssemblyName System.Windows.Forms, System.Drawing
            Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition ([IO.File]::ReadAllText($path))
            'compiled'
        } -args $csFile 2>&1
    } finally { Remove-Item $csFile -ErrorAction SilentlyContinue }
    "$out" -match 'compiled'
}
# $X = $X のような、自分を入れるだけの代入が無い(置きかえの間違いで中身が空になり、通知などで止まる)
Check '自分を入れるだけの代入が無い' {
    $self = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $n.Right.Extent.Text }, $true))
    if ($self.Count) { throw "$($self[0].Extent.StartLineNumber) 行目: $($self[0].Extent.Text)" }
    $true
}
# メニューやタイマーの中のエラーは trap に届かないので、受け手が要る
Check 'メニューやタイマーのエラーを受ける' { [IO.File]::ReadAllText($main) -match 'add_ThreadException' }

# 起動の知らせの待ち方: 知らせが来たか、先に終わったか、来なかったか
$waitReady = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Wait-Ready' }, $true).Extent.Text
. ([scriptblock]::Create($waitReady))
$event = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset)
$running = [pscustomobject]@{ HasExited = $false }
$exited = [pscustomobject]@{ HasExited = $true }
Check '起動の知らせが来たら ready' { [void]$event.Set(); (Wait-Ready $event $running 2000) -eq 'ready' }
Check '知らせを出して終わったら ready' { (Wait-Ready $event $exited 2000) -eq 'ready' }
[void]$event.Reset()
Check '知らせの前に終わったら待たずに exited' { $t = Get-Date; ((Wait-Ready $event $exited 10000) -eq 'exited') -and ((Get-Date) - $t).TotalSeconds -lt 2 }
Check '来ないまま時間が過ぎたら timeout' { (Wait-Ready $event $running 1000) -eq 'timeout' }
$event.Dispose()

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
# 見つかった版を返し、無ければ 空。1つ目の引数（リポジトリ名）はまねた通信では使わない
function Find-Update($current, $skip = '', $manual = $false) {
    $r = & $checkUpdate 'test' $current $skip $manual
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
# 本体そのもの（版だけ上げたもの）を配ったとき、版を読み取れる（本体の $Version の書き方と、更新の確かめ方がずれていない）
$script:served = [IO.File]::ReadAllText($main) -replace "(?m)^(\`$Version\s*=\s*)'[^']*'", "`${1}'99.0.0'"
Check '本体を配ったとき版を読み取れる' { (Find-Update '1.0.0') -eq '99.0.0' }
Serve '1.6.0'; Check '受け取った版は中身で返し、TEMP に残さない' {
    $r = & $checkUpdate 'test' '1.5.0' '' $false
    $r.Text -match "'1\.6\.0'" -and -not (Get-ChildItem $env:TEMP -Filter '*-update.ps1' | Where-Object LastWriteTime -gt (Get-Date).AddSeconds(-10))
}

# ---- ログ ----
$appDir = Join-Path $env:TEMP "test-log-$PID"
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
# アンインストールで消したあとに書いても、フォルダを作り直さない
Write-Log 'アンインストールのあと'
Check 'アンインストールのあとログでフォルダを作り直さない' { -not (Test-Path $appDir) }

# ---- ツールごとのテスト（tests\<本体の名前>.ps1 があれば読み込む。$main・$ast・Check を使える） ----
$own = Join-Path $PSScriptRoot (Split-Path $main -Leaf)
if (Test-Path $own) { . $own }

Write-Host "`n失敗 $script:failures 件"
exit [int]($script:failures -gt 0)
