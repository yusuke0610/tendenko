// subscriber は DMDATA.jp の WebSocket を常時購読し、EEW・津波電文を受信・解析する。
// 常時稼働 (Cloud Run min-instances=1)。ADR-0001 参照。
//
// TODO:
//   - DMDATA.jp WebSocket 接続と自動再接続、シーケンス番号確認による取りこぼし検知 (Stage 1 から必須)
//   - ヘルスチェック: WS 接続が生きていて直近 N 分以内に keepalive を受信していること
//   - 電文解析: VXSE43/45 (EEW) → ウォームアップ通知、VTSE41 (津波警報等) → 案内起動、VTSE51 → 到達予想更新
//   - Pub/Sub 経由で fanout を起動
//   - フォールバック: 気象庁防災情報 XML の ATOM ポーリング (DMDATA 障害時の縮退)
//   - 実行基盤非依存に保つ (VM へ戻す選択肢を残す)
package main

import "fmt"

func main() {
	fmt.Println("tendenko subscriber: not implemented yet")
}
