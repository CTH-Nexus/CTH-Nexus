---
tags:
  - architecture
  - Directory
title: __Document/architecture.md
---

# 📦 What's in Here?

## How to install

First, you need to create a _bare repository_ on the shared folder.

```powershell
# net use R: \\path\\to\\your\\shared\\folder
git init --bare --shared R:\Knewrova.git
```

The following commands should be executed after **cloning** this repository to your local machine (or **local repository**).

> [!NOTE]
> Naturally, cloning will not be possible in an air-gapped environment,
> so separate transport via USB or similar media may be required.

```powershell
git init
git add .
git commit -m "Initial Commit !!"
git remote add origin R:\Knewrova.git
git push origin main
```

## サブモジュールの作成・登録

clone できただけでは使えない

`Member/{USER_ID}/` および `Shared/User/{USER_ID}/` に各人の Vault を削り出すリポジトリを確保する必要がある

ID リストを用意し、それをもとに「共有フォルダ上のベアリポジトリ群」および「それを登録した結果得られる `.gitmodules`」を自動作成できるスクリプトを用意したので利用されたい
ただし、共有フォルダ上にサブモジュールのリポジトリを保持するディレクトリとして `R:\Submodule\Member` および `R:\Submodule\Shared\User` (必要なら `R:\Submodule\Shared\Project`)を、事前に手作業で作成しておく必要がある

### `Generate-Gitmodules.ps1`

IDリストからサブディレクトリ `Member/` および `Shared/User/` を選択することで、その配下に配置されるサブモジュール群を共有フォルダ上に作成する

本来は `git submodule add` の結果生成されるファイルだが、IDの人数分コマンドを直列実行するのは時間がもったいない

### `Create-BareRepos.ps1`

IDリストから共有フォルダ上のディレクトリを選択することで、その配下にベアリポジトリ群を作成する

対象ディレクトリが `Member` であった場合のみ、直下に `Daily` と `Misc` が作成される

### `Setup-UserSparseCheckout.ps1`

ここで再度、共有フォルダ上に `R:\UsersVault` を作成する必要がある

これは、組織リポジトリを sparse-checkout してきたもので、組織リポジトリとの違いは「`Member` 以下のサブモジュール群をチェックアウトしない」ことである

自分の分だけ sparse-checkout すれば、他メンバーの個人メモを同期することなく、`Shared` 以下だけを参照できる

また、upstream こそ 組織リポジトリとして設定されるが、そこに Push できないようになっているため、好きなように自分好みにカスタマイズできる

Vault内部のファイルパス形式については、絶対パスで固定のこと

### `Fix-Submodules.ps1`

本来であれば、clone したあとにサブモジュール追従をやるには `git submodule update --init recursive` とすればよいはずが、なぜか動かない

そのため workaround として、`.gitmodule` を正しいものと仮定して `--force` をつけて再度強制実行する

こうすることで、`.git` 内部の GitLink なる領域が活性化(?)して、サブモジュールとして認識した上に実体ファイルが降ってくるようになる

---

まぁ、個人リポジトリを clone する際に `--recurse-submodule` を忘れなければいいだけの話なのだが
