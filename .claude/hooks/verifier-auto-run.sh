#!/bin/bash
# 匹配逻辑文件改动后自动跑 LyricsVerifier 回归测试
FILE="$CLAUDE_TOOL_INPUT_FILE_PATH"
if echo "$FILE" | grep -qE '(LyricsFetcher|MetadataResolver|MatchingUtils|LanguageUtils|LyricsScorer)\.swift$'; then
    cd /Users/yinanli/Documents/MusicMiniPlayer
    echo '--- Verifier auto-run ---'
    swift run LyricsVerifier run 2>&1 | grep -E 'PASS|FAIL|passed|warnings|===' | head -20
fi
