import Foundation

/// 同梱サンプル (釜石 584177) にフォールバックしている間の扱い (ADR-0004 追記)。
///
/// 判断だけを純粋関数として切り出す。`ContentView` (SwiftUI View) の中に埋めると
/// テストできず、「縮退時に無関係な避難経路を読み上げない」という一番落としたくない
/// 性質を回帰から守れないため。検証は `make app-test`。
enum SampleFallback {
    /// 現在地の地域パッケージを読めていないとき、同梱サンプルを表示してよいか。
    /// 開発中の動作確認のための機能なので、明示的に有効化されているときだけ許す。
    static func shouldPresentSample(regionPath: String?, enabled: Bool) -> Bool {
        regionPath == nil && enabled
    }

    /// 音声案内を読み上げてよいか。
    ///
    /// **サンプルの経路は現在地と無関係なので、地図に描いても読み上げてはいけない。**
    /// 地図は「これはサンプルだ」と一目で分かるうえ無視もできるが、音声は無関係な方向を
    /// 断定的に指示してしまい、避難時に取り消しが効かない。requirements.md §3.3 のとおり
    /// 本アプリは公式警報の後追いで避難準備を整える係であり、誤った方向を能動的に告げる
    /// のは位置づけを踏み越える。
    static func shouldAnnounce(regionPath: String?) -> Bool {
        regionPath != nil
    }

    /// 縮退バナーに出す文言。サンプル表示中はその事実と、音声を出さないことを添える。
    static func bannerMessage(statusMessage: String, regionPath: String?) -> String {
        guard regionPath == nil else { return statusMessage }
        return statusMessage + "（表示中の経路はサンプルです。音声案内は行いません）"
    }
}
