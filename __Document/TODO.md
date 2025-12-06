---
tags:
  - todo
title: __Document/TODO.md
---

# TODO

なにができていれば、各ユーザ（技術に疎い）に対して、個人リポジトリの利用を開始させられるだろうか？

- [x] 誤Pushの抑制機能

- [ ] 煩雑な設定の全自動化
  - インストール含む

## Critical な仕組み

Clone したあとに**確実に実行してもらいたい**ので、「初回の Clone それ自体をスクリプト側で実施」する

- [x] Git の config 設定確認(local/global)
- [x] 自分が管轄しないリポジトリ~~の `main` ブランチ~~へのpushは禁止
- [x] `upstream` の設定
- [x] 共有フォルダへのPush時に競合を防止する仕組み（フックに仕込む）
  - `main` ブランチへの push を禁止すればよさそう
- [x] Attachment への画像どうする問題
  - そもそも、リポジトリに画像を含めないので、その扱いをどうするか
  - hook 内に盛り込むので、`.script\__DoNotTouch\hooks` で議論


- [x] `.obsidian/` および `.vscode/` をユーザ固有の初期値化するためのスクリプト
  - プラグインおよび拡張機能のアプデを速やかに行うための自動化スクリプト
  - `.obsidian` 配下を走査し、`{USER_ID}` を探して `%USERPROFILE%` に置き換える
    - `data.default.json` があれば、`data.json` を作成（既存ファイルは退避する）


## Clone の前準備

- [x] そもそも個人リポジトリを clone してもらうために、git + VSCode のインストールを自動化するスクリプト
- [x] 共有フォルダの一部を `R:\` としてマウントしてもらう作業も必要
  - Clone する際に確認して適宜コマンド実行すればよいので独立させる必要はなし


## Clone / pull 時に必要なこと

- [x] `R:\UsersVault\{USER_ID}.git` を clone してくる際に `--recurse-submodule`
- [x] ↑ に加えて、フックを仕込むためのユーザースクリプト（CMDダブルクリックが理想）


## Obsidian

- [x] 各種テンプレートの作成（`Daily`, `Misc`）
  - 個人的に便利に使えるようにカスタマイズして、それを組織展開するスクリプトを考えればよい

- [ ] Daily.md 内に含まれる tepmlater スクリプトに対して、{USER_ID} で置換する必要アリ
