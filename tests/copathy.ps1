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
