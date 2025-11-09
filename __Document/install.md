---
tags:
  - architecture
  - Directory
title: __Document\architecture.md
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
git remote add origin R:\Knewrova.git
git push origin main
```

## サブモジュールの作成・登録

clone できただけでは使えない
`Member/{USER_ID}/` および `Shared/User/{USER_ID}/` に各人の Vault を削り出すリポジトリを確保する必要がある

ID リストを用意し、それをもとに「共有フォルダ上のベアリポジトリ群」および「それを登録した結果得られる `.gitmodules`」を自動作成できるスクリプトを用意したので利用されたい。

## 個人用リポジトリの配布

これも上記とはまた別に、各人が利用する `UsersVault/{USER_ID}/` というリポジトリを用意する必要がある
ほとんど親リポジトリである `Knewrova` と同じだが、`git sparse-checkout` することで、自分に関係ある範囲のみを選べる

```powershell
git clone --no-checkout R:\Knewrova.git "${USER_ID}"
cd ${USER_ID}
git sparse-checkout init --cone

git sparse-checkout set `
.gitignore `
.gitattributes `
.gitmodules `
LICENSE `
.script/ `
Member/{USER_ID} `
Shared/Project/{USER_ID} `
Shared/User/{USER_ID} `
__Attachment/ `
__Document/ `
__Template/

git checkout main

git remote rename origin upstream
git remote set-url --push upstream "R:\UsersVault\${USER_ID}.git"
git remote add origin "R:\UsersVault\${USER_ID}.git"
git branch main --set-upstream-to=origin/main
git remote -v

# origin  R:\UsersVault\${USER_ID}.git (fetch)
# origin  R:\UsersVault\${USER_ID}.git (push)
# upstream        R:\Knewrova.git (fetch)
# upstream        R:\UsersVault\${USER_ID}.git (push)
```
