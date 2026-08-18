# コントリビュート・PR運用ルール

- **作業は `main` から作業ブランチ (feature branch) を切って行う**。`main` に直接コミットしない。ブランチ名はコミットメッセージの prefix に合わせる (`feat/...`・`fix/...`・`docs/...`・`chore/...` 等)。作業完了後は PR 経由で `main` にマージする
- コミットメッセージは [Conventional Commits](https://www.conventionalcommits.org/ja/) (`feat:`, `fix:`, `docs:`, `chore:` 等)
- **`git push` は毎回ユーザーの明示的な承認を得てから行う**。過去に承認されていても次回に持ち越さない (コミットはローカルなので承認不要)
- アーキテクチャ・データフォーマット・依存関係・ライセンスなどの決定はすべて `docs/adr/` に ADR として記録する (`make docs-adr` で連番作成)。第三者がデューデリジェンスできる品質を維持し、背景・選択肢・トレードオフを省略しない

## PR作成後の運用 (CI・CodeRabbit)

- **CodeRabbit の設定の正本はリポジトリ直下の `.coderabbit.yaml`**。レビュー言語 (`language: ja-JP`)・パスごとのレビュー方針 (`path_instructions`)・有効にする静的解析ツールをここで管理する。`.claude/rules/` や CLAUDE.md のルールを変えたら `.coderabbit.yaml` の `path_instructions` も合わせて更新する
- PR を作成・更新したら、CI (`gh pr checks`) と CodeRabbit のレビューコメントの両方を確認する
- **CI の失敗・CodeRabbit の指摘が 1 件でも残っている間は監視を続ける。**「確認 → 指摘の妥当性を判断 → 必要なら修正してコミット → push → 再レビュー依頼 → 再確認」を繰り返し、両方ともグリーン (CI 成功・指摘は解消または理由を添えて却下済み) になるまでループする。1 回の push・1 回の確認で放置しない
- **ループは最大 3 周まで**。3 周しても指摘が解消しない場合は、そこで自動での修正を止めてユーザーに状況 (残っている指摘・試した修正・解消しない理由) を報告し、判断を仰ぐ。同じ箇所を延々と直し続けない
  - CodeRabbit の再レビューは自動では走らないことがある。push 後に `gh pr comment <PR> --body "@coderabbitai review"` で明示的に依頼する
  - **結果は 3 経路すべてから取る。どれか 1 つでも欠けると指摘を取りこぼす**
    | 取得先 | 何が入るか |
    |---|---|
    | `gh pr view <PR> --json reviews` | レビュー本文 (`Actionable comments posted: N` の件数はここ) |
    | `gh api repos/<owner>/<repo>/pulls/<PR>/comments` | inline のコード指摘 |
    | `gh api repos/<owner>/<repo>/issues/<PR>/comments` | walkthrough・要約・`@coderabbitai` への返信 (timeline コメント。上 2 つには出ない) |
  - **bot のログイン名は経路によって違う** (reviews は `coderabbitai`、issue/inline コメントは `coderabbitai[bot]`)。`select(.user.login == "coderabbitai")` で絞ると取りこぼすので `startswith("coderabbitai")` を使う
  - **inline コメントは解決後も API に残る**ため、件数を数えるだけでは未解決数にならない。未解決の判定は GraphQL の `reviewThreads` の `isResolved` / `isOutdated` を見る:
    ```
    gh api graphql -f query='{repository(owner:"<owner>",name:"<repo>"){pullRequest(number:<PR>){
      reviewThreads(first:50){nodes{isResolved isOutdated path comments(first:1){nodes{body}}}}}}}'
    ```
  - レビュー本文の `Actionable comments posted: N` と、自分が集めた未解決件数が一致するかを毎回突き合わせる。合わなければ取得経路かフィルタを疑う
  - 1 周ごとに「今何周目か」「残っている指摘は何件か」をユーザーに報告する
- CodeRabbit の指摘は鵜呑みにせず内容の妥当性を判断する。的外れな指摘は修正せず、PR コメントで理由を添えて却下してよい。**却下も「解消」として扱う**が、却下したことと理由は必ずユーザーに報告する
- push 自体は上のルール (git push は毎回ユーザーの明示的な承認を得る) に従う。このループも push 前の確認を省略しない

人間のコントリビューター向けの同等の内容 (push 承認など AI アシスタント固有のルールを除く) は [CONTRIBUTING.md](../../CONTRIBUTING.md) にある。
