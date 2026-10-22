# copathy.ps1 を検証し、$Version を GITHUB_OUTPUT の version に書き出す。壊れていれば失敗させる
# 日本語を Windows PowerShell 5.1 で扱うため、このファイルは UTF-8 BOM 付きで保存する
$ErrorActionPreference = 'Stop'

$f = (Resolve-Path 'copathy.ps1').Path
$bytes = [IO.File]::ReadAllBytes($f)
if ($bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
    throw 'copathy.ps1 が UTF-8 BOM 付きでない（Windows PowerShell 5.1 で日本語が文字化けする）'
}

$errors = $null
[void][Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$errors)
if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Host "$($_.Extent.StartLineNumber) 行目: $($_.Message)" }
    throw 'copathy.ps1 に構文エラーがあります'
}

$match = [regex]::Match([IO.File]::ReadAllText($f, [Text.Encoding]::UTF8), "(?m)^\`$Version = '(\d+\.\d+\.\d+)'")
if (-not $match.Success) { throw "copathy.ps1 に `$Version = 'X.Y.Z' が見つからない" }

$version = $match.Groups[1].Value
Write-Host "バージョン: $version"
[IO.File]::AppendAllText($env:GITHUB_OUTPUT, "version=$version`n")
