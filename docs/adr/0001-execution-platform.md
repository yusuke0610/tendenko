# ADR-0001: 検知・配信サーバーの実行基盤に Cloud Run を採用する

- ステータス: Accepted
- 日付: 2026-07-18
- プロジェクト: tendenko

## コンテキスト

tendenko のサーバーサイドは以下のワークロードを持つ。

1. **WS 購読 (subscriber)**: DMDATA.jp の WebSocket を常時購読し、EEW・津波電文を受信・解析する。**常時接続・常時稼働が必須**で、切断は検知遅延に直結する。
2. **プッシュファンアウト (fanout)**: 警報時に対象地域のユーザーへ APNs high priority push を送出する。**平時は負荷ゼロ、警報時に瞬間的なバースト**が発生する。NFR-01: 受信 → APNs 送出 p99 < 1 秒。
3. **データパイプライン**: OSM/DEM/浸水域から地域パッケージを生成するバッチ。日次〜週次で十分。

制約: 個人開発であり、運用に割ける時間は限られる。OS パッチ・ミドルウェア管理は避けたい。開発者の既存スキルは GCP + OpenTofu。

## 決定

**3 ワークロードすべてを Cloud Run 系で運用する。**

| ワークロード | 形態 | 設定 |
|---|---|---|
| subscriber | Cloud Run service | min-instances=1, CPU always allocated, 単一リージョン (MVP) |
| fanout | Cloud Run service | min-instances=0, 警報時にオートスケール。subscriber から Pub/Sub 経由で起動 |
| pipeline | Cloud Run jobs | スケジュール実行 (Cloud Scheduler) |

subscriber と fanout は MVP ではひとつのサービスに同居させてよいが、**コード上は最初から分離**し、スケール時にデプロイ単位を分割できるようにする。

## 検討した代替案

### GCE VM (e2-micro / e2-small)

- ✅ 常時稼働ワークロードとして月額最安。WebSocket との相性に何の工夫も要らない
- ❌ OS パッチ・再起動運用・監視構築がすべて自前。個人開発で最も枯渇しているのは運用時間
- ❌ デプロイ・ロールバックの仕組みを自作する必要がある
- 判定: コストで勝るが運用負担で棄却。ただし**コスト最適化が必要になった時点で subscriber のみ VM に戻す選択肢は残す** (コードは実行基盤非依存に保つ)

### GKE Autopilot

- ✅ 常時稼働 + バーストの混在に最も柔軟
- ❌ クラスタ管理の学習・運用コストが個人開発の規模に対して過剰
- 判定: Stage 3 (下記) までは不要

### Fly.io / Railway 等

- ✅ WebSocket 常時接続アプリのデプロイ体験が良い
- ❌ 既存の GCP/OpenTofu 資産・スキルから外れる。APNs 送出や GCS 配信と分断される
- 判定: 棄却

## Cloud Run 採用にあたっての注意点 (正直な弱点)

- **スケール to ゼロの恩恵は subscriber では放棄する**。min-instances=1 + CPU always allocated の課金は小型 VM と同等かやや高い。Cloud Run を選ぶ理由はコストではなく運用レスとデプロイ体験である
- Cloud Run のインスタンスは予告なく入れ替わりうる。WS 切断 → 自動再接続 → 電文の取りこぼし検知 (シーケンス番号確認) をアプリケーション層で必ず実装する
- ヘルスチェックは「プロセス生存」ではなく「WS 接続が生きていて直近 N 分以内に keepalive を受信している」ことを確認する

## スケール時の構成 (段階計画)

### Stage 1: MVP (〜数百ユーザー)

```
[DMDATA WS] → [subscriber+fanout 同居 / 単一リージョン (asia-northeast1)]
                → [APNs] (デバイストークンは Firestore、全件直接送出)
```

- フォールバック: 気象庁 XML ポーリング (Cloud Scheduler + Cloud Run jobs、60 秒間隔)
- この規模ではファンアウトも 1 インスタンスで 1 秒以内に完了する

### Stage 2: マルチリージョン化 (〜数万ユーザー / 信頼性要件の格上げ)

```
[DMDATA WS] ⇒ subscriber × 2 リージョン (asia-northeast1 / asia-northeast2) 両系 active
                │  電文 ID で重複排除 (Firestore トランザクション or Redis SETNX)
                ▼
            [Pub/Sub topic: alerts]
                ▼
            fanout (min=0, max=N) — 地域別トークンをシャーディングして並列送出
```

- 両系 active-active により単一リージョン障害でも検知が止まらない (NFR-06)
- fanout は Pub/Sub 起動でリージョン非依存。APNs 接続プールを維持するため min-instances=1 に引き上げを検討
- デバイストークンを地域メッシュでインデックスし、対象地域のみに送出 (全国一斉送出をやめる)

### Stage 3: 大規模 (数十万ユーザー〜)

- fanout を Cloud Run から GKE または専用ワーカー群へ。APNs は HTTP/2 多重化の接続数管理がボトルネックになるため、接続プール常駐型が有利
- トークンシャーディングを Pub/Sub の ordering key ベースで分散し、送出 p99 を維持
- DMDATA 契約の上位プラン化 + 冗長購読 (複数 API キー)
- この段階に到達したら本 ADR を supersede する

## 帰結

- 運用時間を開発に回せる。デプロイは `tofu apply` + イメージ push に収まる
- subscriber のコストは月 $15〜25 程度発生し続ける (VM 比で割高を受容)
- コードは実行基盤非依存 (プレーンな Go バイナリ) に保ち、Stage 移行や VM 回帰の自由度を確保する
- WS 再接続・重複排除・シーケンス検証はアプリケーション層の必須実装として Stage 1 から組み込む