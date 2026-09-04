/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import SwiftUI
import Defaults

struct MinimalisticMusicView: View {
    @EnvironmentObject var vm: DynamicIslandViewModel
    @ObservedObject var musicManager = MusicManager.shared
    @State private var isHovering: Bool = false
    
    var body: some View {
        VStack(spacing: 2) {
            // Main content row
            HStack(spacing: 0) {
                // Left: Album Art
                albumArtView

                // Middle: Song title and artist
                Rectangle()
                    .fill(.black)
                    .overlay(
                        GeometryReader { geo in
                            VStack(alignment: .center, spacing: 2) {
                                if !musicManager.songTitle.isEmpty {
                                    MusicTitleMarqueeView(
                                        text: musicManager.songTitle,
                                        isExplicit: musicManager.isCurrentTrackExplicit,
                                        font: .system(size: 12, weight: .semibold),
                                        nsFont: .subheadline,
                                        textColor: Defaults[.coloredSpectrogram] ? Color(nsColor: musicManager.avgColor) : Color.gray,
                                        minDuration: 0.4,
                                        frameWidth: max(0, geo.size.width - 8),
                                        alignment: .center,
                                        badgeHeight: 13
                                    )
                                }

                                // Artist name
                                if !musicManager.artistName.isEmpty {
                                    Text(musicManager.artistName)
                                        .font(.system(size: 10, weight: .regular))
                                        .foregroundColor(Defaults[.playerColorTinting] ? Color(nsColor: musicManager.avgColor).ensureMinimumBrightness(factor: 0.6) : .gray)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                }
                            }
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
                        }
                    )
                    .frame(width: vm.closedNotchSize.width)

                // Right: Music Visualizer
                visualizerView
            }
        }
        .frame(height: vm.effectiveClosedNotchHeight + (isHovering ? 8 : 0), alignment: .center)
        .onHover { hovering in
            isHovering = hovering
        }
    }
    
    // MARK: - Album Art
    
    private var albumArtView: some View {
        HStack {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .background(
                    Image(nsImage: musicManager.albumArt)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: musicManager.albumArt.size.width/musicManager.albumArt.size.height > 1.0 ? 4 : 12))

                )
                .clipped()
                .albumArtFlip(angle: musicManager.flipAngle)
                .frame(width: max(0, vm.effectiveClosedNotchHeight - 12), height: max(0, vm.effectiveClosedNotchHeight - 12))
        }
        .frame(width: max(0, vm.effectiveClosedNotchHeight - (isHovering ? 0 : 12)), height: max(0, vm.effectiveClosedNotchHeight - (isHovering ? 0 : 12)))
    }
    
    // MARK: - Visualizer
    
    private var visualizerView: some View {
        HStack {
            Rectangle()
                .fill(Defaults[.coloredSpectrogram] ? Color(nsColor: musicManager.avgColor).gradient : Color.gray.gradient)
                .frame(width: 50, alignment: .center)
                .mask {
                    AudioSpectrumView(isPlaying: $musicManager.isPlaying)
                        .frame(width: 16, height: 12)
                }
                .frame(width: max(0, vm.effectiveClosedNotchHeight - (isHovering ? 0 : 12)),
                       height: max(0, vm.effectiveClosedNotchHeight - (isHovering ? 0 : 12)), alignment: .center)
        }
        .frame(width: max(0, vm.effectiveClosedNotchHeight - (isHovering ? 0 : 12)),
               height: max(0, vm.effectiveClosedNotchHeight - (isHovering ? 0 : 12)), alignment: .center)
    }
}
