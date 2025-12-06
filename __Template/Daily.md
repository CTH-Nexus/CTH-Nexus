---
title: "<タイトルを設定してください>"
date: { { date:YYYY-MM-DD } }
tags:
  - daily
aliases: ["{{date:YYYY年MM月DD日}}"]
---

# {{date:YYYY年MM月DD日}} ({{date:dddd}})

## ✅ 今日の目標

- [ ] 主要タスク 1
- [ ] 主要タスク 2

## 📝 メモ

- 今日の気づきやアイデアを書く

## 📅 スケジュール

- 午前：
- 午後：

## 🔗 関連リンク

-

## ✅ 振り返り

- 良かったこと：
- 改善点：

<%\*

const filename = tp.file.title;   // ex. 2025-10-28
    const [year, month, day] = filename.split("-"); // => [2025, 10, 28]
    const newPath = `Member/{USER_ID}/Daily/${year}/${month}/${day}`;
    // すでに同じパスにファイルが存在するか確認する
    if (await app.vault.adapter.exists(newPath)) {
        // 既存のファイルがある場合は、新規ファイルの作成を中止
        const newFile = app.workspace.getActiveFile();
        await app.vault.trash(newFile, true);
        new Notice(`既存ファイルがあるため、新規作成分を削除しました: ${newPath}`);
    } else {
        // 既存のファイルが存在しないので、通常通り作成する
    await tp.file.move(newPath);
    }
%>
