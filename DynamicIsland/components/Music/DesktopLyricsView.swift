/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import SwiftUI

struct DesktopLyricsView: View {
    @ObservedObject private var musicManager = MusicManager.shared

    private var activeIndex: Int {
        max(0, musicManager.currentLyricIndex)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if musicManager.syncedLyrics.isEmpty {
                    statusView
                } else {
                    karaokeRows
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .frame(width: 760, height: 196)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("桌面歌词")

            Button {
                DesktopLyricsWindowManager.shared.setEnabled(false)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(.black.opacity(0.72), in: Circle())
                    .overlay {
                        Circle()
                            .stroke(.white.opacity(0.85), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .help("关闭桌面歌词")
            .accessibilityLabel("关闭桌面歌词")
            .padding(8)
        }
        .frame(width: 760, height: 196)
        .background(Color.black.opacity(0.001))
        .contentShape(Rectangle())
    }

    private var karaokeRows: some View {
        let nextIndex = activeIndex + 1
        let topIndex = activeIndex.isMultiple(of: 2) ? activeIndex : nextIndex
        let bottomIndex = activeIndex.isMultiple(of: 2) ? nextIndex : activeIndex

        return VStack(spacing: 8) {
            lyricGroup(
                at: topIndex,
                isActive: topIndex == activeIndex,
                horizontalAlignment: .leading,
                frameAlignment: .leading,
                textAlignment: .leading
            )
            lyricGroup(
                at: bottomIndex,
                isActive: bottomIndex == activeIndex,
                horizontalAlignment: .trailing,
                frameAlignment: .trailing,
                textAlignment: .trailing
            )
        }
    }

    private var statusView: some View {
        let status = musicManager.currentLyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        return Text(status.isEmpty ? "正在加载歌词..." : status)
            .font(.system(size: 26, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.9), radius: 3, x: 0, y: 1)
    }

    @ViewBuilder
    private func lyricGroup(
        at index: Int,
        isActive: Bool,
        horizontalAlignment: HorizontalAlignment,
        frameAlignment: Alignment,
        textAlignment: TextAlignment
    ) -> some View {
        if musicManager.syncedLyrics.indices.contains(index) {
            let line = musicManager.syncedLyrics[index]
            let lyricColor = isActive
                ? Color(red: 1.0, green: 215.0 / 255.0, blue: 0.0)
                : Color.white

            VStack(alignment: horizontalAlignment, spacing: 2) {
                if let tokens = line.pronunciationTokens, !tokens.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        pronunciationTokenRow(
                            tokens,
                            isActive: isActive,
                            color: lyricColor
                        )
                        fallbackLyric(
                            line,
                            isActive: isActive,
                            color: lyricColor,
                            alignment: horizontalAlignment,
                            textAlignment: textAlignment
                        )
                    }
                } else {
                    fallbackLyric(
                        line,
                        isActive: isActive,
                        color: lyricColor,
                        alignment: horizontalAlignment,
                        textAlignment: textAlignment
                    )
                }

                if let translation = line.translation {
                    Text(translation)
                        .font(.system(
                            size: isActive ? 15 : 13,
                            weight: .semibold,
                            design: .rounded
                        ))
                        .modifier(KTVTextStyle(color: lyricColor))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.62)
            .multilineTextAlignment(textAlignment)
            .frame(
                maxWidth: .infinity,
                minHeight: 78,
                maxHeight: 78,
                alignment: frameAlignment
            )
        } else {
            Color.clear.frame(height: 78)
        }
    }

    private func pronunciationTokenRow(
        _ tokens: [LyricToken],
        isActive: Bool,
        color: Color
    ) -> some View {
        HStack(alignment: .top, spacing: isActive ? 12 : 10) {
            ForEach(tokens) { token in
                VStack(spacing: 0) {
                    Text(token.text)
                        .font(.system(
                            size: isActive ? 32 : 26,
                            weight: isActive ? .bold : .semibold,
                            design: .rounded
                        ))
                        .modifier(KTVTextStyle(color: color))

                    if let pronunciation = token.pronunciation {
                        Text(pronunciation)
                            .font(.system(
                                size: isActive ? 17 : 15,
                                weight: .semibold,
                                design: .rounded
                            ))
                            .modifier(KTVTextStyle(color: color))
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func fallbackLyric(
        _ line: LyricLine,
        isActive: Bool,
        color: Color,
        alignment: HorizontalAlignment,
        textAlignment: TextAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(line.text)
                .font(.system(
                    size: isActive ? 32 : 26,
                    weight: isActive ? .bold : .semibold,
                    design: .rounded
                ))
                .modifier(KTVTextStyle(color: color))

            if let pronunciation = fallbackPronunciation(for: line) {
                Text(pronunciation)
                    .font(.system(
                        size: isActive ? 17 : 15,
                        weight: .semibold,
                        design: .rounded
                    ))
                    .modifier(KTVTextStyle(color: color))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.62)
        .multilineTextAlignment(textAlignment)
    }

    private func fallbackPronunciation(for line: LyricLine) -> String? {
        if let romanization = line.romanization?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !romanization.isEmpty {
            return romanization
        }

        let generated = line.pronunciationTokens?
            .compactMap(\.pronunciation)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return generated.isEmpty ? nil : generated
    }
}

private struct KTVTextStyle: ViewModifier {
    let color: Color

    func body(content: Content) -> some View {
        ZStack {
            content.foregroundStyle(.black).offset(x: -1, y: -1)
            content.foregroundStyle(.black).offset(y: -1)
            content.foregroundStyle(.black).offset(x: 1, y: -1)
            content.foregroundStyle(.black).offset(x: -1)
            content.foregroundStyle(.black).offset(x: 1)
            content.foregroundStyle(.black).offset(x: -1, y: 1)
            content.foregroundStyle(.black).offset(y: 1)
            content.foregroundStyle(.black).offset(x: 1, y: 1)
            content.foregroundStyle(color)
        }
        .shadow(color: .black.opacity(0.85), radius: 1, x: 0, y: 2)
    }
}
