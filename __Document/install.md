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
