#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# verify_playlist_move_reflects_upnext.sh
#
# 目的：真机、非破坏性验证 —— 对「当前正在播放的库内用户歌单」执行
# `move track` 是否立即反映到 Music.app 的 Up Next（通过 `current playlist`
# 的曲目顺序、以及 `next track` 后实际播放的歌曲来观察）。
#
# 这是 T1（2026-08-21）未验证项：改当前播放歌单是否即时反映到 Up Next。
#
# 本脚本只做只读探测 + 在一个专用 scratch 歌单里操作，绝不触碰用户真实歌单。
# 本脚本设计为由创始人在自己选择的时间窗口手动运行 —— 它不会被 Claude
# 自动执行，Claude 也不会对 Music.app 跑任何 osascript。
#
# 用法：
#   ./verify_playlist_move_reflects_upnext.sh            仅打印计划，不做任何改动
#   ./verify_playlist_move_reflects_upnext.sh --go        实际执行测试（会暂停你当前播放）
#   ./verify_playlist_move_reflects_upnext.sh --cleanup   只删除 scratch 歌单（若残留）
# ============================================================================

SCRATCH_PLAYLIST_NAME="nanoPod-move-test"
MODE="dry-run"

for arg in "$@"; do
  case "$arg" in
    --go) MODE="go" ;;
    --cleanup) MODE="cleanup" ;;
    -h|--help)
      echo "Usage: $0 [--go|--cleanup]"
      exit 0
      ;;
    *)
      echo "未知参数: $arg" >&2
      exit 1
      ;;
  esac
done

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S.%3N' 2>/dev/null || date '+%H:%M:%S')" "$*"
}

require_music_running() {
  log "检查 Music.app 是否正在运行..."
  local running
  running=$(osascript -e 'tell application "System Events" to (name of processes) contains "Music"')
  if [[ "$running" != "true" ]]; then
    echo "错误：Music.app 未运行。请先启动 Music.app 并开始播放一个用户歌单，再重跑本脚本。" >&2
    exit 1
  fi
  log "Music.app 正在运行。"
}

cleanup_scratch_playlist() {
  log "尝试删除 scratch 歌单 \"${SCRATCH_PLAYLIST_NAME}\"（若存在）..."
  osascript <<EOF
tell application "Music"
  if (exists user playlist "${SCRATCH_PLAYLIST_NAME}") then
    delete user playlist "${SCRATCH_PLAYLIST_NAME}"
    return "deleted"
  else
    return "not-found"
  end if
end tell
EOF
}

if [[ "$MODE" == "cleanup" ]]; then
  require_music_running
  result=$(cleanup_scratch_playlist)
  log "清理结果：${result}"
  exit 0
fi

require_music_running

log "读取当前播放歌单信息（current playlist / current track）..."
CURRENT_INFO=$(osascript <<'EOF'
tell application "Music"
  if not (exists current playlist) then
    return "NO_CURRENT_PLAYLIST"
  end if
  set p to current playlist
  set pName to name of p
  set pClass to (class of p) as text
  set pSpecial to "unknown"
  try
    set pSpecial to (special kind of p) as text
  end try
  return pName & "||" & pClass & "||" & pSpecial
end tell
EOF
)

if [[ "$CURRENT_INFO" == "NO_CURRENT_PLAYLIST" ]]; then
  echo "错误：Music.app 当前没有 current playlist（没有在播放，或播放源不可判定）。请先开始播放一个库内用户歌单。" >&2
  exit 1
fi

IFS='||' read -r CUR_NAME CUR_CLASS CUR_SPECIAL <<< "$CURRENT_INFO" || true
# 上面的 IFS 分割在包含 "||" 的分隔符时不完全可靠（bash IFS 是字符集不是子串），
# 用更稳妥的方式重新解析：
CUR_NAME=$(printf '%s' "$CURRENT_INFO" | awk -F'\\|\\|' '{print $1}')
CUR_CLASS=$(printf '%s' "$CURRENT_INFO" | awk -F'\\|\\|' '{print $2}')
CUR_SPECIAL=$(printf '%s' "$CURRENT_INFO" | awk -F'\\|\\|' '{print $3}')

log "current playlist 名称: ${CUR_NAME}"
log "current playlist 类: ${CUR_CLASS}"
log "current playlist special kind: ${CUR_SPECIAL}"

# 只支持「库内用户歌单」：class 必须是 "user playlist"，special kind 必须是 "none"。
# 电台 / Apple Music 专辑页 / 智能歌单 一律不支持。
if [[ "$CUR_CLASS" != "user playlist" ]]; then
  echo "错误：当前播放的不是库内用户歌单（class=${CUR_CLASS}）。不支持电台 / Apple Music 专辑 / 其他类型。请切换到一个普通用户歌单后重跑。" >&2
  exit 1
fi

if [[ "$CUR_SPECIAL" != "none" ]]; then
  echo "错误：当前播放歌单的 special kind 不是 none（值=${CUR_SPECIAL}），可能是智能歌单等特殊歌单。不支持，请切换到一个普通（非智能）用户歌单后重跑。" >&2
  exit 1
fi

if [[ "$CUR_NAME" == "$SCRATCH_PLAYLIST_NAME" ]]; then
  echo "错误：当前播放的正是 scratch 测试歌单本身（${SCRATCH_PLAYLIST_NAME}）。请切换到你真实的用户歌单后重跑，或先跑 --cleanup 清理残留。" >&2
  exit 1
fi

log "当前播放歌单校验通过：普通库内用户歌单，可以继续。"

if [[ "$MODE" == "dry-run" ]]; then
  cat <<PLAN

===== 计划（dry-run，未执行任何改动）=====
1. 在当前播放歌单 "${CUR_NAME}" 的前 4 首曲目上各 duplicate 一份，
   放进新建的 scratch 用户歌单 "${SCRATCH_PLAYLIST_NAME}"。
2. 从 scratch 歌单的第 1 首开始播放（这会暂停你现在的播放，
   并让 Music.app 的 current playlist 切到 scratch 歌单）。
3. 打印 scratch 歌单当前曲目顺序（含时间戳）。
4. 执行 move track 4 to before track 2（在 scratch 歌单内部）。
5. 立即再次打印曲目顺序（含时间戳），用于对比 move 前后差异。
6. 执行 next track，打印现在实际播放的是哪首曲目 ——
   如果 Up Next 立即跟随 move 后的新顺序，这里应该播放被移动的那首歌。
7. 删除 scratch 歌单，不留痕迹。

⚠️ 警告：第 2 步会打断你当前的播放。
如果确认要实际执行，请加 --go 参数重跑：
    $0 --go

===========================================
PLAN
  exit 0
fi

# ---- MODE == go：实际执行 ----

log "警告：即将暂停你当前的播放并切到 scratch 歌单测试。"

log "步骤1：读取当前播放歌单前 4 首曲目的 persistent ID..."
TRACK_IDS=$(osascript <<EOF
tell application "Music"
  set p to playlist "${CUR_NAME}"
  set idList to {}
  set n to (count of tracks of p)
  if n > 4 then set n to 4
  repeat with i from 1 to n
    set t to track i of p
    set end of idList to (persistent ID of t)
  end repeat
  set AppleScript's text item delimiters to ","
  set outText to idList as text
  set AppleScript's text item delimiters to ""
  return outText
end tell
EOF
)
log "取得曲目 persistent ID 列表：${TRACK_IDS}"

TRACK_COUNT=$(awk -F',' '{print NF}' <<< "$TRACK_IDS")
if [[ "$TRACK_COUNT" -lt 4 ]]; then
  echo "错误：当前播放歌单曲目数不足 4 首（只有 ${TRACK_COUNT} 首），无法完成 move track 4 to before track 2 的测试。" >&2
  exit 1
fi

log "步骤2：创建 scratch 歌单 \"${SCRATCH_PLAYLIST_NAME}\" 并 duplicate 前 4 首曲目进去..."
osascript <<EOF
tell application "Music"
  if (exists user playlist "${SCRATCH_PLAYLIST_NAME}") then
    delete user playlist "${SCRATCH_PLAYLIST_NAME}"
  end if
  set sp to make new user playlist with properties {name:"${SCRATCH_PLAYLIST_NAME}"}
  set src to playlist "${CUR_NAME}"
  set n to (count of tracks of src)
  if n > 4 then set n to 4
  repeat with i from 1 to n
    set t to track i of src
    duplicate t to sp
  end repeat
end tell
EOF
log "scratch 歌单创建完成，已 duplicate ${TRACK_COUNT} 首曲目。"

log "步骤3：暂停你当前播放，改为从 scratch 歌单第 1 首开始播放..."
osascript <<EOF
tell application "Music"
  play (track 1 of user playlist "${SCRATCH_PLAYLIST_NAME}")
end tell
EOF
log "已开始播放 scratch 歌单。"

print_order() {
  local label="$1"
  local ts
  ts=$(date '+%s.%N' 2>/dev/null || date '+%s')
  log "[${label}] 时间戳: ${ts}"
  osascript <<EOF
tell application "Music"
  set p to user playlist "${SCRATCH_PLAYLIST_NAME}"
  set outLines to {}
  repeat with i from 1 to (count of tracks of p)
    set t to track i of p
    set end of outLines to (i as text) & ". " & (name of t) & " [" & (persistent ID of t) & "]"
  end repeat
  set AppleScript's text item delimiters to linefeed
  set outText to outLines as text
  set AppleScript's text item delimiters to ""
  return outText
end tell
EOF
}

log "步骤4：打印 move 之前的曲目顺序。"
print_order "move 之前"

log "步骤5：执行 move track 4 to before track 2..."
MOVE_TS_BEFORE=$(date '+%s.%N' 2>/dev/null || date '+%s')
osascript <<EOF
tell application "Music"
  set p to user playlist "${SCRATCH_PLAYLIST_NAME}"
  move (track 4 of p) to before (track 2 of p)
end tell
EOF
MOVE_TS_AFTER=$(date '+%s.%N' 2>/dev/null || date '+%s')
log "move 命令执行完毕。发出前时间戳=${MOVE_TS_BEFORE} 返回后时间戳=${MOVE_TS_AFTER}"

log "步骤6：立即打印 move 之后的曲目顺序。"
print_order "move 之后（应可与上面对比顺序变化）"

log "步骤7：执行 next track，观察 Up Next 是否已跟随新顺序..."
NEXT_TS_BEFORE=$(date '+%s.%N' 2>/dev/null || date '+%s')
osascript <<EOF
tell application "Music"
  next track
end tell
EOF
sleep 0.3
CURRENT_AFTER_NEXT=$(osascript <<EOF
tell application "Music"
  if (exists current track) then
    set t to current track
    return (name of t) & " [" & (persistent ID of t) & "]"
  else
    return "NO_CURRENT_TRACK"
  end if
end tell
EOF
)
NEXT_TS_AFTER=$(date '+%s.%N' 2>/dev/null || date '+%s')
log "next track 前时间戳=${NEXT_TS_BEFORE} 后时间戳=${NEXT_TS_AFTER}"
log "next track 之后实际播放的曲目：${CURRENT_AFTER_NEXT}"
log "对照：若 Up Next 立即跟随 move 后顺序，这里应该是被移动到 position 2 的那首曲目。"

log "步骤8：清理 —— 删除 scratch 歌单..."
osascript <<EOF
tell application "Music"
  if (exists user playlist "${SCRATCH_PLAYLIST_NAME}") then
    delete user playlist "${SCRATCH_PLAYLIST_NAME}"
  end if
end tell
EOF
log "scratch 歌单已删除。测试结束。"

cat <<SUMMARY

===== 结果解读提示 =====
对比上面「move 之前」和「move 之后」两次曲目顺序打印，
确认 track 4 是否已经出现在 track 2 之前的位置（顺序本身应立即反映，因为
current playlist 直接读取的就是该歌单的当前内容）。

真正待验证的问题是：next track 之后实际播放的曲目，是不是「被移动后」
排在第 2 位的那首曲目 —— 如果是，说明 Up Next 立即跟随了 move；
如果播放的仍是 move 之前顺序下的下一首，说明 Up Next 有滞后或使用了
播放时刻的快照，不会因后续 move 立即改变。
=========================
SUMMARY
