# v$VERSION が未リリースなら、前回のタグ以降のコミットメッセージをリリースノートにしてリリースを作る
# 日本語を Windows PowerShell 5.1 で扱うため、このファイルは UTF-8 BOM 付きで保存する
$ErrorActionPreference = 'Stop'

$tag = "v$env:VERSION"
$released = @(gh release list --limit 1000 --json tagName --jq '.[].tagName') -contains $tag
if ($LASTEXITCODE -ne 0) { throw 'リリースの一覧を取得できなかった' }
if ($released) {
    # 使う人に届くファイルが変わったのに版が同じなら、上げ忘れなので失敗させる（緑のままだと届かないことに気づけない）
    $changed = @(git diff --name-only $tag HEAD -- 'copathy.ps1' 'install.ps1' '*.lnk')
    if ($LASTEXITCODE -ne 0) { throw "$tag との違いを調べられなかった" }
    if ($changed.Count -gt 0) { throw "$tag はリリース済みなのに、使う人に届くファイルが変わっている（$($changed -join '、')）。`$Version を上げる" }
    Write-Host "$tag はリリース済みなので、何もしない"
    exit 0
}

[Console]::OutputEncoding = [Text.Encoding]::UTF8  # 日本語のコミットメッセージを文字化けさせない
$previous = @(git tag --merged HEAD --list 'v*' --sort=-v:refname) | Select-Object -First 1
$range = if ($previous) { "$previous..HEAD" } else { 'HEAD' }
# 使う人に関係ないもの(AI 向けのルール・テスト・リリースの仕組み)だけを変えたコミットは載せない
$lines = @(git log $range --no-merges --format='- %s' -- . ':(exclude)CLAUDE.md' ':(exclude)tests' ':(exclude).github')
if ($lines.Count -eq 0) { $lines = @('- 変更なし') }
$notesFile = Join-Path $env:RUNNER_TEMP 'notes.md'
[IO.File]::WriteAllText($notesFile, ($lines -join "`n"), (New-Object Text.UTF8Encoding $false))

gh release create $tag --target $env:GITHUB_SHA --title "copathy $tag" --notes-file $notesFile --latest
if ($LASTEXITCODE -ne 0) { throw 'リリースを作れなかった' }
Write-Host "$tag をリリースした"
