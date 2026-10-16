# copathy

Windows エクスプローラーで選択中のファイル・フォルダのパスを、**Ctrl+Alt+C** で一気にコピーする常駐ツールです。

## 出力例

ファイル1つ

```
C:\Work\file1.txt
```

フォルダ1つ

```
C:\Work\Docs\
```

同じフォルダ内で複数選択

```
C:\Work\
Docs\
Images\
archive.zip
file2.txt
file10.txt
```

親フォルダがばらばら（検索結果など）

```
C:\Work\Docs\
Sub\
a.txt
b.txt

C:\Work\Images\logo.png
D:\Backup\old.txt
```

- フォルダが先、ファイルが後。名前は数字を数として並べます（file2 → file10）
- 同じフォルダから2つ以上選んだものは、フォルダのパスの下に名前を並べます
- そのフォルダから1つだけ選んだものは、最後にフルパスでまとめて出します
- 何も選択していないときは何もしません
- エクスプローラーが前面にあるときだけ反応するので、ほかのアプリの Ctrl+Alt+C はそのまま使えます

## 動作環境

- Windows 10 / 11
- .NET Framework 4.x（Windows に標準で入っています）

## ビルド

Windows 標準の .NET Framework のコンパイラを使うので、追加のインストールは不要です。

```
build.bat
```

`copathy.exe` ができます。

## 使い方

- `copathy.exe` を起動するとタスクトレイに常駐し、Windows の自動起動に登録されます
- トレイのメニューの「終了（自動起動も解除）」で終了し、自動起動の登録も消えます
- もう一度使うときは `copathy.exe` を起動してください
- 起動中にもう一度 `copathy.exe` を起動すると、古いほうが終了して新しいほうに入れ替わります（新しい exe に差し替えたときなど）
- 実行中は exe が使用中になるため、ビルドし直すときは先にトレイから終了してください

## ライセンス

[MIT](LICENSE)
