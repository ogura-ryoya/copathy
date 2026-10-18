# v$VERSION が未リリースなら、前回のタグ以降のコミットメッセージをリリースノートにしてリリースを作る
# 日本語を Windows PowerShell 5.1 で扱うため、このファイルは UTF-8 BOM 付きで保存する
$ErrorActionPreference = 'Stop'

$tag = "v$env:VERSION"
$released = @(gh release list --limit 1000 --json tagName --jq '.[].tagName') -contains $tag
if ($LASTEXITCODE -ne 0) { throw 'リリースの一覧を取得できませんでした' }
if ($released) {
    Write-Host "$tag はリリース済みなので、何もしません"
    exit 0
}

[Console]::OutputEncoding = [Text.Encoding]::UTF8  # 日本語のコミットメッセージを文字化けさせない
$previous = @(git tag --merged HEAD --list 'v*' --sort=-v:refname) | Select-Object -First 1
$range = if ($previous) { "$previous..HEAD" } else { 'HEAD' }
$lines = @(git log $range --no-merges --format='- %s')
if ($lines.Count -eq 0) { $lines = @('- 変更なし') }
$notesFile = Join-Path $env:RUNNER_TEMP 'notes.md'
[IO.File]::WriteAllText($notesFile, ($lines -join "`n"), (New-Object Text.UTF8Encoding $false))

gh release create $tag --target $env:GITHUB_SHA --title "copathy $tag" --notes-file $notesFile --latest
if ($LASTEXITCODE -ne 0) { throw 'リリースを作れませんでした' }
Write-Host "$tag をリリースしました"
