# copathy

Windows のエクスプローラーで選んだファイル・フォルダのパスを、**Ctrl+Alt+C** でまとめてコピーするツール。

- Ctrl+Alt+C が効くのはエクスプローラーが前面にあるときだけ（デスクトップでは効かない）。ほかのアプリには影響しない
- タスクトレイに常駐し、サインイン時に自動で起動する

## インストール

1. [最新のリリース](https://github.com/ogura-ryoya/copathy/releases/latest) の **Source code (zip)** をダウンロードして展開する
2. 展開したフォルダの **「copathy をインストール」** をダブルクリックする（ZIP を開いたまま実行すると、展開するよう知らせが出る）

「copathy をインストールした」と通知が出れば完了（展開したフォルダは、インストール後に消してよい）。新しい版を起動できなかったときは、前の版に戻して、画面で知らせる。インストールのログは `%TEMP%\copathy-install.log` に残る。セキュリティの警告が出たら **実行** を押す（**詳細情報** と出たら、それを押してから **実行**）。1 分たっても何も出ないときは、ウイルス対策ソフトに止められているかもしれない。

## 使い方

エクスプローラーでファイルやフォルダを選んで **Ctrl+Alt+C** を押すと、パスがコピーされる。

ファイル 1 つ

```
C:\Work\file1.txt
```

フォルダ 1 つ

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

- フォルダが先、ファイルが後。名前は数字を数として並べる（file2 → file10）
- 同じフォルダから 2 つ以上選んだものは、フォルダのパスの下に名前を並べる。1 つだけのものは、最後にフルパスでまとめる
- ごみ箱やコントロールパネルなど、ファイルのパスにならない場所ではコピーしない（そう知らせる）
- ほかのアプリが Ctrl+Alt+C を使っていて効かないときは、そう知らせる

トレイのアイコンを右クリックすると、次のことができる。

- バージョンの確認、GitHub を開く、更新の確認
- **ログをコピー**：うまく動かないときは、これを押してから開発者に貼り付けて送る（トレイにアイコンが出ないときは `%LOCALAPPDATA%\copathy\log.txt` を送る）
- **終了（自動起動も解除）**：止めて、次のサインインから起動しないようにする。スタートメニューの「copathy」からまた起動できる
- **アンインストール**：確認のあと、消す（下の「アンインストール」を見る）

## 更新

起動時と、動いている間は1日ごとに新しい版を確かめ、あれば自動で更新する。更新の内容は [Releases](https://github.com/ogura-ryoya/copathy/releases) で見られる。

## アンインストール

「設定 > アプリ > インストールされているアプリ」の **copathy** から消す。トレイのアイコンを右クリックして **アンインストール** を選んでもよい。どちらも確認のあと、次のものをすべて消す（元に戻せない）。

- 自動起動とスタートメニューのショートカット
- `%LOCALAPPDATA%\copathy`（ログを含む）
- 通知の設定と、「設定 > アプリ」の登録

消せなかったものがあれば、画面で知らせる。「設定 > アプリ」の登録は、ほかがすべて消えたときだけ最後に消すので、残ったときはそこからもう一度消せる。理由は `%TEMP%\copathy-uninstall.log` に残る。

「設定 > アプリ」にも出ない、トレイも使えないとき（2.4 以前の版のまま起動できないなど）は、次を手で消す。

- `%LOCALAPPDATA%\copathy` のフォルダ
- スタートアップ（`shell:startup`）とスタートメニュー（`shell:programs`）の `copathy.lnk`
- レジストリ（`regedit` で開く）の次の 2 か所
  - `HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall\copathy`
  - `HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\ogura-ryoya.copathy`

## 動作環境

Windows 10 / 11（追加のインストールは要らない）。会社の PC などで PowerShell スクリプトの実行が禁止されていると動かない。

## 開発者向け

`copathy.ps1` の `$Version` を上げて main にプッシュすると、GitHub Actions がテスト（`tests/run.ps1`）を動かしてリリースを作る。リリースノートは前のリリースからのコミットメッセージで作られる（CLAUDE.md・tests・.github だけを変えたコミットは載らない）。

## ライセンス

[MIT](LICENSE)
