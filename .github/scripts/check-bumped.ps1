# v$VERSION がリリース済みなのに、使う人に届くファイルが変わっていたら（版の上げ忘れ）失敗させる。どのブランチでも動かす
# 日本語を Windows PowerShell 5.1 で扱うため、このファイルは UTF-8 BOM 付きで保存する
$ErrorActionPreference = 'Stop'

$tag = "v$env:VERSION"
$released = @(gh release list --limit 1000 --json tagName --jq '.[].tagName') -contains $tag
if ($LASTEXITCODE -ne 0) { throw 'リリースの一覧を取得できなかった' }
if ($released) {
    # 緑のままだと、届かないことに気づけない
    $changed = @(git diff --name-only $tag HEAD -- 'copathy.ps1' 'install.ps1' '*.lnk')
    if ($LASTEXITCODE -ne 0) { throw "$tag との違いを調べられなかった" }
    if ($changed.Count -gt 0) { throw "$tag はリリース済みなのに、使う人に届くファイルが変わっている（$($changed -join '、')）。`$Version を上げる" }
}
Write-Host "${tag}: 上げ忘れなし"
