# 各页在不同尺寸下的离屏渲染 · 方法记录（2026-09-26）

用途：给 `../proposal.md` §1.6 的「哪些元素难看」提供实物证据，不截屏、不看屏、不启动 nanoPod.app、不碰 Music.app。

## 怎么做的

1. `git worktree add --detach <scratchpad>/resize-render main`，在 worktree 里临时加一个 XCTest（源码留档在 `render-harness.swift.txt`，不进仓库、不编译）。
2. 真实的 `MiniPlayerView` 通过 `PanelWindowMetrics.makeContentView` 挂进一个放在屏幕外（原点 −30000）的 `NSWindow` 子类（覆写 `constrainFrameRect` 原样返回，AppKit 不会把它拉回屏幕），深色外观。`MusicController.shared` 在 XCTest 下走 preview 数据；封面用代码画的渐变图；歌词用 DEBUG 自带的 `translated-word` fixture（把控制器的曲目身份设成 fixture 的，`LyricsView.onAppear` 的抓取被同曲稳定门拦下，不走网络）。
3. 宽度 180 / 200 / 250 / 320 / 375 / 400，高度按 284/250 比例；每个尺寸抓 专辑页（普通封面、全屏封面）、歌词页（有/无翻译）、歌单页。`cacheDisplay` 抓整个 hosting view（比窗口高 32pt），拼图时裁掉顶部透明的 32pt 安全区带。
4. 跑法：`lockf <scratchpad>/swift-serial.lock env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter TempResizeRenderTests`，串行锁，只跑这一类。
5. 用完 `git worktree remove --force` 删掉 worktree。

## 已知盲区

- 专辑页 hover 态（控件出现后的封面缩小、标题位置）在离屏 `cacheDisplay` 里抓不到英雄封面和标题文字（只抓到控件条），所以 hover 态的数字全部来自代码算术，不来自渲染图；`render-album-hover-first.webp` 只用于看 180 / 200 宽时底部控件条被裁的事实。
- 渲染图是深色外观、渐变假封面，只看布局与密度，不看材质。

## 产出

- `render-album-rest.webp`、`render-albumfull-rest.webp`、`render-lyrics.webp`、`render-playlist.webp`、`render-album-hover-first.webp`：六个宽度并排，1pt = 1px 的一半（原图 2x 缩到 1x 再存 webp）。
