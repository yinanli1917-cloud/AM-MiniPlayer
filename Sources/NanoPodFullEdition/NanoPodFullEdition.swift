import Foundation
import MusicMiniPlayerCore

// =============================================================================
// PRIVATE-API NOTICE: 私有 API 代码只允许出现在 NanoPodFullEdition target。
// Core / AppKit / MusicMiniPlayerApp 源码树禁止出现 MediaRemote 字样
// （scripts/assert_pure_edition.sh 第②道门断言）。纯净版产品的依赖图里没有
// 这个 target，链接不到——这是隔离手段，不是编译条件。
// =============================================================================
//
// [INPUT]: PlaybackSourceID (Core, struct + RawRepresentable)
// [OUTPUT]: .systemNowPlaying id + edition marker — skeleton only, no adapter
//           code, no MediaRemote code, no downloaded vendor files.
// [POS]: WT-E E3 骨架第一步（docs/wt-e-full-edition-plan-2026-09-12.md M1）。
//        SystemNowPlayingSource / AdapterProcessRunner / StreamPayloadParser
//        留待后续里程碑；本文件不写任何私有 API 调用。
// =============================================================================

extension PlaybackSourceID {
    public static let systemNowPlaying = PlaybackSourceID(rawValue: "systemNowPlaying")
}

public enum NanoPodFullEdition {
    public static let editionName = "full"
}
