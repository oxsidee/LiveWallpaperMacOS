/*
 * This file is part of LiveWallpaper – LiveWallpaper App for macOS.
 * Copyright (C) 2025 Bios thusvill
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import SwiftUI
import AppKit
import ApplicationServices
import ServiceManagement

let sharedEngine = WallpaperEngine.shared()

@main
struct LiveWallpaperApp: App {
    
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
            Settings { EmptyView() }
    }
        
}


class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var window: NSWindow!

    let engine = sharedEngine
    let viewModel = WallpaperViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {

        NSApp.setActivationPolicy(.accessory)


        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "play.desktopcomputer", accessibilityDescription: "Live Wallpaper")
        }


        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "Manage wallpapers", action: #selector(showWindow), keyEquivalent: "m"))
        menu.addItem(NSMenuItem(title: "Next Wallpaper", action: #selector(nextWallpaper), keyEquivalent: "n"))
        menu.addItem(NSMenuItem.separator())
        
        let onlyLocalItem = NSMenuItem(title: "Only Local Videos", action: #selector(toggleOnlyLocal), keyEquivalent: "")
        onlyLocalItem.tag = 100
        menu.addItem(onlyLocalItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu

        // Create main window with ContentView
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView,.borderless],
            backing: .buffered,
            defer: false
        )
        //hide titlebar
        //window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.toolbarStyle = .unified
        
        window.center()
        window.contentView = NSHostingView(rootView: ContentView())
        window.title = "LiveWallpaper By Bios"
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        
        if !hasAccessibilityAccess() {
            requestAccessibilityAccess()
        }

        
        if !isLoginItemEnabled() {
            setLoginItem(enabled: true)
        }
        
        // Initialize slideshow if enabled
        _ = SlideshowManager.shared

        // On screen unlock: re-apply wallpapers and restart slideshow if enabled
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenUnlocked),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
    }

    @objc private func screenUnlocked() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            sharedEngine?.reapplyWallpapersToAllDisplays()
            SlideshowManager.shared.reloadSettingsAfterUnlock()
        }
    }

    // Show the config window
    @objc func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Hide the window without quitting the app
    @objc func hideWindow() {
        window.orderOut(nil)
    }

    // Switch to next wallpaper
    @objc func nextWallpaper() {
        SlideshowManager.shared.switchToNextWallpaper()
    }
    
    // Toggle only local videos
    @objc func toggleOnlyLocal() {
        SlideshowManager.shared.onlyLocalVideos.toggle()
    }

    // Quit the app completely
    @objc func quit() {

        engine?.terminateApplication()
        NSApp.terminate(nil)
    }
}

// MARK: - NSMenuDelegate
extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        if let item = menu.item(withTag: 100) {
            item.state = SlideshowManager.shared.onlyLocalVideos ? .on : .off
        }
    }
}

// MARK: Permission Access

func hasAccessibilityAccess() -> Bool {
    return AXIsProcessTrusted()
}


func requestAccessibilityAccess() {
    let options: [String: Any] = [
        kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
    ]
    AXIsProcessTrustedWithOptions(options as CFDictionary)
}




func isLoginItemEnabled() -> Bool {
    return UserDefaults.standard.bool(forKey: "LaunchAtLogin")
}


func setLoginItem(enabled: Bool) {
    guard let bundleId = Bundle.main.bundleIdentifier else { return }
    
    if SMLoginItemSetEnabled(bundleId as CFString, enabled) {
        UserDefaults.standard.set(enabled, forKey: "LaunchAtLogin")
    } else {
        print("❌ Failed to update login items")
    }
}
