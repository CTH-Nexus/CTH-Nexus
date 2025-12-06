---
tags:
  - readme
title: .script/README.md
---

# 📦 スクリプト一覧と運用ガイド

このリポジトリには、**管理者用**と**利用者用**の PowerShell スクリプトが含まれている。
共有フォルダ構造は以下の方針に従う：

```
R:\
  UsersVault\{USER_ID}.git          ← 個人ベアリポジトリ
  Submodule\
    Member\{USER_ID}.git            ← 個人向けサブモジュール
    Shared\User\{USER_ID}.git       ← 共有向けサブモジュール
  {TEAM_REPO}.git                   ← チーム用ベア
  Upload\                           ← 画像等の保存場所
  .obsidian.git                     ← Obsidian プラグイン配布
```

---

## ✅ 管理者が実行すべきスクリプト

### 1. `Create-BareRepos.ps1`

- **目的**: ID リストに基づき、共有フォルダにベアリポジトリを作成。

#### Usage

```powershell
# R: ドライブをマウント
net use R: "\\fileserver\share"

# スクリプト実行（IDリスト選択ダイアログが開く）
powershell.exe -ExecutionPolicy Bypass -NoProfile -STA `
  -File ".\.script\__DoNotTouch\Create-BareRepos.ps1"
```

---

### 2. `Generate-Gitmodules.ps1`

- **目的**: `.gitmodules` を自動生成（Shared のサブモジュール定義）。

#### Usage

```powershell
# R: ドライブをマウント
net use R: "\\fileserver\share"

powershell.exe -ExecutionPolicy Bypass -NoProfile -STA `
  -File ".\.script\__DoNotTouch\Generate-Gitmodules.ps1"
```

---

### 3. `Setup-Submodules.ps1`

- **目的**: サブモジュールのセットアップ

#### Usage

```powershell
net use R: "\\fileserver\share"
# 検証
powershell.exe -ExecutionPolicy Bypass -NoProfile -STA `
  -File ".\.script\__DoNotTouch\Setup-Submodules.ps1" -Summary -DryRun
# Stable＝固定SHA再現
powershell.exe -ExecutionPolicy Bypass -NoProfile -STA `
  -File ".\.script\__DoNotTouch\Setup-Submodules.ps1" -Mode Stable -Summary
# Latest＝ブランチ先端へ
powershell.exe -ExecutionPolicy Bypass -NoProfile -STA `
  -File ".\.script\__DoNotTouch\Setup-Submodules.ps1" -Mode Latest -Summary
```

---

### 4. `Setup-UserSparseCheckout.ps1`

- **目的**: 個人用リポジトリを初期化し、`R:\UsersVault\{USER_ID}.git` に push。

#### Usage

```powershell
net use R: "\\fileserver\share"
powershell.exe -ExecutionPolicy Bypass -NoProfile -STA `
  -File ".\.script\__DoNotTouch\Setup-UserSparseCheckout.ps1"
```

#### 完了チェックリスト（ログ対応）

- IDリスト選択：Using ID list file: ...`id_list.txt`
  - ✅ ダイアログ→ファイル取得のフローが正常。

- 作業ディレクトリ初期化：Creating per-run work directory at: ...`\work\<RunKey>`
  - ✅ RunKey（日時+ハッシュ+PID）でユニークなワークディレクトリが作成。

- 全ユーザ処理（Process-AllUsers）開始
  - ターゲットベア初期化：Target bare repo does not exist. Creating... → Successfully created bare repo.
    - ✅ 既存確認→未存在→init --bare 成功。既存時は正常スキップに修正済み。
  - ソースベア検証：Verifying source repository at 'R:\Knewrova.git'... → Source repository verified successfully.
    - ✅ HEAD 存在チェックOK。
  - クローン：Cloning 'R:\Knewrova.git' ... → Cloning into 'A1200001'... done.
    - ✅ --no-checkout クローン成功、作業ディレクトリへ移動。
  - スパースチェックアウト：Initializing sparse-checkout (cone mode)... → Setting sparse-checkout paths for A1200001...
    - ✅ MyWork/ を含む対象パスに更新反映済み。
  - mainチェックアウト：Checking out 'main' branch... Already on 'main'
    - ✅ main のチェックアウト成功。
  - リモート設定：remote rename origin upstream / push upstream DISABLED / add origin R:\UsersVault...
    - ✅ origin=UsersVault, upstream=ソース, upstream push disabled のポリシー通り。
  - remote -v の表示も期待どおり。
    - push要否判定：Branch 'main' does not exist on 'origin'. Proceeding with initial push.
    - ✅ ls-remote で ExitCode=2 → 初回 push 必要判定成功。
  - 初回push：push -u origin main → Successfully pushed 'main' to 'origin'.
    - ✅ 追跡設定＆新規ブランチ作成（[new branch] main -> main）。
    - ※サーバ側 '$GIT_DIR' too big は通知ですが、push は成功しており影響なし。
  - ユーザ単位サマリ：--- Successfully processed User: A1200001 in 66.92 seconds ---
    - ✅ 所要時間と成功ログ出力。

- 後処理：Cleaning up this run's work directory: ... → Work directory successfully deleted.
  - ✅ クリーンアップ成功。

- 総括：SCRIPT COMPLETED SUCCESSFULLY.
  - ✅ 全体成功、期待どおりの終端メッセージ。

---


---

## ✅ 利用者が実行すべきスクリプト

### 1. `SoftwareCheck.ps1`

- **目的**: Obsidian / PortableGit / VSCode のインストール状況を確認し、共有フォルダの最新インストーラで更新。
- **設定方針**: `.env` により共有フォルダパスを自動指定（引数不要）。

#### Usage

```powershell
# R: ドライブをマウント
net use R: "\\fileserver\share"

# DryRun（インストールせず計画のみ表示）
powershell.exe -ExecutionPolicy Bypass -NoProfile -STA `
  -File ".\.script\__DoNotTouch\SoftwareCheck.ps1" -DryRun

# 本番（.env に基づき自動設定）
powershell.exe -ExecutionPolicy Bypass -NoProfile -STA `
  -File ".\.script\__DoNotTouch\SoftwareCheck.ps1"
```

---

### 2. `RegisterSafeDirectory.ps1`

- **目的**: Git の `safe.directory` を一括登録します。対象は以下の通り:
  - **id_list.txt に記載されたユーザ ID** に基づくベアリポジトリ
    - 例: `R:\UsersVault\<ID>.git`（※ `<ID>.git` は **`-IdBaseDir` で指定した各ディレクトリ直下**に展開）
  - **そのまま登録する個別ターゲット**（チーム共通の `.obsidian` ベア、チーム用ベア／ワークツリー 等）
    - 例: `R:\.obsidian.git`、`R:\Knewrova.git`（※ **`-TargetDir`** で明示指定）

- **設定方針**:
  - **UNC パス（`\\server\share`）は禁止**。**ドライブレターでマッピングされた絶対パス**を指定してください。
  - `safe.directory` は **スラッシュ形式（`/`）**で登録します。
  - `id_list.txt` は **`-IdBaseDir` が指定されている場合のみ**使用します。**引数未指定または既定位置（ScriptDir）にない場合**、GUI ダイアログで選択可能。
  - `-DryRun` 指定時のみ**確認のみ（適用なし）**。未指定時は**適用モード**（承認プロンプトあり）。`-NoPrompt` で**承認なし適用**。

#### Usage

```powershell
# DRY-RUN
powershell.exe -ExecutionPolicy Bypass -NoProfile -STA `
  -File ".\.script\__DoNotTouch\RegisterSafeDirectory.ps1" `
  -IdBaseDir "R:\UsersVault","R:\Submodule\Member" `
  -TargetDir "R:\.obsidian.git","R:\Knewrova.git" `
  -DryRun

# 本番（承認なし）
powershell.exe -ExecutionPolicy Bypass -NoProfile -STA `
  -File ".\.script\__DoNotTouch\RegisterSafeDirectory.ps1" `
  -IdBaseDir "R:\UsersVault","R:\Submodule\Member" `
  -TargetDir "R:\.obsidian.git","R:\Knewrova.git" `
  -NoPrompt
```

---

### 3. `Clone-and-Initialize.ps1`

- **目的**: 個人ベアリポジトリをクローンし、初期化（サブモジュール、hooks、config）。

#### Usage

```powershell
net use R: "\\fileserver\share"
powershell.exe -ExecutionPolicy Bypass -NoProfile -STA `
  -File ".\.script\__DoNotTouch\Clone-and-Initialize.ps1" `
  -rShareUNC "\\fileserver\share" `
  -repoPath "R:\UsersVault\{USER_ID}.git" `
  -teamRepo "R:\{TEAM_REPO}.git"
```

---

### 4. `Git-ConfigCheck.ps1`

- **目的**: Git 設定の整合性確認と修正。

#### Usage

```powershell
net use R: "\\fileserver\share"
cd ClonedUserRepo/

# DryRun
powershell.exe -ExecutionPolicy Bypass -NoProfile -STA `
  -File ".\.script\__DoNotTouch\Git-ConfigCheck.ps1" -DryRun

# 本番
powershell.exe -ExecutionPolicy Bypass -NoProfile -STA `
  -File ".\.script\__DoNotTouch\Git-ConfigCheck.ps1"
```

---

### 5. `Set-HooksPath-For-Submodules.ps1`

- **目的**: サブモジュールに hooksPath を適用。

#### Usage

```powershell
net use R: "\\fileserver\share"
cd ClonedUserRepo/

powershell.exe -ExecutionPolicy Bypass -NoProfile -STA `
  -File ".\.script\__DoNotTouch\Set-HooksPath-For-Submodules.ps1" -DryRun
```

---

### 6. `Setup-Obsidian.ps1`

- **目的**: `.env` に基づき Obsidian Vault とプラグインをセットアップ。

#### Usage

```powershell
net use R: "\\fileserver\share"
cd ClonedUserRepo/

# DryRun
powershell.exe -ExecutionPolicy Bypass -NoProfile -STA `
  -File ".\.script\__DoNotTouch\Setup-Obsidian.ps1" -DryRun

# 本番
powershell.exe -ExecutionPolicy Bypass -NoProfile -STA `
  -File ".\.script\__DoNotTouch\Setup-Obsidian.ps1" -Y
```


## `Pre-Commit` Hooks

このフォルダーには、Git フック `pre-commit` と補助スクリプト `scripts/commit-submodules.sh` を配置します。
目的は **親リポジトリのコミット直前に、管轄するサブモジュールの Add+Commit+Push を確実に完了させ、更新された gitlink を親コミットに含める**ことです。

#### 問題の核心
- 親リポジトリでコミットが走ったタイミングで、
- **管轄サブモジュール**に対し **Add（全変更）→ Commit（並列）→ Push（並列／完了待ち）** を実施し、
- そのコミットで更新された **gitlink を親のコミットに含める**（＝`git add <submodule-path>`）

#### 管轄サブモジュールの定義
- 親の `.gitmodules` に記録された **`submodule.*.url` の URL に、自分の `USER_ID`（大文字小文字無視）が含まれる**もの。
- `USER_ID` は **親リポジトリ直下の `.env`** に記載します（例：`USER_ID=A1253419`）。

---

### 動作方針（重要）

1. **PortableGit 優先**（`%USERPROFILE%/Software/PortableGit/cmd/git.exe`）。無ければ `PATH` の `git`。
2. **親／子共通フック**
   - **子（サブモジュール内）**では、**`commit-submodules.sh` のみスキップ**。
     → それ以外のステップは **通常どおり続行**（例：PowerShell の既存処理）。
3. **Add+Commit（並列）**
   - コミットは **並列**で起動し、**すべてのコミット完了を待機**。
   - **1件でもコミット失敗**があれば、**親のコミットは中止**。
4. **gitlink 反映**
   - コミットに成功した **サブモジュールのパス**を親で `git add` して **gitlink をステージ**。
5. **Push（並列／完了待ち）**
   - `origin main` へ **並列で push**。
   - **完了を待機**するが、**失敗しても親コミットは継続**（エラーは必ず表示）。
6. **PowerShell 失敗時**
   - `Pre-Commit.ps1` が **不在／エラー終了**なら、**親コミットは中止**。

---

### コミット対象は「常に all」（設計意図）

- `git add -A` を採用し、**未追跡（追加）・更新・削除**を **漏れなくステージ**します。
  - `git add .` は **削除の検出が漏れる場合がある**ため不採用。
- コミット対象に含めたくない生成物などは、**各サブモジュールの `.gitignore`** で管理してください。

---

### ブランチ方針（main 固定）

- サブモジュール側は **`main` ブランチを前提**とします。
- **現行ブランチが `main` 以外**の場合：
  - **コミットは現行ブランチに対して実施**（安全のため自動切替しない）。
  - ただし **push は `origin main` 固定**のため、**期待通りに更新されない可能性**があります。
  - スクリプトは **警告を表示**します。必要なら設計変更（現行ブランチへ push）をご検討ください。

---

### Windows での実行（Git for Windows / MSYS2）

- **shebang が必須**：スクリプト先頭に `#!/usr/bin/env sh` を記述してください。
- **`chmod +x` は通常不要**：Git for Windows（MSYS2）は **shebang を解釈**してフックを起動します。
- **PowerShell 呼び出し**：`Pre-Commit.ps1` を **固定名**で実行します。`pwsh` が優先／無ければ `powershell`。

---

### エラー扱い（整合性重視）

- `Pre-Commit.ps1` が不在／失敗 → **親コミット中止**。
- サブモジュールの **Add+Commit** が1件でも失敗 → **親コミット中止**。
- **Push 失敗** → **親コミットは継続**（ただし **失敗数を明示表示**）。

---

### 導入手順

1. **ファイル配置**
   - `.git/hooks/pre-commit`（shebang 必須）
   - `scripts/commit-submodules.sh`
   - 親リポジトリ直下に `.env`（例：`USER_ID=A1253419`）
2. **PortableGit の配置確認**
   - 既定パス：`%USERPROFILE%/Software/PortableGit/cmd/git.exe`
   - 無ければ `PATH` に `git` があることを確認。
3. **初回動作確認**
   - 管轄サブモジュールで適当な変更（追加／更新／削除）を行う。
   - 親で `git commit` を実行。
   - ログに **並列コミット→gitlink ステージ→並列プッシュ** の順で出力されることを確認。
   - 親コミットに **gitlink の更新が含まれる**ことを確認（`git show` 等）。

### トラブルシューティング

- **`git.exe not found`**
  - PortableGit（`%USERPROFILE%/Software/PortableGit/cmd/git.exe`）の存在を確認。
  - 代替として `PATH` の `git` が参照可能か確認。
- **`Pre-Commit.ps1 not found` や PowerShell 実行失敗**
  - `.git/hooks/Pre-Commit.ps1` のパスと権限、内容を確認。
  - `pwsh` / `powershell` のどちらかが動くか確認（`pwsh` 優先）。
- **`.gitmodules` が存在しない**
  - 管轄抽出ができないため、何もしないで終了（ログに出ます）。
- **`No managed submodules found`**
  - `.env` の `USER_ID` と `.gitmodules` の `submodule.*.url` に `USER_ID` が含まれているか（大小無視）確認。
- **`One or more submodule commits failed`**
  - 子リポジトリ側の競合、未解決の衝突、コミット拒否（pre-commit/pre-push）などを点検。
  - `.gitignore` の誤りで不要物がステージされていないかも確認。
- **Push が失敗する**
  - ネットワーク／共有フォルダの競合、認証、ブランチ不一致（`current_branch != main`）を確認。
  - 現設計は `origin main` 固定。必要なら要件に応じて現行ブランチへ push する設計変更を検討。

---

### よくある注意点（運用）

- **ブランチが `main` 以外**でコミットされる場合、`push origin main` は期待通りに更新されないことがあります。
  - 現設計は **警告のみ**で現行ブランチにコミットし、**push は `origin main` 固定**です。
  - 必要に応じて **現行ブランチへ push**への切替案を検討可能です。
- **Windows の実行属性**
  - Git for Windows（MSYS2）は **shebang を解釈**してフックを起動します。通常は **`chmod +x` 不要**。
  - **先頭行の `#!/usr/bin/env sh` は必須**です。
- **コミット対象は常に all**
  - `git add -A` により、**追加・更新・削除**をすべてステージします。
  - 不要なファイルは `.gitignore` で除外管理してください。
