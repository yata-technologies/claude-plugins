# <PROJECT-KEY> ワークログ設定

このプロジェクトのワークログ記録で使う `category_id` / `phase_id` / `activity_id`
のリストと使い分けガイド、およびステータス遷移で使う具体的なツール名。
`coyote_list_categories` / `coyote_list_phases` / `coyote_list_activities`
（バックエンドが Coyote MCP の場合）で取得して埋める。（コミット対象 — チーム共有）

## ステータス遷移（作業開始・終了）

Tracker は作業単位を必ず2つのステータス遷移で挟む。**このプロジェクトのバックエンドで
実際に呼ぶツール名**を下表に書く。共通スキルはこの遷移を抽象的にしか書かないため、
「どのツールを呼ぶか」を知っているのはこの表だけ。`.claude/coyote-tracker.config` の
`task_update_tool` / `issue_update_tool` / `status_*` と必ず一致させること。

| タイミング | 対象 | 呼ぶツール | 設定するステータス |
|---|---|---|---|
| 作業開始の瞬間（最初の読み書きより前） | タスク | `<TASK_UPDATE_TOOL>` | `<STATUS_IN_PROGRESS>` |
| 人間がイシューを指名して作業開始 | イシュー | `<ISSUE_UPDATE_TOOL>` | `<STATUS_IN_PROGRESS>` |
| ワークログがスコープを締める瞬間 | タスク＋親イシュー | `<TASK_UPDATE_TOOL>` / `<ISSUE_UPDATE_TOOL>` | `<STATUS_CLOSED>` |

- 開始側の遷移は**タスクを作成／特定した同じターン**で行う。コードを読む前、方針を書く前。
- 終了側の遷移は**ワークログを提案する同じ応答**で束ねて提案する（2回に分けない）。

## カテゴリ (category_id)

| id | 名称 | 用途 |
|----|------|------|
| … | … | … |

## フェーズ (phase_id)

| id | 名称 | 用途 |
|----|------|------|
| … | … | … |

## アクティビティ (activity_id)

| id | 名称 | 用途 |
|----|------|------|
| … | … | … |

## 使い分けメモ

- …
