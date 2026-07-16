# Swift 一本化移行計画

## 目的

macOS 専用の `vde-notifier` を Swift の単一コードベースへ統合し、Node.js、Bun、pnpm、npm パッケージ、および JavaScript 依存を製品と開発環境から撤去する。

通知を受け付ける CLI と通知クリックを処理する常駐エージェントは、同一の Swift Package と同一の配布アプリに収める。プロセス境界は通知クリックを非同期に処理するため維持するが、言語・ビルド・リリース経路は一本化する。

## 非目標

- Node 版 CLI と Swift 版 CLI の長期併存
- npm 版利用者向けの互換ラッパーや自動フォールバック
- macOS 以外への対応
- Developer ID 署名・公証の導入
- CLI の仕様変更や新機能追加

移行リリースでは Node 版を廃止する。必要な互換性は、既存の CLI 引数、終了コード、Codex/Claude ペイロード解釈、通知クリック時の focus 動作という利用者向け契約に限定する。

## 現状と問題

現在は TypeScript CLI が入力解析、Codex/Claude 連携、tmux 制御、ターミナル制御を担当し、Swift アプリが macOS 通知と通知クリック後のアクション実行を担当する。

この構成には次の運用コストがある。

- macOS 専用製品でありながら Node.js または Bun の実行環境が必要
- npm と GitHub Release/Cask の二系統でバージョンと公開処理を管理
- TypeScript と Swift の二つの依存管理、テスト、CI が必要
- Node CLI が自分自身を再起動する focus ペイロードに、パッケージランナー固有の実行パスが含まれる
- デフォルト通知経路が Swift アプリなので、Node 版だけでは製品の主要機能が完結しない

## 目標構成

```text
VdeNotifierApp.app
├── Contents/MacOS/vde-notifier-app  # アプリ管理・agent・低水準 notify
└── Contents/MacOS/vde-notifier      # 同一実装の利用者向け CLI
    ├── notify（既定）
    ├── focus
    ├── Codex/Claude ペイロード解析
    ├── tmux コンテキスト取得・復帰
    └── ターミナルのアクティベーション
```

二つの実行ファイル名は同じ Swift ソースから生成する。`vde-notifier` は通知内容と focus アクションを組み立て、同じアプリ内の agent client を直接利用する。通知アクションとして保存する実行対象は `vde-notifier --mode focus --payload ...` とし、シェル補間は使わない。

## 互換対象

| 契約 | 移行方針 |
| --- | --- |
| `--title` / `--message` / `--sound` | 維持 |
| `--codex` / Codex payload 優先順位 | 維持 |
| Codex title generation 自動除外 | 維持 |
| Codex subagent / non-interactive 除外 | 維持 |
| `--claude` / transcript JSONL 読み込み | 維持 |
| Claude non-interactive 除外 | 維持 |
| `--terminal` / `--term-bundle-id` | 維持 |
| `--dry-run` / `--verbose` / `--log-file` | 維持 |
| `-- <command> [args...]` | 維持 |
| `--mode focus --payload` | 維持 |
| `--notifier` | 廃止。Swift agent を唯一の通知実装とする |
| terminal-notifier / swiftDialog | 廃止。フォールバックは設けない |
| npm / npx / bunx / pnpm dlx | 廃止。Homebrew Cask に一本化 |

## 実装段階

### 1. Swift CLI の純粋ロジック

- CLI 引数モデルと厳格なパーサーを追加する
- JSON 値の抽出、sound 正規化、focus payload の Codable モデルを追加する
- terminal profile、tmux 応答解析、診断ログを副作用から分離する
- TypeScript の境界値テストを Swift の XCTest へ移植する

### 2. エージェント入力の移植

- Codex payload の入力優先順位とセッション rollout 判定を移植する
- Claude payload、transcript JSONL、親プロセスによる print mode 判定を移植する
- ファイル読み込み量、thread id、transcript path を検証し、不正入力で失敗させる

### 3. 通知と focus の統合

- tmux バイナリ探索、コンテキスト取得、対象の再検証と focus を移植する
- terminal activation を移植する
- Swift agent client を CLI から直接呼び、通知アクションを登録する
- dry-run、診断ログ、後続コマンド実行を移植する

### 4. 配布・運用の切り替え

- app bundle に `vde-notifier` と `vde-notifier-app` を収録する
- Cask から両コマンドをインストールする
- CI を macOS/Swift の検証だけに統合する
- npm publish workflow、`package.json`、lockfile、TypeScript ソースと設定を削除する
- README とリリース手順を Homebrew/App release の単一路線に更新する

### 5. 最終検証

- strict concurrency と warnings-as-errors を含む全 XCTest を実行する
- universal app を生成して署名、plist、二つの CLI、arm64/x86_64 slice を検証する
- tmux を使った notify dry-run と focus の統合テストを実行する
- Node/npm/Bun/pnpm への実行時・CI・文書参照が残っていないことを検索で確認する
- 全差分をセルフレビューし、重大・高優先度の指摘がゼロになるまで修正と再検証を繰り返す

## リスクと対策

| リスク | 対策 |
| --- | --- |
| 動的 JSON の解釈差 | 既存 TypeScript テストの代表値と境界値を XCTest に移植する |
| Process 実行時の deadlock / exit code 欠落 | stdout/stderr の取得を共通化し、成功・失敗・大容量出力をテストする |
| focus payload の不正値で任意コマンド実行 | Codable 復号後に絶対パス、tmux identifier、terminal bundle id を検証する |
| App bundle 内の CLI 自己参照が壊れる | 実行中バイナリの絶対パスを action executable に保存し、bundle smoke test で確認する |
| Codex/Claude セッションファイルの肥大化 | 読み込み上限を設け、必要な先頭または末尾だけを読む |
| 二重実装が残って乖離する | 移行完了コミットで Node/npm 資産を削除し、併存期間を設けない |

## ロールバック方針

移行前 HEAD をバックアップブランチに保存する。移行後に重大な回帰が見つかった場合は、新しい修正コミットまたはバックアップブランチからの revert commit で戻す。作業ツリーを破壊する `reset --hard` や一括 restore は使わない。

## Definition of Done

### 機能完了条件

- [x] `vde-notifier` の既存 CLI 契約のうち互換対象に列挙した全項目が Swift で動作する
- [x] 通知送信と通知クリック後の tmux pane 復帰が Node.js、Bun、npm パッケージなしで完結する
- [x] app bundle と Homebrew Cask が `vde-notifier` と `vde-notifier-app` の両方を提供する
- [x] terminal-notifier、swiftDialog、Node CLI のフォールバック経路が残っていない

### テスト完了条件

- [x] `swift test` が成功する
- [x] strict concurrency と warnings-as-errors を有効にした `swift test` が成功する
- [x] CLI、Codex、Claude、tmux、focus payload、terminal profile、後続コマンドの正常系・異常系テストが成功する
- [x] universal app bundle の plist、署名、arm64/x86_64、help、version、doctor smoke test が成功する
- [x] セルフレビューで重大・高優先度の未解決指摘がゼロである

### 運用反映条件

- [x] Node/npm 用のソース、設定、lockfile、publish workflow がリポジトリから削除されている
- [x] CI と release workflow が Swift 単一構成を検証する
- [x] README が Homebrew によるインストールと単一 release flow だけを案内する
- [x] Homebrew tap が同一 app bundle から二つの CLI をインストールする
- [x] 各移行段階が意図別のコミットとして記録されている

## 計画セルフレビュー

- 責務境界: 言語は一本化するが、通知クリックに必要な agent のプロセス境界を誤って除去していない
- 互換性: 利用者向け CLI 契約と廃止対象を明示し、暗黙のフォールバックを計画していない
- セキュリティ: JSON、ファイルパス、focus action、外部コマンドを信頼境界として扱っている
- 検証可能性: 機能、テスト、運用の各完了条件をコマンドまたはリポジトリ状態で測定できる
- 配布整合性: Cask、app asset、二つの実行名、release tag を同じバージョンに統合している
- ロールバック: Git 履歴を破壊せずに戻せる

セルフレビュー上の未解決事項はない。実装中に既存契約の解釈差が見つかった場合は、TypeScript テストの期待値を正とし、Swift テストを先に追加してから実装する。

## 完了時の検証記録

- XCTest: 71 tests、失敗 0
- コンパイラ条件: `-strict-concurrency=complete`、`-warnings-as-errors`
- app bundle: plist、ad-hoc code signature、`arm64` / `x86_64`、二つの実行ファイルを検証
- GitHub CI: run `29472697279` 成功
- GitHub Release: `app-v0.2.0`、`VdeNotifierApp.app.tar.gz` 公開成功
- Release workflow: run `29472749388` 成功
- Homebrew Cask: version `0.2.0`、二つの binary artifact を確認
- Homebrew audit: ローカルおよび run `29472835505` 成功
- 実インストール: `brew reinstall --cask yuki-yano/vde-notifier/vde-notifier-app` で 0.2.0 を導入

Developer ID で署名・公証していないアプリが `/Applications` 配下で Gatekeeper に拒否される既知の制約は、本移行とは独立した運用制約として残る。quarantine 除去後も対象 macOS では `spctl` が拒否することを確認した。これはユーザー了承のうえで本計画の非目標として扱い、Swift CLI 自体は同じ配布バイナリを `/Applications` 外で起動して確認した。
