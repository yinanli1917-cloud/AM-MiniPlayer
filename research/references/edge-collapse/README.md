# 贴边收起动效参考库（2026-09-19 ~ 09-20 创始人提供）

原始文件在创始人 Downloads / Movies，这里是改名后的副本，供复用。逐帧结论以各 `*-analysis.md` 为准（全帧率抽帧，不抽样）。

| 文件 | 来源 | 看什么 | 核心结论 |
|---|---|---|---|
| ref1-black-pill-to-glass-card-bottom-edge.mp4 | 第三方，底边黑胶囊 ↔ 米色玻璃卡片 | 材质切换与几何同步；收起时先塌高再收窄成杆、杆落到胶囊留颈；展开先鼓圆再拉长 | 展开 ~170ms，收起 ~200ms，内容晚 100–200ms 出现；黑胶囊是纯色无边缘光 |
| ref2-apple-music-nowplaying-to-miniplayer-hero-flight.mov | Apple Music 正在播放页收回迷你条（120fps） | 容器先走、封面晚 ~130ms 单飞、大过冲、最后落定 | 总 ~340ms；只留封面/标题/播放/快进 |
| ref3-glass-capsule-to-sphere-material.mp4 | 玻璃胶囊变球 | 材质：regular 玻璃，边缘高光先于几何，冷暖色散；宽度单调收 73% 无过冲 317ms；出现淡入、消失收缩+虚化+淡出 | 待机高光缓慢绕行 ~1.75s |
| ref4-liquid-goo-merge.mov | iOS 26 照片 app 工具栏 Select（60fps） | 官方 glass 融合真实样子：按压发亮 → Select 胶囊向左长成宽条与菜单键拉颈融合 → 文字变糊过渡 → 右端挤出圆形 X 断开 | 全程 ~400ms；内容用模糊过渡不硬切；两块静止时留极小间隙 |
| Siri 截图（对话里，未存文件） | iOS 26 Type to Siri 面板 | 贴岛端纯黑、向屏内渐透的玻璃 | 黑是 tint 进材质 + 整层 dimming 渐变，不是盖一层 |
| proto-v2-rejected-2026-09-20-1831.mp4 | 我们样品第二版（创始人否决） | 玻璃壳与内容分离、封面残影、长条和按钮融成一团 | 反面教材 |
| proto-v3-rejected-2026-09-20-1844.mp4 | 我们样品第三版（创始人否决） | 整卡当照片缩放、灰泥材质、控制块残留 | 反面教材 |

设计稿：`research/edge-collapse-redesign-2026-09-19.md`。样品：`research/spikes/edge-collapse-spike/`。
