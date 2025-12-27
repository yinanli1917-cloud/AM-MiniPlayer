//
//  TranslationService.swift
//  MusicMiniPlayer
//
//  Created by Claude Code
//

import Foundation
import Translation
import NaturalLanguage

@available(macOS 15.0, *)
class TranslationService {
    /// 执行翻译任务
    /// - Parameters:
    ///   - session: 由 SwiftUI translationTask 提供的翻译会话
    ///   - lyrics: 需要翻译的歌词文本数组
    /// - Returns: 翻译后的文本数组
    static func translationTask(_ session: TranslationSession, lyrics: [String]) async -> [String]? {
        guard !lyrics.isEmpty else { return nil }

        logToFile("🌐 [Translation] Starting translation for \(lyrics.count) lines")

        do {
            let requests = lyrics.map { TranslationSession.Request(sourceText: $0) }
            let responses = try await session.translations(from: requests)
            let translatedTexts = responses.map { $0.targetText }

            logToFile("✅ [Translation] Successfully translated \(translatedTexts.count) lines")
            return translatedTexts

        } catch {
            logToFile("❌ [Translation] Failed: \(error.localizedDescription)")

            // 如果翻译失败，尝试检测真实语言用于配置更新
            if let realLanguage = detectLanguage(for: lyrics) {
                logToFile("🔄 [Translation] Detected real language: \(realLanguage.languageCode?.identifier ?? "unknown")")
                // 返回 nil 表示需要更新配置（调用者应检测并更新 translationSessionConfig）
            }
            return nil
        }
    }

    /// 写入调试日志文件
    private static func logToFile(_ message: String) {
        let logPath = "/tmp/nanopod_lyrics_debug.log"
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let handle = FileHandle(forWritingAtPath: logPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: logPath, contents: data)
            }
        }
    }

    /// 检测文本的主要语言
    /// - Parameter texts: 文本数组
    /// - Returns: 检测到的语言，如果无法检测返回 nil
    static func detectLanguage(for texts: [String]) -> Locale.Language? {
        var langCount: [Locale.Language: Int] = [:]
        let recognizer = NLLanguageRecognizer()

        for text in texts {
            recognizer.reset()
            recognizer.processString(text)

            if let dominantLanguage = recognizer.dominantLanguage {
                let language = Locale.Language(identifier: dominantLanguage.rawValue)
                // 跳过系统语言（通常是目标语言）
                if language != Locale.Language.systemLanguages.first {
                    langCount[language, default: 0] += 1
                }
            }
        }

        // 返回出现次数最多且至少出现 3 次的语言
        if let mostCommon = langCount.sorted(by: { $1.value < $0.value }).first,
           mostCommon.value >= 3 {
            return mostCommon.key
        }

        return nil
    }
}
