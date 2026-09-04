/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import AppKit
import Combine
import Defaults
import SwiftUI

@MainActor
final class DesktopLyricsWindowManager: NSObject, NSWindowDelegate {
    static let shared = DesktopLyricsWindowManager()

    private enum PositionKey {
        static let x = "desktopLyricsPositionX"
        static let y = "desktopLyricsPositionY"
    }

    private let musicManager = MusicManager.shared
    private var window: NSPanel?
    private var cancellables = Set<AnyCancellable>()

    private override init() {
        super.init()

        synchronizeLyricsEngine(with: Defaults[.enableDesktopLyrics])

        Defaults.publisher(.enableDesktopLyrics)
            .receive(on: RunLoop.main)
            .sink { [weak self] change in
                self?.synchronizeLyricsEngine(with: change.newValue)
                self?.updatePresentation()
            }
            .store(in: &cancellables)

        Defaults.publisher(.enableLyrics)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updatePresentation() }
            .store(in: &cancellables)

        Publishers.CombineLatest3(
            musicManager.$currentLyrics,
            musicManager.$songTitle,
            musicManager.$artistName
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _, _, _ in self?.updatePresentation() }
        .store(in: &cancellables)

        updatePresentation()
    }

    func setEnabled(_ isEnabled: Bool) {
        Defaults[.enableDesktopLyrics] = isEnabled
        synchronizeLyricsEngine(with: isEnabled)
        updatePresentation()
    }

    func toggle() {
        setEnabled(!Defaults[.enableDesktopLyrics])
    }

    func windowDidMove(_ notification: Notification) {
        guard let window else { return }
        UserDefaults.standard.set(window.frame.origin.x, forKey: PositionKey.x)
        UserDefaults.standard.set(window.frame.origin.y, forKey: PositionKey.y)
    }

    private func updatePresentation() {
        guard Defaults[.enableLyrics],
              Defaults[.enableDesktopLyrics],
              musicManager.hasActiveSession
        else {
            hide()
            return
        }

        let window = ensureWindow()
        if !window.isVisible {
            restoreOrSetDefaultPosition(for: window)
            window.orderFrontRegardless()
        }
    }

    private func synchronizeLyricsEngine(with isEnabled: Bool) {
        guard Defaults[.enableLyrics] != isEnabled else { return }
        Defaults[.enableLyrics] = isEnabled
    }

    private func ensureWindow() -> NSPanel {
        if let window { return window }

        let size = NSSize(width: 760, height: 196)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: DesktopLyricsView())
        panel.setContentSize(size)

        ScreenCaptureVisibilityManager.shared.register(panel, scope: .panelsOnly)
        window = panel
        return panel
    }

    private func restoreOrSetDefaultPosition(for window: NSWindow) {
        let defaults = UserDefaults.standard
        let savedX = defaults.object(forKey: PositionKey.x) as? Double
        let savedY = defaults.object(forKey: PositionKey.y) as? Double

        if let savedX, let savedY {
            let savedFrame = NSRect(
                x: savedX,
                y: savedY,
                width: window.frame.width,
                height: window.frame.height
            )
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(savedFrame) }) {
                window.setFrameOrigin(savedFrame.origin)
                return
            }
        }

        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.midX - window.frame.width / 2,
            y: visibleFrame.minY + max(72, visibleFrame.height * 0.12)
        )
        window.setFrameOrigin(origin)
    }

    private func hide() {
        window?.orderOut(nil)
    }
}
