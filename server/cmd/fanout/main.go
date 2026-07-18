// fanout は警報時に対象地域のユーザーへ APNs high priority push を送出する。
// 平時は負荷ゼロ、警報時に瞬間バースト。NFR-01: 受信 → APNs 送出 p99 < 1 秒。ADR-0001 参照。
//
// TODO:
//   - APNs HTTP/2 クライアント (alert push, high priority。silent push は間引かれるため使わない)
//   - デバイストークン管理と地域メッシュによるインデックス (Stage 2 で対象地域のみ送出)
//   - subscriber からの Pub/Sub 起動トリガー受信 (Stage 1 は全件直接送出、トークンは Firestore)
package main

import "fmt"

func main() {
	fmt.Println("tendenko fanout: not implemented yet")
}
