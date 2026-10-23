# copathy だけのテスト（run.ps1 が読み込む）。コピーする文字の作り方（PathText.Format）を、本体の C# を取り出して本物のフォルダで試す
$source = $ast.Find({ param($n) ($n -is [Management.Automation.Language.StringConstantExpressionAst] -or $n -is [Management.Automation.Language.ExpandableStringExpressionAst]) -and $n.Value -match 'class PathText' }, $true).Value
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition $source

function Format-Paths { [PathText]::Format([string[]]$args) }
$d = Join-Path $env:TEMP "test-copathy-$PID"
New-Item -ItemType Directory -Force "$d\a\sub", "$d\b", "$d\c" | Out-Null
try {
    Check 'パス: 同じフォルダのものは、親フォルダの下に名前を数の順で並べる（file2 < file10）' { (Format-Paths "$d\a\file10.txt" "$d\a\file2.txt") -eq "$d\a\`r`nfile2.txt`r`nfile10.txt" }
    Check 'パス: フォルダが先で、名前の後ろに \ を付ける' { (Format-Paths "$d\a\file2.txt" "$d\a\sub") -eq "$d\a\`r`nsub\`r`nfile2.txt" }
    Check 'パス: 1つだけのものは最後にフルパスで、空行で区切る' { (Format-Paths "$d\b\only.txt" "$d\a\file2.txt" "$d\a\file10.txt") -eq "$d\a\`r`nfile2.txt`r`nfile10.txt`r`n`r`n$d\b\only.txt" }
    Check 'パス: 1つだけのもの同士は続けて並べる' { (Format-Paths "$d\c\x.txt" "$d\b\only.txt") -eq "$d\b\only.txt`r`n$d\c\x.txt" }
    Check 'パス: 1つだけのフォルダも後ろに \ を付ける' { (Format-Paths "$d\a\sub") -eq "$d\a\sub\" }
    Check 'パス: 親フォルダは大文字・小文字を区別しない' { ((Format-Paths "$d\a\file2.txt" "$d\A\file10.txt") -split "`r`n").Count -eq 3 }
} finally { Remove-Item $d -Recurse -Force }

# ---- インストールと消す処理 ----
# 名前を変えた写し（$tp + 場面ごとの文字）で試す。本物の copathy のインストール先・ショートカット・登録・合図には触らない。
# install.ps1 は画面を出さない（SETUP_NO_UI=1）。起動する側は、本物の代わりに最小の「にせ copathy」を使う場面と、本物の copathy.ps1 の写しを使う場面がある。
$tp = "copathyT$PID"
$work = Join-Path $env:TEMP "test-setup-$PID"
$utf8 = New-Object Text.UTF8Encoding $true
$ukRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
$nkRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'
$startupDir = [Environment]::GetFolderPath('Startup')
$programsDir = [Environment]::GetFolderPath('Programs')
$mainText = [IO.File]::ReadAllText($main, [Text.Encoding]::UTF8)
$installText = [IO.File]::ReadAllText((Join-Path $root 'install.ps1'), [Text.Encoding]::UTF8)
$unTemplate = $ast.Find({ param($n) $n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -match 'param\(\[switch\]\$Yes' }, $true).Value
$testingUninstalling = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-Uninstalling' }, $true).Extent.Text
$names = New-Object System.Collections.Generic.List[string]
$R = @{}

function Put($path, $text) { New-Item -ItemType Directory -Force (Split-Path $path) | Out-Null; [IO.File]::WriteAllText($path, $text, $utf8) }
function Get-UninstallText($n) { $unTemplate.Replace('@@APPNAME@@', $n) }
function Rename-App($text, $n) {
    $r = $text.Replace("`$AppName = 'copathy'", "`$AppName = '$n'")
    if ($r -ceq $text) { throw "`$AppName の行が見つからない" }
    $r
}
function Get-Procs($pattern) { @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { "$($_.CommandLine)".IndexOf($pattern, [StringComparison]::OrdinalIgnoreCase) -ge 0 }) }
function Get-ProcCount($pattern) { @(Get-Procs $pattern).Count }
function Dir-Of($n) { Join-Path $env:LOCALAPPDATA $n }
function Name-Of($suffix) { $n = "$tp$suffix"; [void]$names.Add($n); $n }
# 場面の後始末（動いているものを止め、作ったものをすべて消す）
function Wipe($n) {
    foreach ($p in (Get-Procs "\$n\")) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    foreach ($p in (Get-Procs "\$n\")) { Wait-Process -Id $p.ProcessId -Timeout 5 -ErrorAction SilentlyContinue }
    Remove-Item (Dir-Of $n), (Join-Path $work $n), (Join-Path $startupDir "$n.lnk"), (Join-Path $programsDir "$n.lnk"),
        "$ukRoot\$n", "$nkRoot\ogura-ryoya.$n", (Join-Path $env:TEMP "$n-install.log"), (Join-Path $env:TEMP "$n-uninstall.log"),
        (Join-Path $work "$n.uninstall.src") -Recurse -Force -ErrorAction SilentlyContinue
}
function Start-Ps($file, $argList, $cwd) {
    $p = Start-Process powershell.exe -PassThru -WindowStyle Hidden -WorkingDirectory $cwd -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$file`"") + $argList)
    $null = $p.Handle  # 終了コードを読めるよう控える
    $p
}
function Wait-Ps($p, $ms = 150000) { if (-not $p.WaitForExit($ms)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; return -999 }; $p.ExitCode }
function Read-Log($path) { if (Test-Path $path) { [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) } else { '' } }
function Test-Mark($n, $kind) { $m = $null; try { if ([Threading.Mutex]::TryOpenExisting("Local\$n$kind", [ref]$m)) { $m.Dispose(); return $true } } catch {}; $false }
function Hold-Setup($n) { $m = New-Object Threading.Mutex($false, "Local\$($n)Setup"); if (-not $m.WaitOne(0)) { throw '排他を取れない' }; $m }

# にせ copathy: 起動したら印・合図・消すスクリプト・登録などを作り、Ready を出して Quit を待つ。
# MODE: good / slow(Ready が 8 秒遅い) / hang(Ready を出さず止まる) / crash(消すスクリプト・登録・ショートカットを作って、Ready の前に終わる)
#   crashbare(登録とショートカットだけ作って終わる。消すスクリプトは無い) / keep(「設定 > アプリ」の仕組みを持つ版だが、起動しても作らない) / legacy(2.4.x 相当。仕組みを持たず、作らない)
$fakeTemplate = @'
$Version = '@V@'
$AppName = '@N@'
@TOKEN@
$dir = Split-Path $MyInvocation.MyCommand.Path
Set-Content (Join-Path $dir "probe-$Version.txt") "cwd=$((Get-Location).Path) previous=$(Test-Path (Join-Path $dir 'copathy.previous.ps1')) headless=$($args -contains 'headless')"
if ($args -notcontains 'headless') { return }
$m = New-Object Threading.Mutex($false, "Local\$AppName")
if (-not $m.WaitOne(0)) { exit }
$quit = New-Object Threading.EventWaitHandle($false, 'ManualReset', "Local\$($AppName)Quit")
if ('@MODE@' -in 'good', 'slow', 'hang', 'crash') { Copy-Item '@U@' (Join-Path $dir 'uninstall.ps1') -Force }
if ('@MODE@' -in 'good', 'slow', 'hang', 'crash', 'crashbare') {
    $k = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$AppName"
    New-Item $k -Force | Out-Null
    Set-ItemProperty $k DisplayVersion $Version
}
Set-Content (Join-Path ([Environment]::GetFolderPath('Startup')) "$AppName.lnk") 'x'
Set-Content (Join-Path ([Environment]::GetFolderPath('Programs')) "$AppName.lnk") 'x'
if ('@MODE@' -in 'crash', 'crashbare') { exit }
if ('@MODE@' -eq 'slow') { Start-Sleep 8 }
if ('@MODE@' -eq 'hang') { Start-Sleep 600; exit }
$ready = New-Object Threading.EventWaitHandle($false, 'ManualReset', "Local\$($AppName)Ready")
[void]$ready.Set()
[void]$quit.WaitOne()
'@
function New-Kit($n, $version, $mode = 'good') {
    $kit = Join-Path $work $n
    Put (Join-Path $work "$n.uninstall.src") (Get-UninstallText $n)
    Put "$kit\install.ps1" (Rename-App $installText $n)
    $token = if ($mode -eq 'legacy') { '' } else { "`$uninstallScript = 'x'  # 2.5.0 以降の版が持つ正本のまね" }
    $text = $fakeTemplate.Replace('@TOKEN@', $token).Replace('@N@', $n).Replace('@V@', $version).Replace('@MODE@', $mode).Replace('@U@', (Join-Path $work "$n.uninstall.src"))
    if ($mode -eq 'broken') { $text = "`$Version = '$version'`r`nif ( {`r`n" }
    Put "$kit\copathy.ps1" $text
    $kit
}
function Run-Install($kit, $ms = 150000) { Wait-Ps (Start-Ps "$kit\install.ps1" @() $kit) $ms }
# インストール済みの状態を直接作る（消すスクリプトの試し用）
function New-Installed($n) {
    $d = Dir-Of $n
    Put "$d\copathy.ps1" "`$Version = '1.0.0'`r`n"
    Put "$d\uninstall.ps1" (Get-UninstallText $n)
    Put "$d\log.txt" 'x'
    Put "$d\sub\a.txt" 'x'
    Set-Content (Join-Path $startupDir "$n.lnk") 'x'
    Set-Content (Join-Path $programsDir "$n.lnk") 'x'
    New-Item "$nkRoot\ogura-ryoya.$n" -Force | Out-Null
    New-Item "$ukRoot\$n" -Force | Out-Null
    Set-ItemProperty "$ukRoot\$n" DisplayName $n
}
function Run-Uninstall($n, $argList = @('-Quiet'), $ms = 90000) { Wait-Ps (Start-Ps (Join-Path (Dir-Of $n) 'uninstall.ps1') $argList $env:TEMP) $ms }
function Test-AllGone($n) {
    -not (Test-Path (Dir-Of $n)) -and -not (Test-Path (Join-Path $startupDir "$n.lnk")) -and -not (Test-Path (Join-Path $programsDir "$n.lnk")) -and
        -not (Test-Path "$ukRoot\$n") -and -not (Test-Path "$nkRoot\ogura-ryoya.$n")
}
function Get-RealState {
    $d = Join-Path $env:LOCALAPPDATA 'copathy'
    $files = foreach ($f in "$d\copathy.ps1", "$d\uninstall.ps1", (Join-Path $startupDir 'copathy.lnk'), (Join-Path $programsDir 'copathy.lnk')) {
        if (Test-Path $f) { "$f=$((Get-Item $f).LastWriteTimeUtc.Ticks)" } else { "$f=なし" }
    }
    $reg = if (Test-Path "$ukRoot\copathy") { (Get-ItemProperty "$ukRoot\copathy" | Out-String) } else { 'なし' }
    $marks = foreach ($s in 'Setup', 'Uninstalling') { "$s=$(Test-Mark 'copathy' $s)" }
    (@($files) + $reg + @($marks)) -join "`n"
}

$savedNoUi = $env:SETUP_NO_UI
$env:SETUP_NO_UI = '1'
$realBefore = Get-RealState
$hangProc = $null
try {
    New-Item -ItemType Directory -Force $work | Out-Null

    # ---- 静的な確かめ ----
    Check '消すスクリプトの正本: 名前を置きかえても構文エラーが無い' {
        $e = $null; [void][Management.Automation.Language.Parser]::ParseInput((Get-UninstallText 'x'), [ref]$null, [ref]$e); $e.Count -eq 0 -and $unTemplate -match '@@APPNAME@@' -and $unTemplate -notmatch "copathy'"
    }
    Check 'install.ps1: 先頭に $AppName = ''copathy'' の行がある（名前はここから作る）' { $installText -match "(?m)^\`$AppName = 'copathy'\s*$" }
    Check '名前: 本物の名前を直に書いた合図・登録・インストール先が無い（copathy.ps1・install.ps1）' {
        -not ($mainText -match 'Local\\copathy|Uninstall\\copathy|LOCALAPPDATA ''copathy''|LOCALAPPDATA ''copathy''|Settings\\ogura-ryoya\.copathy') -and
        -not ($installText -match 'Local\\copathy|Uninstall\\copathy|LOCALAPPDATA ''copathy''|Settings\\ogura-ryoya\.copathy')
    }
    Check '起動のたび、ショートカットより先に uninstall.ps1 と登録を書く' {
        $i = $mainText.IndexOf('WriteAllText($uninstallPs1'); $k = $mainText.IndexOf('Set-ItemProperty -LiteralPath $uninstallKey'); $s = $mainText.IndexOf('New-Shortcut $startupLnk')
        $i -ge 0 -and $k -ge 0 -and $s -ge 0 -and $i -lt $s -and $k -lt $s
    }
    Check '作業フォルダ: Start-App・New-Shortcut・install.ps1 の起動はすべてユーザーのフォルダ' {
        $app = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Start-App' }, $true).Extent.Text
        $sc = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-Shortcut' }, $true).Extent.Text
        $app -match '-WorkingDirectory \$env:USERPROFILE' -and $sc -match 'WorkingDirectory = \$env:USERPROFILE' -and $installText -match 'Start-Process "\$env:WINDIR\\System32\\conhost.exe" -PassThru -WorkingDirectory \$env:USERPROFILE'
    }
    Check '更新の抑止: 更新の確認を始める前に、消す印(Test-Uninstalling)を見て戻る（タイマー）' {
        $t = $mainText.IndexOf('$updateTimer.add_Tick('); $body = $mainText.Substring($t)
        $a = $body.IndexOf('Test-Uninstalling'); $b = $body.IndexOf('& $startCheck $false'); $c = $body.IndexOf('& $applyUpdate')
        $t -ge 0 -and $a -ge 0 -and $b -gt $a -and $c -gt $a -and $body.Substring($a, 160) -match 'return'
    }
    Check 'トレイの「アンインストール」: 「はい」なら -Yes 付きで uninstall.ps1 を画面なしで起動し、自分は終わる' {
        $t = $mainText.IndexOf('$uninstallItem.add_Click('); $body = $mainText.Substring($t, 2200)
        $body -match 'Start-Process \$conhost -ArgumentList "\$uninstallArgs -Yes"' -and $mainText -match '\$uninstallArgs = "--headless [^"]*-File `"\$uninstallPs1`""' -and $body.IndexOf('-Yes') -lt $body.IndexOf('& $stop')
    }
    Check '消す: 排他が取れず終了コード 2 で終わるとき、-Quiet でなければ画面で知らせる（Quiet では出さない）' {
        $e = $unTemplate.IndexOf('exit 2'); $before = $unTemplate.Substring([Math]::Max(0, $e - 400), [Math]::Min(400, $e))
        $e -ge 0 -and $before -match '(?m)^\s*Show ' -and $unTemplate -match '(?s)function Show\(.*?\{\s*if \(\$Quiet\) \{ return \}'
    }
    Check '消す: 「消している印」(Uninstalling)は、確認のダイアログ(YesNo)より前に作る（確認を出している間も更新しない）' {
        $a = $unTemplate.IndexOf('Local\$($AppName)Uninstalling'); $b = $unTemplate.IndexOf("'YesNo'")
        $a -ge 0 -and $b -gt $a
    }
    Check '消す: ほかのものが残る間は、フォルダを消さない(フォルダは最後)' { $unTemplate -match '\$_ -ne \$dir -and \(Test-Path -LiteralPath \$_\)' }
    Check 'release.yml: 版の上げ忘れの確かめは、テストの後・リリースの前に、どのブランチでも動く手順(if なし)で、リリースの手順には残さない。並びの group はブランチごと' {
        $y = [IO.File]::ReadAllText((Join-Path $root '.github\workflows\release.yml'), [Text.Encoding]::UTF8) -replace '\r', ''
        $steps = @($y -split '(?m)^      - ' | Where-Object { $_ -match '^(name|uses):' })
        $iT = -1; $iB = -1; $iR = -1; for ($i = 0; $i -lt $steps.Count; $i++) { if ($steps[$i] -match 'tests/run\.ps1') { $iT = $i }; if ($steps[$i] -match 'check-bumped\.ps1') { $iB = $i }; if ($steps[$i] -match 'create-release\.ps1') { $iR = $i } }
        $cr = [IO.File]::ReadAllText((Join-Path $root '.github\scripts\create-release.ps1'), [Text.Encoding]::UTF8)
        $iT -ge 0 -and $iB -gt $iT -and $iR -gt $iB -and $steps[$iB] -notmatch '(?m)^\s+if:' -and $steps[$iB] -match 'VERSION:' -and $steps[$iB] -match 'GH_TOKEN:' -and $cr -notmatch 'git diff' -and
            $y -match '(?m)^\s+group: release-\$\{\{ github\.ref \}\}\s*$'
    }
    Check '終了(自動起動も解除): インストール先でなければ自動起動のショートカットに触れず終わる' {
        $t = $mainText.IndexOf('$exitItem.add_Click('); $body = $mainText.Substring($t, 900)
        $a = $body.IndexOf('-not $isInstalled'); $b = $body.IndexOf('Remove-Item $startupLnk')
        $a -ge 0 -and $b -gt $a -and $body.Substring($a, $b - $a) -match 'return'
    }
    Check '作業フォルダ: 画面なしで起動した直後（排他より前）に、作業フォルダをユーザーのフォルダへ変える' {
        $h = $mainText.IndexOf("-notcontains 'headless'"); $a = $mainText.IndexOf('Set-Location $env:USERPROFILE', $h); $b = $mainText.IndexOf('$mutex = New-Object System.Threading.Mutex($false, "Local\$AppName")')
        $h -ge 0 -and $a -gt $h -and $b -gt $a
    }
    Check 'release.yml: どのブランチへのプッシュでもテストを動かし、リリースを作る手順だけ main に限る' {
        $y = [IO.File]::ReadAllText((Join-Path $root '.github\workflows\release.yml'), [Text.Encoding]::UTF8) -replace '\r', ''
        $pushBlock = [regex]::Match($y, '(?ms)^  push:\n(.*?)^  workflow_dispatch:').Groups[1].Value
        $steps = @($y -split '(?m)^      - ' | Where-Object { $_ -match '^(name|uses):' })
        $testStep = @($steps | Where-Object { $_ -match 'tests/run\.ps1' }); $relStep = @($steps | Where-Object { $_ -match 'create-release\.ps1' })
        $y -match '(?m)^  workflow_dispatch:' -and $pushBlock -ne '' -and $pushBlock -notmatch 'branches' -and
        $testStep.Count -eq 1 -and $testStep[0] -notmatch '(?m)^\s+if:' -and
        $relStep.Count -eq 1 -and $relStep[0] -match "(?m)^\s+if:\s*github\.ref == 'refs/heads/main'\s*$"
    }
    Check 'README: アンインストールの入り口・消すもの・手で消す場所が書いてある' {
        $rd = [IO.File]::ReadAllText((Join-Path $root 'README.md'), [Text.Encoding]::UTF8)
        $rd -match '設定' -and $rd -match 'アプリ' -and $rd -match 'アンインストール' -and $rd -match '%LOCALAPPDATA%\\copathy' -and $rd -match 'copathy\.lnk' -and $rd -match 'レジストリ|Uninstall'
    }

    # ---- 止まる版を新しく入れる（60 秒かかるので、ほかの確かめと並べて動かす） ----
    $nH = Name-Of 'h1'
    $kitH = New-Kit $nH '9.1.0' 'hang'
    $hangProc = Start-Ps "$kitH\install.ps1" @() $kitH

    # v3: 前の版があって、新しい版が起動の知らせを出さない(60 秒) → 止めてから前の版に戻す（これも 60 秒かかるので並べる）
    $nV3 = Name-Of 'v3'
    $kitV3 = New-Kit $nV3 '9.1.0' 'keep'
    $R.v3a = Run-Install $kitV3
    $origV3 = [IO.File]::ReadAllText("$(Dir-Of $nV3)\copathy.ps1")
    $kitV3 = New-Kit $nV3 '9.2.0' 'hang'
    $v3Proc = Start-Ps "$kitV3\install.ps1" @() $kitV3

    # ---- 消すスクリプト ----
    # u1: ふつうに全部消える（作業フォルダがインストール先の中でも消せる）
    $n = Name-Of 'u1'; New-Installed $n
    Set-Content (Join-Path $env:TEMP "$n-install.log") 'x'  # インストーラーのログも、すべて消せたら消える
    $R.u1 = Wait-Ps (Start-Ps (Join-Path (Dir-Of $n) 'uninstall.ps1') @('-Quiet') (Dir-Of $n)) 90000
    Check '消す: -Quiet で自動起動・スタートメニュー・通知の設定・フォルダ・登録がすべて消え、終了コード 0' { $R.u1 -eq 0 -and (Test-AllGone $n) }
    Check '消す: すべて消せたら、%TEMP% の消すログとインストーラーのログも消す（インストール先にはログを書かない）' {
        -not (Test-Path (Join-Path $env:TEMP "$n-uninstall.log")) -and -not (Test-Path (Join-Path $env:TEMP "$n-install.log")) -and -not (Test-Path (Dir-Of $n))
    }

    # u2: 動いている copathy は合図で終わってもらう
    $n = Name-Of 'u2'; New-Installed $n
    $kit = New-Kit $n '9.1.0'; Copy-Item "$kit\copathy.ps1" (Join-Path (Dir-Of $n) 'copathy.ps1') -Force
    $ev = New-Object Threading.EventWaitHandle($false, 'ManualReset', "Local\$($n)Ready"); [void]$ev.Reset()
    $fake = Start-Ps (Join-Path (Dir-Of $n) 'copathy.ps1') @('headless') $env:TEMP
    $up = $ev.WaitOne(30000)
    $R.u2 = Run-Uninstall $n @('-Quiet', '-HoldsLock')  # -HoldsLock なら成功してもログを残す(中身を確かめるため)
    Check '消す: 動いている copathy を合図で終わらせてから消す（強制では止めない）' {
        $up -and $R.u2 -eq 0 -and $fake.HasExited -and (Test-AllGone $n) -and (Read-Log (Join-Path $env:TEMP "$n-uninstall.log")) -notmatch '合図で終わらない'
    }
    $ev.Dispose()

    # u3: 合図で終わらないインストール先の powershell は止める。名前が前方一致するだけの別のフォルダのものは止めない
    $n = Name-Of 'u3'; $sib = Name-Of 'u3X'; New-Installed $n
    Put (Join-Path (Dir-Of $n) 'hang.ps1') 'Start-Sleep 600'
    Put (Join-Path (Dir-Of $sib) 'hang.ps1') 'Start-Sleep 600'
    $hang = Start-Ps (Join-Path (Dir-Of $n) 'hang.ps1') @() $env:TEMP
    $other = Start-Ps (Join-Path (Dir-Of $sib) 'hang.ps1') @() $env:TEMP
    Start-Sleep -Seconds 2
    $R.u3 = Run-Uninstall $n
    Check '消す: 合図で終わらない（コマンドラインにインストール先を含む）powershell を止めて消す' { $R.u3 -eq 0 -and $hang.HasExited -and (Test-AllGone $n) }
    Check '消す: 名前が似ているだけの別フォルダの powershell は止めない' { -not $other.HasExited }
    Stop-Process -Id $other.Id -Force -ErrorAction SilentlyContinue

    # u4: 消せないものがあるとき。終了コード 1、登録は残る、印は動いている間だけ、握りを外して消し直せる
    $n = Name-Of 'u4'; New-Installed $n
    $lock = [IO.File]::Open((Join-Path (Dir-Of $n) 'log.txt'), 'Open', 'Read', 'None')
    $sawMark = $false
    try {
        $p4 = Start-Ps (Join-Path (Dir-Of $n) 'uninstall.ps1') @('-Quiet') $env:TEMP
        $limit = (Get-Date).AddSeconds(60)
        while (-not $p4.HasExited -and (Get-Date) -lt $limit) {
            $AppName = $n; . ([scriptblock]::Create($testingUninstalling))
            if (Test-Uninstalling) { $sawMark = $true; break }
            Start-Sleep -Milliseconds 100
        }
        $R.u4 = Wait-Ps $p4 90000
    } finally { $lock.Dispose() }
    $markAfter = (Test-Mark $n 'Uninstalling')
    Check '消す: 消せないものがあると終了コード 1 で、フォルダと「設定 > アプリ」の登録が残る' { $R.u4 -eq 1 -and (Test-Path (Dir-Of $n)) -and (Test-Path "$ukRoot\$n") }
    Check '消す: 消せるものは消す（ショートカット・通知の設定）' { -not (Test-Path (Join-Path $startupDir "$n.lnk"))  -and -not (Test-Path (Join-Path $programsDir "$n.lnk")) -and -not (Test-Path "$nkRoot\ogura-ryoya.$n") }
    Check '消す: 消せなかったものと理由を %TEMP% のログに残す（消し残しがあるときはログを消さない）' { (Read-Log (Join-Path $env:TEMP "$n-uninstall.log")) -match '消せなかった' }
    Check '消す: 動いている間は「消している印」があり（copathy の Test-Uninstalling が真）、終わると無い' { $sawMark -and -not $markAfter }
    $R.u4b = Run-Uninstall $n
    Check '消す: 握りを外して消し直すと、登録も含めて全部消える' { $R.u4b -eq 0 -and (Test-AllGone $n) }

    # u4c: フォルダが別のプロセスの作業フォルダで、中身は消せてもフォルダが残るとき。自分(uninstall.ps1)が消えたままにならず、登録も残り、握りを外せば消し直せる
    $n = Name-Of 'u4c'; New-Installed $n
    $holdPs1 = Join-Path $work "$n.hold.ps1"; Put $holdPs1 'Start-Sleep 600'
    $holder = Start-Ps $holdPs1 @() (Dir-Of $n)
    Start-Sleep -Seconds 2
    $R.u4c = Run-Uninstall $n
    $selfOk = (Test-Path (Join-Path (Dir-Of $n) 'uninstall.ps1')) -and ([IO.File]::ReadAllText((Join-Path (Dir-Of $n) 'uninstall.ps1'), [Text.Encoding]::UTF8) -ceq (Get-UninstallText $n))
    Check '消す(作業フォルダに使われている): 終了コード 1、フォルダと登録が残り、uninstall.ps1 も残る（書き戻される）' {
        $R.u4c -eq 1 -and (Test-Path (Dir-Of $n)) -and (Test-Path "$ukRoot\$n") -and $selfOk
    }
    Check '消す(作業フォルダに使われている): 消せるもの(中身・ショートカット・通知の設定)は消す' {
        -not (Test-Path (Join-Path (Dir-Of $n) 'sub')) -and -not (Test-Path (Join-Path (Dir-Of $n) 'copathy.ps1')) -and -not (Test-Path (Join-Path $startupDir "$n.lnk")) -and -not (Test-Path "$nkRoot\ogura-ryoya.$n")
    }
    Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue; Wait-Process -Id $holder.Id -Timeout 5 -ErrorAction SilentlyContinue
    $R.u4cb = if (Test-Path (Join-Path (Dir-Of $n) 'uninstall.ps1')) { Run-Uninstall $n } else { -1 }
    Check '消す(作業フォルダに使われている): 握りを外して残った uninstall.ps1 で消し直すと、登録も含めて全部消える' { $R.u4cb -eq 0 -and (Test-AllGone $n) }

    # u4d: ショートカットが消せないとき、フォルダ(uninstall.ps1 を含む)は最後まで消さない。ほかが消えてから消す
    $n = Name-Of 'u4d'; New-Installed $n
    $lnkLock = [IO.File]::Open((Join-Path $startupDir "$n.lnk"), 'Open', 'Read', 'None')
    try { $R.u4d = Run-Uninstall $n } finally { $lnkLock.Dispose() }
    $logD = Read-Log (Join-Path $env:TEMP "$n-uninstall.log")
    Check '消す(ほかが残る): ログに、ショートカットが消せなかった理由と、フォルダを「ほかが消えていないので、消さずに残した」理由が両方ある（理由が空の行にしない）' {
        $logD -match '消せなかった: .*\.lnk（.+）' -and $logD -match "消せなかった: [^\r\n]*\\$([regex]::Escape($n))（ほかが消えていない"
    }
    Check '消す(ほかが残る): 終了コード 1、フォルダは中身ごと(uninstall.ps1 も)消さず、登録も残る' {
        $R.u4d -eq 1 -and (Test-Path (Join-Path (Dir-Of $n) 'uninstall.ps1')) -and (Test-Path (Join-Path (Dir-Of $n) 'sub\a.txt')) -and (Test-Path (Join-Path (Dir-Of $n) 'copathy.ps1')) -and (Test-Path "$ukRoot\$n")
    }
    Check '消す(ほかが残る): 消せるもの(スタートメニューのショートカット・通知の設定)は消す' { -not (Test-Path (Join-Path $programsDir "$n.lnk")) -and -not (Test-Path "$nkRoot\ogura-ryoya.$n") }
    $R.u4db = Run-Uninstall $n
    Check '消す(ほかが残る): 握りを外して消し直すと、フォルダも登録も全部消える' { $R.u4db -eq 0 -and (Test-AllGone $n) }

    # u5b: 排他が取れなかったときの画面の知らせ。相手が違う種類(インストール中)なら知らせ、同じ種類(消す処理)や相手の印なしなら黙る。
    # 画面を出さないため、正本の Show の「画面を出す所」だけをログに書く形に置きかえた写しで動かす(-Quiet で出さない判定は残る)
    $uiLess = [regex]::Replace($unTemplate, '(?s)\$owner = New-Object System.Windows.Forms.Form.*?\$owner\.Dispose\(\)', 'Log "画面の知らせ: $text"', 1)
    if ($uiLess -ceq $unTemplate) { throw 'u5b: 置きかえが効いていない' }
    function Run-UiLess($n, $argList) {
        $f = Join-Path $work "$n.uiless.ps1"; Put $f $uiLess.Replace('@@APPNAME@@', $n)
        Wait-Ps (Start-Ps $f $argList $env:TEMP) 60000
    }
    $n = Name-Of 'u5b'; New-Installed $n
    $hold = Hold-Setup $n; $markI = $null; $markU = $null
    try {
        $markI = New-Object Threading.Mutex($false, "Local\$($n)Installing")
        $R.u5i = Run-UiLess $n @('-Yes'); $logI = Read-Log (Join-Path $env:TEMP "$n-uninstall.log")
        $R.u5iq = Run-UiLess $n @('-Quiet'); $logIq = (Read-Log (Join-Path $env:TEMP "$n-uninstall.log")).Substring($logI.Length)
        $markI.Dispose(); $markI = $null
        Remove-Item (Join-Path $env:TEMP "$n-uninstall.log") -ErrorAction SilentlyContinue
        $markU = New-Object Threading.Mutex($false, "Local\$($n)Uninstalling")
        $R.u5u = Run-UiLess $n @('-Yes'); $logU = Read-Log (Join-Path $env:TEMP "$n-uninstall.log")
        $markU.Dispose(); $markU = $null
        Remove-Item (Join-Path $env:TEMP "$n-uninstall.log") -ErrorAction SilentlyContinue
        $R.u5n = Run-UiLess $n @('-Yes'); $logN = Read-Log (Join-Path $env:TEMP "$n-uninstall.log")
    } finally { $hold.ReleaseMutex(); $hold.Dispose(); foreach ($m in $markI, $markU) { if ($m) { $m.Dispose() } } }
    Check '消す(排他・相手の種類): 相手がインストール中なら、何も消さずに終了コード 2 で、画面で知らせる' { $R.u5i -eq 2 -and $logI -match '画面の知らせ: .*インストール' -and (Test-Path (Dir-Of $n)) }
    Check '消す(排他・相手の種類): 相手がインストール中でも -Quiet なら画面を出さない(終了コード 2)' { $R.u5iq -eq 2 -and $logIq -notmatch '画面の知らせ' }
    Check '消す(排他・相手の種類): 相手が同じ種類(消す処理)なら、黙って終了コード 2' { $R.u5u -eq 2 -and $logU -notmatch '画面の知らせ' -and $logU -match '何もしない' }
    Check '消す(排他・相手の種類): 相手の印が無いときも、黙って終了コード 2' { $R.u5n -eq 2 -and $logN -notmatch '画面の知らせ' }

    # u4e: 消し残したときの画面の知らせ(画面は出さない形)。uninstall.ps1 が残っているなら「設定 > アプリからもう一度」と案内し、手で消す案内はしない
    $n = Name-Of 'u4e'; New-Installed $n
    $lnkLock = [IO.File]::Open((Join-Path $startupDir "$n.lnk"), 'Open', 'Read', 'None')
    try { $R.u4e = Run-UiLess $n @('-Yes') } finally { $lnkLock.Dispose() }
    $logE = Read-Log (Join-Path $env:TEMP "$n-uninstall.log")
    Check '消す(消し残しの知らせ): uninstall.ps1 が残るなら、「設定 > アプリ」からもう一度消すよう案内し、手で消す案内はしない。残ったものを示す' {
        $R.u4e -eq 1 -and (Test-Path (Join-Path (Dir-Of $n) 'uninstall.ps1')) -and $logE -match '画面の知らせ: [^\r\n]*設定 > アプリ' -and $logE -match '画面の知らせ: [^\r\n]*消せなかったもの' -and $logE -notmatch '画面の知らせ: [^\r\n]*手で消す'
    }
    Check '消す(消し残しの知らせ): uninstall.ps1 が無いときの案内(手で消す・レジストリの場所)も正本にある(静的。無い状態を作れないため)' {
        $unTemplate -match '(?s)if \(Test-Path -LiteralPath \$selfPath\) \{.*?設定 > アプリ.*?\} else \{.*?手で消す.*?Uninstall\\\$AppName'
    }
    Wipe $n

    # u5: インストール・消すの排他。取れなければ何もしない（終了コード 2）
    $n = Name-Of 'u5'; New-Installed $n
    $hold = Hold-Setup $n
    try { $R.u5 = Run-Uninstall $n } finally { $hold.ReleaseMutex(); $hold.Dispose() }
    Check '消す: ほかのインストール・消す処理が動いていたら、何も消さずに終了コード 2' { $R.u5 -eq 2 -and (Test-Path (Dir-Of $n)) -and (Test-Path "$ukRoot\$n") -and (Read-Log (Join-Path $env:TEMP "$n-uninstall.log")) -match '何もしない' }

    # u6: -HoldsLock なら、排他を呼んだ側が持っていても進む
    $n = Name-Of 'u6'; New-Installed $n
    Set-Content (Join-Path $env:TEMP "$n-install.log") 'keep' -NoNewline
    $hold = Hold-Setup $n
    try { $R.u6 = Run-Uninstall $n @('-Quiet', '-HoldsLock') } finally { $hold.ReleaseMutex(); $hold.Dispose() }
    Check '消す: -HoldsLock なら排他を持たれていても消す' { $R.u6 -eq 0 -and (Test-AllGone $n) }
    Check '消す: -HoldsLock(インストーラーの片づけ)のときは、すべて消せてもログを残す（失敗の理由なので）' { (Read-Log (Join-Path $env:TEMP "$n-uninstall.log")) -match '消した' -and (Read-Log (Join-Path $env:TEMP "$n-install.log")) -eq 'keep' }

    # u7: 消すものが何も無くても失敗にしない
    $n = Name-Of 'u7'; New-Installed $n
    $unPs1 = Join-Path $work "$n.single.ps1"; Put $unPs1 (Get-UninstallText $n)
    Remove-Item (Dir-Of $n) -Recurse -Force; Remove-Item (Join-Path $startupDir "$n.lnk"), (Join-Path $programsDir "$n.lnk"), "$ukRoot\$n", "$nkRoot\ogura-ryoya.$n" -Recurse -Force
    $R.u7 = Wait-Ps (Start-Ps $unPs1 @('-Quiet') $env:TEMP) 90000
    Check '消す: 消すものが何も無いときも終了コード 0（0 件）' { $R.u7 -eq 0 }

    # ---- インストール（にせ copathy） ----
    # o1: 新しく入れて成功 → 展開したフォルダを消せる → 上書き（前の版あり）
    $n = Name-Of 'o1'; $kit = New-Kit $n '9.1.0'
    $R.o1a = Run-Install $kit
    $log = Read-Log (Join-Path $env:TEMP "$n-install.log")
    $dirO = Dir-Of $n
    Check 'インストール(新規): 成功の終了コード 0、置かれ、installed.flag があり、前の版の控えは残らない' {
        $R.o1a -eq 0 -and (Test-Path "$dirO\copathy.ps1") -and (Test-Path "$dirO\installed.flag") -and -not (Test-Path "$dirO\copathy.previous.ps1") -and
        ([IO.File]::ReadAllText("$dirO\copathy.ps1") -ceq [IO.File]::ReadAllText("$kit\copathy.ps1"))
    }
    Check 'インストール(新規): ログに 開始(元・新・前=なし)・起動を待った・成功 の行が残る' {
        $log -match "インストール: 開始 元=\S*\\$([regex]::Escape($n)) 新=v9\.1\.0 前=なし" -and $log -match '起動を待った [\d.]+ 秒 結果=ready' -and $log -match 'インストール: 成功'
    }
    Check 'インストール(新規): 成功したときだけ log.txt にも写す' { (Read-Log "$dirO\log.txt") -match 'インストール: 成功' }
    Check '作業フォルダ: 起動した copathy の作業フォルダはユーザーのフォルダ' {
        (Read-Log "$dirO\probe-9.1.0.txt") -match ('cwd=' + [regex]::Escape([IO.Path]::GetFullPath($env:USERPROFILE)).TrimEnd('\') + '\s') -and (Read-Log "$dirO\probe-9.1.0.txt") -match 'headless=True'
    }
    Check '作業フォルダ: インストール後、展開したフォルダをそのまま消せる' { Remove-Item $kit -Recurse -Force -ErrorAction SilentlyContinue; -not (Test-Path $kit) }
    $kit = New-Kit $n '9.2.0'
    $R.o1b = Run-Install $kit
    $log = Read-Log (Join-Path $env:TEMP "$n-install.log")
    Check 'インストール(上書き): 成功し、新しい版が置かれ、動いている前の版は終わって新しい版が 1 つだけ動く' {
        $R.o1b -eq 0 -and ([IO.File]::ReadAllText("$dirO\copathy.ps1") -match "9\.2\.0") -and ((Get-ProcCount "$dirO\copathy.ps1") -eq 1) -and (Test-Path "$dirO\probe-9.2.0.txt")
    }
    Check 'インストール(上書き): 上書きの前に前の版を copathy.previous.ps1 へ取り（起動した版から見える）、成功したら消す' {
        (Read-Log "$dirO\probe-9.2.0.txt") -match 'previous=True' -and -not (Test-Path "$dirO\copathy.previous.ps1")
    }
    Check 'インストール(上書き): ログに 前=v9.1.0 と、前の copathy を合図で終わらせた が残る' { $log -match '新=v9\.2\.0 前=v9\.1\.0' -and $log -match '前の copathy を合図で終わらせた\([\d.]+ 秒\)' }
    Wipe $n

    # v1: 前の版があって、新しい版が起動しない → 前の版に戻る
    # 前の版は「設定 > アプリ」の仕組みを持つが起動しても作らない版(keep)にして、戻した後に残っているのが新しい版の作ったものだと分かるようにする
    $n = Name-Of 'v1'; $kit = New-Kit $n '9.1.0' 'keep'
    $R.v1a = Run-Install $kit
    $dirV = Dir-Of $n
    $orig = [IO.File]::ReadAllText("$dirV\copathy.ps1")
    $kit = New-Kit $n '9.2.0' 'crash'
    Remove-Item (Join-Path $env:TEMP "$n-install.log") -ErrorAction SilentlyContinue
    $R.v1 = Run-Install $kit
    $log = Read-Log (Join-Path $env:TEMP "$n-install.log")
    Check 'インストール(戻し): 新しい版が起動しないと終了コード 1、前の版の中身に戻り、控えと installed.flag は残らない' {
        $R.v1a -eq 0 -and $R.v1 -eq 1 -and ([IO.File]::ReadAllText("$dirV\copathy.ps1") -ceq $orig) -and -not (Test-Path "$dirV\copathy.previous.ps1") -and -not (Test-Path "$dirV\installed.flag")
    }
    Check 'インストール(戻し): 前の版が起動し直している（Ready を出して動いている）' { $log -match '前の版を起動して待った [\d.]+ 秒 結果=ready' -and (Get-ProcCount "$dirV\copathy.ps1") -eq 1 }
    Check 'インストール(戻し・前の版が仕組みを持つ): 新しい版が作った消すスクリプトと「設定 > アプリ」の登録は消さずに残す' { (Test-Path "$dirV\uninstall.ps1") -and (Test-Path "$ukRoot\$n") }
    Check 'インストール(戻し): 画面の知らせに「v9.2.0 を起動できなかったので、前の v9.1.0 に戻した」とログの場所が出る' {
        $log -match 'v9\.2\.0 を起動できなかったので、前の v9\.1\.0 に戻した' -and $log -match [regex]::Escape("$n-install.log")
    }
    Check 'インストール(戻し): 失敗はログ(TEMP)に残るが、インストール先の log.txt には写さない' { $log -match 'インストール: 失敗' -and -not ((Read-Log "$dirV\log.txt") -match 'インストール: 失敗') }
    Wipe $n

    # v2: 前の版が 2.4.x 相当（仕組みを持たない）→ 戻したら uninstall.ps1 と登録を消す
    $n = Name-Of 'v2'; $kit = New-Kit $n '9.1.0' 'legacy'
    $R.v2a = Run-Install $kit
    $dirV2 = Dir-Of $n
    $origV2 = [IO.File]::ReadAllText("$dirV2\copathy.ps1")
    $kit = New-Kit $n '9.2.0' 'crash'
    $R.v2 = Run-Install $kit
    $log = Read-Log (Join-Path $env:TEMP "$n-install.log")
    Check 'インストール(戻し・前の版が 2.4.x 相当): 前の版の中身に戻り、前の版が起動し直している' {
        $R.v2a -eq 0 -and $R.v2 -eq 1 -and ([IO.File]::ReadAllText("$dirV2\copathy.ps1") -ceq $origV2) -and $log -match '前の版を起動して待った [\d.]+ 秒 結果=ready' -and (Get-ProcCount "$dirV2\copathy.ps1") -eq 1 -and -not (Test-Path "$dirV2\copathy.previous.ps1")
    }
    Check 'インストール(戻し・前の版が 2.4.x 相当): 新しい版が作った uninstall.ps1 と「設定 > アプリ」の登録を消す（押しても何も起きない項目を残さない）' {
        -not (Test-Path "$dirV2\uninstall.ps1") -and -not (Test-Path "$ukRoot\$n")
    }
    Wipe $n

    # b2: 前の版が無くて、新しい版が登録とショートカットだけ作って終わった（消すスクリプトが無い）→ 直接消す
    $n = Name-Of 'b2'; $kit = New-Kit $n '9.2.0' 'crashbare'
    $R.b2 = Run-Install $kit
    Check 'インストール(片づけ・消すスクリプトが無い): 登録・ショートカット・フォルダを直接消し、何も残らない' { $R.b2 -eq 1 -and (Test-AllGone $n) }
    Wipe $n

    # k1: 前の版が無くて、新しい版が起動せず、片づけで消せないものがある → 消えたと言わず、「設定 > アプリ」から消し直せる形で残す
    $n = Name-Of 'k1'; $kit = New-Kit $n '9.2.0' 'crash'
    $dK = Dir-Of $n; Put "$dK\zheld.txt" 'x'
    $lockK = [IO.File]::Open("$dK\zheld.txt", 'Open', 'Read', 'None')
    try { $R.k1 = Run-Install $kit } finally { $lockK.Dispose() }
    $log = Read-Log (Join-Path $env:TEMP "$n-install.log")
    Check 'インストール(片づけ・消せないものがある): 終了コード 1、「片づけた」と言わず「消しきれなかった」と残す' { $R.k1 -eq 1 -and $log -match '片づけきれなかった' -and $log -notmatch 'インストール: 片づけた' }
    Check 'インストール(片づけ・消せないものがある): 「設定 > アプリ」の登録が残るなら、それを消せる uninstall.ps1 も残っている' { -not (Test-Path "$ukRoot\$n") -or (Test-Path "$dK\uninstall.ps1") }
    $R.k1b = if (Test-Path "$dK\uninstall.ps1") { Run-Uninstall $n } else { -1 }
    Check 'インストール(片づけ・消せないものがある): 握りを外したあと、残った uninstall.ps1 で全部消える' { $R.k1b -eq 0 -and (Test-AllGone $n) }
    Check 'インストール(片づけの知らせ): uninstall.ps1 が残るなら、使っているものを閉じて「設定 > アプリ」からアンインストールするよう案内し、手で消す案内はしない' {
        $log -match '画面の知らせ（省略）: [^\r\n]*消しきれなかった[^\r\n]*設定 > アプリ' -and $log -notmatch '画面の知らせ（省略）: [^\r\n]*手で消す'
    }
    Wipe $n

    # k2: 前の版が無く、新しい版が登録とショートカットだけ作って終わり(uninstall.ps1 が無い)、フォルダの中に消せないものがある → 手で消す場所(レジストリも)を案内する
    $n = Name-Of 'k2'; $kit = New-Kit $n '9.2.0' 'crashbare'
    $dK2 = Dir-Of $n; Put "$dK2\zheld.txt" 'x'
    $lockK2 = [IO.File]::Open("$dK2\zheld.txt", 'Open', 'Read', 'None')
    try { $R.k2 = Run-Install $kit } finally { $lockK2.Dispose() }
    $logK2 = Read-Log (Join-Path $env:TEMP "$n-install.log")
    Check 'インストール(片づけの知らせ): uninstall.ps1 が無いなら、フォルダ・ショートカット・レジストリの登録を手で消すよう案内する（「設定 > アプリ」からとは言わない）' {
        $R.k2 -eq 1 -and -not (Test-Path "$dK2\uninstall.ps1") -and $logK2 -match '画面の知らせ（省略）: [^\r\n]*消しきれなかった[^\r\n]*レジストリ[^\r\n]*手で消す' -and $logK2 -notmatch '画面の知らせ（省略）: [^\r\n]*アンインストールする'
    }
    Wipe $n

    # b1: 前の版が無くて、新しい版が起動しない → 何も残さない
    $n = Name-Of 'b1'; $kit = New-Kit $n '9.2.0' 'broken'
    $R.b1 = Run-Install $kit
    $log = Read-Log (Join-Path $env:TEMP "$n-install.log")
    Check 'インストール(片づけ): 新しく入れて起動しないと終了コード 1、フォルダ・ショートカット・登録が何も残らない' { $R.b1 -eq 1 -and (Test-AllGone $n) }
    Check 'インストール(片づけ): 理由と片づけをログ(TEMP)に残し、知らせにログの場所を示す' { $log -match 'インストール: 失敗' -and $log -match '片づけ' -and $log -match [regex]::Escape("$n-install.log") -and $log -match '結果=exited' }
    Wipe $n

    # n1: 元の copathy.ps1 が無い
    $n = Name-Of 'n1'; $kit = New-Kit $n '9.1.0'; Remove-Item "$kit\copathy.ps1"
    $R.n1 = Run-Install $kit
    Check 'インストール(エラー): 隣に copathy.ps1 が無いと終了コード 1、何も作らず、ログに残る' { $R.n1 -eq 1 -and (Test-AllGone $n) -and (Read-Log (Join-Path $env:TEMP "$n-install.log")) -match 'copathy\.ps1 が見つからない' }
    Wipe $n

    # m1: 排他を取られていたら何もしない
    $n = Name-Of 'm1'; $kit = New-Kit $n '9.1.0'
    $hold = Hold-Setup $n
    try { $R.m1 = Run-Install $kit } finally { $hold.ReleaseMutex(); $hold.Dispose() }
    Check '二重実行: 排他が取られていたら、何もせず終了コード 0（失敗にしない）で、ログに残る' { $R.m1 -eq 0 -and (Test-AllGone $n) -and (Read-Log (Join-Path $env:TEMP "$n-install.log")) -match '何もしないで終わる' }
    Wipe $n

    # c1: ほぼ同時に 2 つ動かす。一方だけが入れ、他方は何もせず終わる。どちらも失敗にならない
    $n = Name-Of 'c1'; $kit = New-Kit $n '9.1.0' 'slow'
    $pa = Start-Ps "$kit\install.ps1" @() $kit; $pb = Start-Ps "$kit\install.ps1" @() $kit
    $ca = Wait-Ps $pa; $cb = Wait-Ps $pb
    $log = Read-Log (Join-Path $env:TEMP "$n-install.log")
    Check '二重実行: 続けて 2 回動かすと両方とも終了コード 0 で、入れるのは一方だけ（成功 1 回・何もしない 1 回）、失敗の行は無い' {
        $ca -eq 0 -and $cb -eq 0 -and ([regex]::Matches($log, 'インストール: 成功')).Count -eq 1 -and ([regex]::Matches($log, '何もしないで終わる')).Count -eq 1 -and $log -notmatch 'インストール: 失敗'
    }
    Check '二重実行: 入れた copathy は動いている' { (Test-Path (Join-Path (Dir-Of $n) 'copathy.ps1')) -and (Get-ProcCount "$(Dir-Of $n)\copathy.ps1") -ge 1 }
    Wipe $n

    # i1: インストールが動いている間だけ「Installing」の印を持つ。その間に消す処理を動かすと、相手がインストールと分かって知らせる
    $n = Name-Of 'i1'; $kit = New-Kit $n '9.1.0' 'slow'
    $pi = Start-Ps "$kit\install.ps1" @() $kit
    $sawI = $false; $limI = (Get-Date).AddSeconds(100)
    while (-not $pi.HasExited -and (Get-Date) -lt $limI) { if (Test-Mark $n 'Installing') { $sawI = $true; break }; Start-Sleep -Milliseconds 100 }
    $R.i1u = if ($sawI) { Run-UiLess $n @('-Yes') } else { -1 }
    $logI1 = Read-Log (Join-Path $env:TEMP "$n-uninstall.log")
    $R.i1 = Wait-Ps $pi
    Check 'インストール(印): 動いている間は Installing の印があり、終わると無い' { $sawI -and $R.i1 -eq 0 -and -not (Test-Mark $n 'Installing') }
    Check 'インストール中に消す処理を動かすと、何も消さず終了コード 2 で、インストール中と画面で知らせる' { $R.i1u -eq 2 -and $logI1 -match '画面の知らせ: .*インストール' -and (Test-Path (Join-Path (Dir-Of $n) 'copathy.ps1')) }
    Wipe $n

    # i2: インストールが排他を取れなかったとき、相手が消す処理(違う種類)なら画面で知らせ、相手がインストール(同じ種類)なら黙る。どちらも終了コード 0 で何も作らない
    $n = Name-Of 'i2'; $kit = New-Kit $n '9.1.0'
    $hold = Hold-Setup $n; $mU = $null; $mI = $null
    try {
        $mU = New-Object Threading.Mutex($false, "Local\$($n)Uninstalling")
        $R.i2a = Run-Install $kit; $logA = Read-Log (Join-Path $env:TEMP "$n-install.log")
        $mU.Dispose(); $mU = $null
        Remove-Item (Join-Path $env:TEMP "$n-install.log") -ErrorAction SilentlyContinue
        $mI = New-Object Threading.Mutex($false, "Local\$($n)Installing")
        $R.i2b = Run-Install $kit; $logB = Read-Log (Join-Path $env:TEMP "$n-install.log")
        $mI.Dispose(); $mI = $null
        Remove-Item (Join-Path $env:TEMP "$n-install.log") -ErrorAction SilentlyContinue
        $R.i2c = Run-Install $kit; $logC = Read-Log (Join-Path $env:TEMP "$n-install.log")
        # 先のインストーラーが片づけで消す処理を呼んでいる間は、Installing と Uninstalling の両方の印がある。同じ種類(インストール)として黙る
        Remove-Item (Join-Path $env:TEMP "$n-install.log") -ErrorAction SilentlyContinue
        $mU = New-Object Threading.Mutex($false, "Local\$($n)Uninstalling"); $mI = New-Object Threading.Mutex($false, "Local\$($n)Installing")
        $R.i2d = Run-Install $kit; $logDd = Read-Log (Join-Path $env:TEMP "$n-install.log")
    } finally { $hold.ReleaseMutex(); $hold.Dispose(); foreach ($m in $mU, $mI) { if ($m) { $m.Dispose() } } }
    Check 'インストール(排他・相手の種類): 相手が消す処理なら、何も作らず終了コード 0 で、画面で知らせる（画面は出さない形のログ）' { $R.i2a -eq 0 -and (Test-AllGone $n) -and $logA -match '画面の知らせ（省略）: .*消す処理' }
    Check 'インストール(排他・相手の種類): 相手がインストール(同じ種類)なら、黙って終了コード 0' { $R.i2b -eq 0 -and (Test-AllGone $n) -and $logB -notmatch '画面の知らせ' -and $logB -match '何もしないで終わる' }
    Check 'インストール(排他・相手の種類): 相手の印が無いときも、黙って終了コード 0' { $R.i2c -eq 0 -and (Test-AllGone $n) -and $logC -notmatch '画面の知らせ' }
    Check 'インストール(排他・相手の種類): Installing と Uninstalling の両方の印があるとき(先のインストーラーが片づけ中)は、同じ種類と見て黙る' { $R.i2d -eq 0 -and (Test-AllGone $n) -and $logDd -notmatch '画面の知らせ' -and $logDd -match '何もしないで終わる' }
    Wipe $n

    # i3: 合図のミューテックスがすぐ取れても(合図の結果にかかわらず)、インストール先の残っている copathy は止めてから上書きする
    $n = Name-Of 'i3'; $d3 = Dir-Of $n
    Put "$d3\copathy.ps1" "`$Version = '9.0.0'`r`nStart-Sleep 600`r`n"   # 合図の印(Mutex)を持たない、居残りの copathy
    $sleeper = Start-Ps "$d3\copathy.ps1" @() $env:TEMP
    Start-Sleep -Seconds 2
    $kit = New-Kit $n '9.1.0'
    $R.i3 = Run-Install $kit
    $log = Read-Log (Join-Path $env:TEMP "$n-install.log")
    Check 'インストール(居残り): 合図がすぐ戻っても、残っている copathy を止めてから進み、成功して新しい版が 1 つだけ動く' {
        $R.i3 -eq 0 -and $sleeper.HasExited -and $log -match '合図で終わらないので止める' -and ((Get-ProcCount "$d3\copathy.ps1") -eq 1) -and (Test-Path "$d3\probe-9.1.0.txt")
    }
    Wipe $n

    # ---- check-bumped.ps1(版の上げ忘れ)。一時のリポジトリと、にせの gh で動かす ----
    $cb = Join-Path $root '.github\scripts\check-bumped.ps1'
    Check 'check-bumped.ps1: BOM 付きで構文エラーが無く、リリースの一覧(gh)と copathy.ps1・install.ps1・*.lnk の違いを見る' {
        $bytes = [IO.File]::ReadAllBytes($cb); $e = $null; [void][Management.Automation.Language.Parser]::ParseFile($cb, [ref]$null, [ref]$e)
        $t = [IO.File]::ReadAllText($cb, [Text.Encoding]::UTF8)
        $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF -and $e.Count -eq 0 -and $t -match 'gh release list' -and $t -match "git diff --name-only" -and $t -match 'copathy\.ps1' -and $t -match 'install\.ps1' -and $t -match '\*\.lnk'
    }
    $repo = Join-Path $work 'bumped-repo'; $fakeBin = Join-Path $work 'fakebin'
    New-Item -ItemType Directory -Force $repo, $fakeBin | Out-Null
    [IO.File]::WriteAllText((Join-Path $fakeBin 'gh.cmd'), "@echo off`r`nfor %%t in (%FAKE_TAGS%) do echo %%t`r`n")
    $savedEnv = @{ PATH = $env:PATH; VERSION = $env:VERSION; FAKE_TAGS = $env:FAKE_TAGS; GIT_AUTHOR_NAME = $env:GIT_AUTHOR_NAME; GIT_AUTHOR_EMAIL = $env:GIT_AUTHOR_EMAIL; GIT_COMMITTER_NAME = $env:GIT_COMMITTER_NAME; GIT_COMMITTER_EMAIL = $env:GIT_COMMITTER_EMAIL }
    $gitOk = [bool](Get-Command git -ErrorAction SilentlyContinue)
    try {
        if ($gitOk) {
            $env:GIT_AUTHOR_NAME = $env:GIT_COMMITTER_NAME = 'test'; $env:GIT_AUTHOR_EMAIL = $env:GIT_COMMITTER_EMAIL = 'test@example.com'
            Push-Location $repo
            try {
                git init -q . 2>&1 | Out-Null
                Set-Content copathy.ps1 'a'; Set-Content install.ps1 'a'; Set-Content notes.txt 'a'
                git add -A 2>&1 | Out-Null; git commit -q -m first 2>&1 | Out-Null; git tag v1.0.0 2>&1 | Out-Null
            } finally { Pop-Location }
        }
        $env:PATH = "$fakeBin;$($savedEnv.PATH)"
        # 終了コードと、出力(または失敗の理由)を UTF-8 のファイルへ書く包みで動かす（失敗の理由まで見るため）
        function Run-Bumped($tags, $ver) {
            $env:FAKE_TAGS = $tags; $env:VERSION = $ver
            $outF = Join-Path $work 'bumped.out'; Remove-Item $outF -ErrorAction SilentlyContinue
            $wrap = Join-Path $work 'bumped-wrap.ps1'
            Put $wrap ('param($out)' + "`r`n" + 'try { $r = & ''' + $cb + ''' *>&1 | Out-String; [IO.File]::WriteAllText($out, $r, (New-Object Text.UTF8Encoding $true)); exit 0 } catch { [IO.File]::WriteAllText($out, "$($_.Exception.Message)", (New-Object Text.UTF8Encoding $true)); exit 1 }')
            $code = Wait-Ps (Start-Ps $wrap @($outF) $repo) 60000
            $script:bumpOut = Read-Log $outF
            $code
        }
        function Commit-File($name, $text) { Push-Location $repo; try { Set-Content $name $text; git add -A 2>&1 | Out-Null; git commit -q -m x 2>&1 | Out-Null } finally { Pop-Location } }
        if ($gitOk) {
            $b1 = Run-Bumped 'v1.0.0' '1.0.0'; $o1 = $script:bumpOut   # リリース済み・変更なし
            Commit-File 'notes.txt' 'b'
            $b2 = Run-Bumped 'v1.0.0' '1.0.0'; $o2 = $script:bumpOut   # リリース済み・届かないファイルだけ変更
            Commit-File 'copathy.ps1' 'b'
            $b3 = Run-Bumped 'v1.0.0' '1.0.0'; $o3 = $script:bumpOut   # リリース済み・届くファイルが変更（上げ忘れ）
            $b4 = Run-Bumped 'v0.9.0 v1.0.0' '1.1.0'; $o4 = $script:bumpOut   # 版を上げた（未リリース）
            $b5 = Run-Bumped 'v1.0.0' '1.0.0'; $o5 = $script:bumpOut   # もう一度（再現）
        }
    } finally { foreach ($k in $savedEnv.Keys) { if ($null -eq $savedEnv[$k]) { Remove-Item "Env:\$k" -ErrorAction SilentlyContinue } else { Set-Item "Env:\$k" $savedEnv[$k] } } }
    Check 'check-bumped.ps1(動かして確認): リリース済み・届くファイルに変更なし → 通る（届かないファイルだけの変更も通る）' { $gitOk -and $b1 -eq 0 -and $b2 -eq 0 -and $o1 -match '上げ忘れなし' -and $o2 -match '上げ忘れなし' }
    Check 'check-bumped.ps1(動かして確認): リリース済みの版なのに copathy.ps1 が変わっていたら失敗(版の上げ忘れ)' { $gitOk -and $b3 -eq 1 -and $b5 -eq 1 -and $o3 -match 'v1\.0\.0 はリリース済みなのに、使う人に届くファイルが変わっている' -and $o3 -match 'copathy\.ps1' -and $o3 -notmatch 'notes\.txt' -and $o5 -match 'リリース済みなのに' }
    Check 'check-bumped.ps1(動かして確認): 版を上げて未リリースなら、変わっていても通る' { $gitOk -and $b4 -eq 0 -and $o4 -match 'v1\.1\.0: 上げ忘れなし' }

    # ---- 本物の copathy.ps1 の写し（版は 99.0.0 にして、更新の確認で書きかわらないようにする） ----
    $curVer = [regex]::Match($mainText, "(?m)^\`$Version = '(\d+\.\d+\.\d+)'").Groups[1].Value
    function New-RealKit($n) {
        $kit = Join-Path $work $n
        Put "$kit\install.ps1" (Rename-App $installText $n)
        Put "$kit\copathy.ps1" ((Rename-App $mainText $n).Replace("`$Version = '$curVer'", "`$Version = '99.0.0'"))
        $kit
    }
    function Stop-ByQuit($n, $pattern) {
        $q = New-Object Threading.EventWaitHandle($false, 'ManualReset', "Local\$($n)Quit"); [void]$q.Set()
        $limit = (Get-Date).AddSeconds(20); while ((Get-ProcCount $pattern) -gt 0 -and (Get-Date) -lt $limit) { Start-Sleep -Milliseconds 300 }
        [void]$q.Reset(); $q.Dispose()
    }

    # r1: インストール先以外で動かしても、何も作らない。展開したフォルダを握らない（起動し直す Start-App）
    $n = Name-Of 'r1'; $kit = New-RealKit $n
    $cwdDir = Join-Path $work "$n-cwd"; New-Item -ItemType Directory -Force $cwdDir | Out-Null
    $ev = New-Object Threading.EventWaitHandle($false, 'ManualReset', "Local\$($n)Ready"); [void]$ev.Reset()
    $first = Start-Ps "$kit\copathy.ps1" @() $cwdDir
    $up = $ev.WaitOne(60000)
    [void](Wait-Ps $first 30000)
    Check '作業フォルダ: 画面なしで起動し直された copathy は、起動した場所のフォルダを握らない（消せる）' { Remove-Item $cwdDir -Recurse -Force -ErrorAction SilentlyContinue; $up -and -not (Test-Path $cwdDir) }
    Check '写し: インストール先以外では、自動起動・スタートメニューのショートカット・uninstall.ps1・「設定 > アプリ」の登録を作らない' {
        $up -and -not (Test-Path (Join-Path $startupDir "$n.lnk")) -and -not (Test-Path (Join-Path $programsDir "$n.lnk")) -and -not (Test-Path "$kit\uninstall.ps1") -and -not (Test-Path "$ukRoot\$n") -and -not (Test-Path (Dir-Of $n))
    }
    Check '写し: インストール先でないことがログに残る' { (Read-Log "$kit\log.txt") -match 'インストール先' }
    Stop-ByQuit $n "\$n\copathy.ps1"
    Check '写し: 合図(Quit)で終わる' { (Get-ProcCount "\$n\copathy.ps1") -eq 0 }
    $ev.Dispose()
    Wipe $n

    # r1c: 古い版が展開したフォルダを作業フォルダにして起動したときも、画面なしで起動した直後に放す（直接 headless で起動）
    $n = Name-Of 'r1c'; $kit = New-RealKit $n
    $cwdDir = Join-Path $work "$n-cwd"; New-Item -ItemType Directory -Force $cwdDir | Out-Null
    $ev = New-Object Threading.EventWaitHandle($false, 'ManualReset', "Local\$($n)Ready"); [void]$ev.Reset()
    [void](Start-Ps "$kit\copathy.ps1" @('headless') $cwdDir)
    $up = $ev.WaitOne(60000)
    Check '作業フォルダ: 引き継いだ作業フォルダ(展開したフォルダ)を、画面なしで動いている copathy は握らない（消せる）' { Remove-Item $cwdDir -Recurse -Force -ErrorAction SilentlyContinue; $up -and -not (Test-Path $cwdDir) }
    Stop-ByQuit $n "\$n\copathy.ps1"
    $ev.Dispose()
    Wipe $n

    # f1: 画面が使えない環境（CI など）のまね。本物の写しの画面を読み込む所で失敗させ、止まり続けず、長く待たずに失敗として片づくこと
    $n = Name-Of 'f1'; $kit = New-RealKit $n
    $t = [IO.File]::ReadAllText("$kit\copathy.ps1", [Text.Encoding]::UTF8)
    $t2 = $t.Replace('Add-Type -AssemblyName System.Windows.Forms, System.Drawing', "throw '画面が使えない(テスト)'").Replace('(New-Object -ComObject WScript.Shell).Popup(', '@(')
    if ($t2 -ceq $t) { throw 'f1: 置きかえが効いていない' }
    Put "$kit\copathy.ps1" $t2
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $R.f1 = Run-Install $kit 100000
    $sw.Stop()
    $log = Read-Log (Join-Path $env:TEMP "$n-install.log")
    Check '画面が使えないとき: インストールは 40 秒以内に失敗(終了コード 1)で終わる（60 秒の待ちや画面待ちで止まらない）' { $R.f1 -eq 1 -and $sw.Elapsed.TotalSeconds -lt 40 -and $log -match '結果=exited' }
    Check '画面が使えないとき: 動いたままのものが無く、作ったもの(フォルダ・ショートカット・登録)も残らない' { (Get-ProcCount "\$n\") -eq 0 -and (Test-AllGone $n) }
    Wipe $n

    # r2:本物の写しをインストール → 登録の内容 → 起動のたび書き直す → 消す
    $n = Name-Of 'r2'; $kit = New-RealKit $n; $dirR = Dir-Of $n
    $R.r2 = Run-Install $kit 120000
    $key = if (Test-Path "$ukRoot\$n") { Get-ItemProperty "$ukRoot\$n" } else { $null }
    Check '写し(インストール先): インストールが成功し、copathy が動く' { $R.r2 -eq 0 -and (Get-ProcCount "$dirR\copathy.ps1") -ge 1 }
    Check '写し(インストール先): 登録の内容(名前・版・発行元・アイコン・場所・URL・NoModify・NoRepair)' {
        $key.DisplayName -ceq $n -and $key.DisplayVersion -ceq '99.0.0' -and $key.Publisher -ceq 'ogura-ryoya' -and $key.DisplayIcon -ieq "$dirR\$n.ico" -and
        $key.InstallLocation -ieq $dirR -and $key.URLInfoAbout -match '^https://github\.com/ogura-ryoya/copathy' -and $key.NoModify -eq 1 -and $key.NoRepair -eq 1
    }
    Check '写し(インストール先): UninstallString は画面なし(--headless)で uninstall.ps1 を絶対パスで動かす' {
        $u = $key.UninstallString; $u -match '--headless' -and $u -match 'powershell' -and $u.IndexOf("$dirR\uninstall.ps1", [StringComparison]::OrdinalIgnoreCase) -ge 0 -and $u -notmatch '-Quiet'
    }
    Check '写し(インストール先): uninstall.ps1 が書き出される（BOM 付き、正本の名前置きかえと同じ中身）' {
        $b = [IO.File]::ReadAllBytes("$dirR\uninstall.ps1"); $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF -and ([IO.File]::ReadAllText("$dirR\uninstall.ps1", [Text.Encoding]::UTF8) -ceq (Get-UninstallText $n))
    }
    Check '作業フォルダ: 作る自動起動・スタートメニューのショートカットの作業フォルダはユーザーのフォルダ' {
        $sh = New-Object -ComObject WScript.Shell
        $a = $sh.CreateShortcut((Join-Path $startupDir "$n.lnk")); $b = $sh.CreateShortcut((Join-Path $programsDir "$n.lnk"))
        $a.WorkingDirectory -ieq $env:USERPROFILE -and $b.WorkingDirectory -ieq $env:USERPROFILE -and $a.Arguments -match 'headless'
    }
    Check '作業フォルダ: 本物の写しで入れたあとも、展開したフォルダを消せる' { Remove-Item $kit -Recurse -Force -ErrorAction SilentlyContinue; -not (Test-Path $kit) }
    # 起動のたびに書き直す（壊れていても、消えていても直る）
    Stop-ByQuit $n "$dirR\copathy.ps1"
    Remove-Item "$dirR\uninstall.ps1" -Force
    Set-ItemProperty "$ukRoot\$n" -Name DisplayVersion -Value '0.0.1'
    $ev = New-Object Threading.EventWaitHandle($false, 'ManualReset', "Local\$($n)Ready"); [void]$ev.Reset()
    # 「消している印」(確認を出している間も持つ印)を立てたまま起動し、更新の確認を始めないことを確かめる。ここから先の log.txt の行だけを見る
    $logLen = (Read-Log "$dirR\log.txt").Length
    $markHold = New-Object Threading.Mutex($false, "Local\$($n)Uninstalling")
    $checkPat = '最新版（|更新を確認できなかった|が見つかった'
    [void](Start-Ps "$dirR\copathy.ps1" @('headless') $env:TEMP)
    $up2 = if ($R.r2 -eq 0) { $ev.WaitOne(60000) } else { $false }; $ev.Dispose()
    if ($up2) { Start-Sleep -Seconds 8 }  # 起動後 1 秒ごとのタイマーが何度も回る時間
    $logNew = (Read-Log "$dirR\log.txt").Substring($logLen)
    $noCheckWhileMarked = $up2 -and $logNew -notmatch $checkPat
    $markHold.Dispose()  # 印を外すと、確認が始まる(通信できなくても「確認できなかった」と記録される)
    $limit = (Get-Date).AddSeconds(45)
    while ($up2 -and ((Read-Log "$dirR\log.txt").Substring($logLen) -notmatch $checkPat) -and (Get-Date) -lt $limit) { Start-Sleep -Milliseconds 500 }
    $checkAfterRelease = $up2 -and ((Read-Log "$dirR\log.txt").Substring($logLen) -match $checkPat)
    Check '写し(インストール先): 起動のたびに uninstall.ps1 と登録の版を書き直す' {
        $up2 -and (Test-Path "$dirR\uninstall.ps1") -and (Get-ItemProperty "$ukRoot\$n").DisplayVersion -ceq '99.0.0'
    }
    Check '更新の抑止(動かして確認): 消している印がある間は、更新の確認を始めない' { $noCheckWhileMarked }
    Check '更新の抑止(動かして確認): 印を外すと更新の確認が始まる（上の確かめが「確認が元々起きない」だけでないこと）' { $checkAfterRelease }
    $R.r2u = Run-Uninstall $n @('-Quiet') 120000
    Check '写し(インストール先): 動いたまま uninstall.ps1 -Quiet で、合図で終わらせて全部消える' { $R.r2u -eq 0 -and (Get-ProcCount "\$n\") -eq 0 -and (Test-AllGone $n) }
    Wipe $n

    # ---- 止まる版（並べて動かしていたもの） ----
    $R.h1 = Wait-Ps $hangProc 120000
    $log = Read-Log (Join-Path $env:TEMP "$nH-install.log")
    Check 'インストール(止まる版・新規): 起動の知らせが来ないまま 60 秒で、終了コード 1' { $R.h1 -eq 1 -and $log -match '結果=timeout' }
    Check 'インストール(止まる版・新規): 起動しかけた copathy を止め、消すスクリプトを画面なしで呼び、何も残らない' {
        (Get-ProcCount "\$nH\") -eq 0 -and (Test-AllGone $nH) -and $log -match '起動しかけた copathy を止める' -and $log -match '消すスクリプトの結果=0'
    }
    Wipe $nH

    # v3 の結果（前の版あり・起動の知らせが来ない）
    $R.v3 = Wait-Ps $v3Proc 120000
    $log = Read-Log (Join-Path $env:TEMP "$nV3-install.log")
    $iStop = $log.IndexOf('起動しかけた copathy を止める'); $iBack = $log.IndexOf('前の版を起動して待った')
    $dV3 = Dir-Of $nV3
    Check 'インストール(戻し・起動の知らせが来ない): 60 秒で終了コード 1、起動しかけた copathy を止めてから前の版に戻す' {
        $R.v3a -eq 0 -and $R.v3 -eq 1 -and $log -match '結果=timeout' -and $iStop -ge 0 -and $iBack -gt $iStop
    }
    Check 'インストール(戻し・起動の知らせが来ない): 前の版の中身に戻り、前の版だけが動き、控えと installed.flag は残らない' {
        ([IO.File]::ReadAllText("$dV3\copathy.ps1") -ceq $origV3) -and $log -match '前の版を起動して待った [\d.]+ 秒 結果=ready' -and (Get-ProcCount "$dV3\copathy.ps1") -eq 1 -and -not (Test-Path "$dV3\copathy.previous.ps1") -and -not (Test-Path "$dV3\installed.flag")
    }
    Wipe $nV3
} finally {
    foreach ($n in $names) { Wipe $n }
    foreach ($p in (Get-Procs "\$tp")) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Get-ChildItem $env:LOCALAPPDATA -Directory -Filter "$tp*" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem $startupDir, $programsDir -Filter "$tp*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem $ukRoot, $nkRoot -ErrorAction SilentlyContinue | Where-Object PSChildName -like "*$tp*" | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem $env:TEMP -Filter "$tp*" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    if ($null -eq $savedNoUi) { Remove-Item Env:\SETUP_NO_UI -ErrorAction SilentlyContinue } else { $env:SETUP_NO_UI = $savedNoUi }
}
Check '本物の copathy のインストール先・ショートカット・登録・合図に触っていない' { (Get-RealState) -ceq $realBefore }
Check '後片づけ: 名前を変えた写しのインストール先・ショートカット・登録・TEMP のログが残っていない' {
    -not (Get-ChildItem $env:LOCALAPPDATA -Directory -Filter "$tp*" -ErrorAction SilentlyContinue) -and -not (Get-ChildItem $startupDir, $programsDir -Filter "$tp*" -ErrorAction SilentlyContinue) -and
    -not (Get-ChildItem $ukRoot -ErrorAction SilentlyContinue | Where-Object PSChildName -like "*$tp*") -and -not (Get-ChildItem $env:TEMP -Filter "$tp*" -ErrorAction SilentlyContinue) -and -not (Test-Path $work)
}
