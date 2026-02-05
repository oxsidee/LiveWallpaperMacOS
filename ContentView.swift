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
import AVFoundation
import UniformTypeIdentifiers
import Combine
import AppKit



// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var viewModel = WallpaperViewModel()
    @State private var showSettings = false
    @StateObject private var displayManager = DisplayManager()
    
    
    @Environment(\.dismiss) private var dismiss
        static var didCloseOnLaunch = false


    @State private var selectedTab = 0
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            
            // Top toolbar
            ToolbarView(
                showSettings: $showSettings,
                onReload: { viewModel.reloadContent() }
            )
            .padding(.horizontal)
            .padding(.top, 24)
            .padding(.bottom, 12)

            // Tabs
            TabView(selection: $selectedTab) {
                // Wallpapers tab (combined downloaded + aerial)
                ZStack(alignment: .bottom) {
                    VideoGridView(
                        videos: viewModel.videos,
                        viewModel: viewModel,
                        onVideoSelect: { video in
                            viewModel.startWallpaper(video: video, displays: Array(displayManager.selectedDisplays))
                        }
                    )
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)

                    DisplayDockView(
                        displays: displayManager.displays,
                        selectedDisplays: $displayManager.selectedDisplays
                    )
                    .padding(.bottom, 20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tabItem {
                    Label("Wallpapers", systemImage: "photo.on.rectangle")
                }
                .tag(0)
                
                // Slideshow tab
                SlideshowTabView(viewModel: viewModel)
                    .tabItem {
                        Label("Slideshow", systemImage: "play.rectangle.on.rectangle")
                    }
                    .tag(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.all)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .frame(minWidth: 600, minHeight: 250)
        
        .sheet(isPresented: $showSettings) {
            SettingsView(viewModel: viewModel)
        }
        .onAppear {
            viewModel.loadDisplays()
            viewModel.reloadContent()
            
            if (!Self.didCloseOnLaunch && !(sharedEngine?.isFirstLaunch())!) {
                                Self.didCloseOnLaunch = true
                                dismiss()
                            }
            
            
        }
        
    }
}


// MARK: - Toolbar View
struct ToolbarView: View {
    @Binding var showSettings: Bool
    let onReload: () -> Void
    
    var body: some View {
        HStack {
            Spacer()
            
            Button(action: onReload) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16))
            }
            .buttonStyle(.glass)
            
            Button(action: { showSettings = true }) {
                Image(systemName: "gear")
                    .font(.system(size: 16))
            }
            .buttonStyle(.glass)
        }
    }
}

// MARK: - Video Grid View
struct VideoGridView: View {
    let videos: [VideoItem]
    let viewModel: WallpaperViewModel
    let onVideoSelect: (VideoItem) -> Void
    
    @State private var selectedCategory: String = "All"
    @State private var selectedSource: String = "All"
    @StateObject private var downloadManager = AerialDownloadManager.shared
    @State private var showAerialVideos = false
    @State private var isSelectionMode = false
    @State private var selectedVideoIDs: Set<String> = []
    @State private var showBatchDeleteConfirmation = false
    
    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 12)]
    
    private let allCategories = ["All", "Nature", "Cities", "Underwater", "Planet Earth", "Uploaded"]
    
    var availableSources: [String] {
        var sources = Set(downloadManager.videos.map { $0.source })
        // Add sources from local videos
        sources.formUnion(videos.map { $0.source })
        sources.remove("Local") // Will be added separately
        return ["All", "Local"] + sources.sorted()
    }
    
    var localVideosWithCategories: [VideoItem] {
        videos  // source and category are already set in reloadContent
    }
    
    var allVideos: [VideoItem] {
        var result: [VideoItem] = []
        
        // For "Local" filter - show only local videos
        if selectedSource == "Local" {
            return localVideosWithCategories
        }
        
        // Build a map of local videos by aerialId for quick lookup
        var localByAerialId: [String: VideoItem] = [:]
        var localWithoutAerialId: [VideoItem] = []
        
        for video in localVideosWithCategories {
            if let aerialId = video.aerialId {
                localByAerialId[aerialId] = video
            } else {
                // Uploaded or unknown videos
                localWithoutAerialId.append(video)
            }
        }
        
        // When showing aerial videos - merge in order of API
        if showAerialVideos {
            let quality = UserDefaults.standard.string(forKey: "streaming_quality") ?? "1080p-H264"
            
            // Filter aerial videos by source
            let sourceFilteredAerials: [AerialVideo]
            if selectedSource == "All" {
                sourceFilteredAerials = downloadManager.videos
            } else {
                sourceFilteredAerials = downloadManager.videos.filter { $0.source == selectedSource }
            }
            
            // Iterate through aerial videos in API order
            for aerial in sourceFilteredAerials {
                // If downloaded, use local version; otherwise use streaming
                if let localVideo = localByAerialId[aerial.id] {
                    result.append(localVideo)
                } else if let url = aerial.getURL(forQuality: quality) {
                    // Create streaming VideoItem
                    let thumbURL = aerial.url1080pH264 ?? aerial.url1080pSDR ?? aerial.url4KSDR
                    var qualities: [String] = []
                    if aerial.url4KHDR != nil { qualities.append("4K-HDR") }
                    if aerial.url4KSDR != nil { qualities.append("4K-SDR") }
                    if aerial.url1080pHDR != nil { qualities.append("1080p-HDR") }
                    if aerial.url1080pSDR != nil { qualities.append("1080p-SDR") }
                    if aerial.url1080pH264 != nil { qualities.append("1080p-H264") }
                    
                    let streamingItem = VideoItem(
                        filename: aerial.name,
                        path: url,
                        thumbnailPath: "",
                        quality: quality,
                        category: aerial.category,
                        isRemote: true,
                        remoteURL: url,
                        thumbnailURL: thumbURL,
                        source: aerial.source,
                        aerialId: aerial.id,
                        availableQualities: qualities
                    )
                    result.append(streamingItem)
                }
            }
            
            // Add uploaded/unknown local videos at the end
            if selectedSource == "All" {
                result.append(contentsOf: localWithoutAerialId)
            } else {
                result.append(contentsOf: localWithoutAerialId.filter { $0.source == selectedSource })
            }
        } else {
            // Not showing aerial - just show local videos
            if selectedSource == "All" {
                result = localVideosWithCategories
            } else {
                result = localVideosWithCategories.filter { $0.source == selectedSource }
            }
        }
        
        return result
    }
    
    var filteredVideos: [VideoItem] {
        if selectedCategory == "All" {
            return allVideos
        }
        return allVideos.filter { $0.category == selectedCategory }
    }
    
    var groupedByCategory: [String: [VideoItem]] {
        Dictionary(grouping: filteredVideos) { $0.category }
    }
    
    var sortedCategories: [String] {
        let order = ["Nature", "Cities", "Underwater", "Planet Earth", "Uploaded"]
        return groupedByCategory.keys.sorted { a, b in
            let aIndex = order.firstIndex(of: a) ?? 999
            let bIndex = order.firstIndex(of: b) ?? 999
            return aIndex < bIndex
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Category filter bar
            HStack(spacing: 8) {
                ForEach(allCategories, id: \.self) { category in
                    Button(action: { selectedCategory = category }) {
                        Text(category)
                            .font(.system(size: 12, weight: selectedCategory == category ? .bold : .regular))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(selectedCategory == category ? Color.accentColor : Color.gray.opacity(0.2))
                            )
                            .foregroundColor(selectedCategory == category ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
                
                Spacer()
                
                // Selection mode toggle
                Button(action: {
                    isSelectionMode.toggle()
                    if !isSelectionMode {
                        selectedVideoIDs.removeAll()
                    }
                }) {
                    Image(systemName: isSelectionMode ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .foregroundColor(isSelectionMode ? .accentColor : .secondary)
                .help(isSelectionMode ? "Exit selection" : "Select multiple")
                
                // Upload video button
                Button(action: uploadVideo) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20))
                    Text("Add")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                
                Toggle("Show Aerial", isOn: $showAerialVideos)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: showAerialVideos) { newValue in
                        if newValue {
                            AerialVideoLoader.shared.loadIfNeeded()
                        }
                    }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            // Selection mode bar
            if isSelectionMode {
                HStack {
                    Text("\(selectedVideoIDs.count) selected")
                        .font(.system(size: 12, weight: .medium))
                    
                    Spacer()
                    
                    // Download selected (only for remote videos)
                    let selectedRemote = filteredVideos.filter { selectedVideoIDs.contains($0.id) && $0.isRemote }
                    if !selectedRemote.isEmpty {
                        Button(action: {
                            for video in selectedRemote {
                                if let aerialId = video.aerialId ?? video.id as String?,
                                   let aerial = downloadManager.videos.first(where: { $0.id == aerialId }) {
                                    downloadManager.downloadVideo(aerial, quality: video.quality ?? "1080p-H264", to: viewModel.folderPath)
                                }
                            }
                            selectedVideoIDs.removeAll()
                            isSelectionMode = false
                        }) {
                            Label("Download (\(selectedRemote.count))", systemImage: "arrow.down.circle")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.bordered)
                    }
                    
                    // Delete selected (only for local videos)
                    let selectedLocal = filteredVideos.filter { selectedVideoIDs.contains($0.id) && !$0.isRemote }
                    if !selectedLocal.isEmpty {
                        Button(action: {
                            showBatchDeleteConfirmation = true
                        }) {
                            Label("Delete (\(selectedLocal.count))", systemImage: "trash")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                    
                    Button("Cancel") {
                        selectedVideoIDs.removeAll()
                        isSelectionMode = false
                    }
                    .font(.system(size: 12))
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.1))
            }
            
            // Source filter (show when there are multiple sources in local or streaming videos)
            if availableSources.count > 2 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(availableSources, id: \.self) { source in
                            Button(action: { selectedSource = source }) {
                                Text(source)
                                    .font(.system(size: 11, weight: selectedSource == source ? .bold : .regular))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(selectedSource == source ? Color.blue : Color.gray.opacity(0.15))
                                    )
                                    .foregroundColor(selectedSource == source ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 6)
            }
            
            ScrollView {
                if videos.isEmpty && !showAerialVideos {
                    Button {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        panel.title = "Select Wallpaper Folder"
                        panel.prompt = "Choose"
                        
                        if panel.runModal() == .OK, let url = panel.url {
                            viewModel.folderPath = url.path
                            sharedEngine?.selctFolder(url.path())
                            viewModel.reloadContent()
                        }
                    } label: {
                        Text("Select a wallpaper folder")
                            .font(.system(size: 14, weight: .medium))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else if selectedCategory == "All" {
                    // Show grouped by category
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(sortedCategories, id: \.self) { category in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(category)
                                    .font(.headline)
                                    .padding(.horizontal)
                                
                                LazyVGrid(columns: columns, spacing: 12) {
                                    let categoryVideos = groupedByCategory[category] ?? []
                                    ForEach(Array(categoryVideos.enumerated()), id: \.element.id) { idx, video in
                                        videoCard(for: video, index: idx)
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                    .padding(.vertical)
                } else {
                    // Single category view
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(Array(filteredVideos.enumerated()), id: \.element.id) { idx, video in
                            videoCard(for: video, index: idx)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }
            }
        }
        .confirmationDialog("Delete \(selectedVideoIDs.count) videos?", isPresented: $showBatchDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                let selectedLocal = filteredVideos.filter { selectedVideoIDs.contains($0.id) && !$0.isRemote }
                for video in selectedLocal {
                    viewModel.deleteVideo(video)
                }
                selectedVideoIDs.removeAll()
                isSelectionMode = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will move the selected videos to Trash.")
        }
        .onAppear {
            // Scan for already downloaded videos
            downloadManager.scanDownloadedVideos(in: viewModel.folderPath)
            
            // Load aerial video sources if needed
            if downloadManager.sources.isEmpty {
                downloadManager.loadSources {
                    if downloadManager.videos.isEmpty {
                        downloadManager.loadVideos()
                    }
                }
            } else if downloadManager.videos.isEmpty {
                downloadManager.loadVideos()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("AerialVideoDownloaded"))) { _ in
            viewModel.reloadContent()
        }
    }
    
    private func uploadVideo() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.title = "Select Video Files"
        panel.prompt = "Add"
        
        if panel.runModal() == .OK {
            for url in panel.urls {
                let destURL = URL(fileURLWithPath: viewModel.folderPath).appendingPathComponent(url.lastPathComponent)
                
                do {
                    // Remove if exists
                    if FileManager.default.fileExists(atPath: destURL.path) {
                        try FileManager.default.removeItem(at: destURL)
                    }
                    // Copy to wallpaper folder
                    try FileManager.default.copyItem(at: url, to: destURL)
                    
                    // Create metadata JSON for uploaded file
                    let metadataURL = destURL.deletingPathExtension().appendingPathExtension("json")
                    let metadata: [String: Any] = [
                        "id": UUID().uuidString,
                        "name": url.deletingPathExtension().lastPathComponent,
                        "source": "Local",
                        "category": "Uploaded",
                        "quality": ""
                    ]
                    if let jsonData = try? JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted) {
                        try? jsonData.write(to: metadataURL)
                    }
                } catch {
                    NSLog("Failed to copy video: \(error.localizedDescription)")
                }
            }
            viewModel.reloadContent()
        }
    }
    
    @ViewBuilder
    private func videoCard(for video: VideoItem, index: Int) -> some View {
        let isSelected = selectedVideoIDs.contains(video.id)
        
        ZStack(alignment: .topLeading) {
            if video.isRemote {
                RemoteVideoThumbnailButton(video: video, action: {
                    if isSelectionMode {
                        toggleSelection(video.id)
                    } else {
                        onVideoSelect(video)
                    }
                }, folderPath: viewModel.folderPath, index: index)
            } else {
                VideoThumbnailButton(video: video, action: {
                    if isSelectionMode {
                        toggleSelection(video.id)
                    } else {
                        onVideoSelect(video)
                    }
                }, onDelete: {
                    viewModel.deleteVideo(video)
                })
            }
            
            // Selection checkbox overlay
            if isSelectionMode {
                Button(action: { toggleSelection(video.id) }) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 24))
                        .foregroundColor(isSelected ? .accentColor : .white)
                        .shadow(radius: 2)
                }
                .buttonStyle(.plain)
                .padding(8)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
        )
    }
    
    private func toggleSelection(_ id: String) {
        if selectedVideoIDs.contains(id) {
            selectedVideoIDs.remove(id)
        } else {
            selectedVideoIDs.insert(id)
        }
    }
}

// MARK: - Remote Video Thumbnail Button (for streaming)
struct RemoteVideoThumbnailButton: View {
    let video: VideoItem
    let action: () -> Void
    var folderPath: String = ""
    var index: Int = 0  // For priority-based thumbnail loading
    @StateObject private var thumbnailCache = AerialThumbnailCache.shared
    @StateObject private var downloadManager = AerialDownloadManager.shared
    @State private var thumbnail: NSImage?
    
    private var aerialVideo: AerialVideo {
        let q = video.quality ?? "1080p-H264"
        return AerialVideo(
            id: video.id,
            name: video.filename,
            category: video.category,
            source: video.source,
            timeOfDay: "",
            url4KSDR: q == "4K-SDR" ? video.remoteURL : nil,
            url4KHDR: q == "4K-HDR" ? video.remoteURL : nil,
            url1080pSDR: q == "1080p-SDR" ? video.remoteURL : nil,
            url1080pHDR: q == "1080p-HDR" ? video.remoteURL : nil,
            url1080pH264: q == "1080p-H264" ? video.remoteURL : video.thumbnailURL
        )
    }
    
    private var isDownloading: Bool {
        downloadManager.downloadingIDs.contains(video.id)
    }
    
    private var isWaiting: Bool {
        downloadManager.waitingIDs.contains(video.id)
    }
    
    private var downloadProgress: Double {
        downloadManager.downloadProgress[video.id] ?? 0
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: action) {
                ZStack(alignment: .bottomTrailing) {
                    if let thumbnail = thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(16/9, contentMode: .fill)
                            .frame(height: 120)
                            .clipped()
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(height: 120)
                            .overlay {
                                VStack(spacing: 4) {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                }
                            }
                    }
                    
                    // Stream badge
                    HStack(spacing: 4) {
                        Image(systemName: "wifi")
                            .font(.system(size: 10))
                        Text("Stream")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.blue.opacity(0.8))
                    )
                    .padding(6)
                }
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            
            // Name
            Text(video.filename)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
                .foregroundColor(.primary)
            
            // Available qualities
            if let qualities = video.availableQualities, !qualities.isEmpty {
                Text(qualities.joined(separator: " · "))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            // Download button
            HStack {
                Spacer()
                
                if isDownloading {
                    Button(action: { downloadManager.cancelDownload(video.id) }) {
                        ZStack {
                            Circle()
                                .stroke(Color.gray.opacity(0.3), lineWidth: 2.5)
                                .frame(width: 22, height: 22)
                            
                            Circle()
                                .trim(from: 0, to: downloadProgress)
                                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                .frame(width: 22, height: 22)
                                .rotationEffect(.degrees(-90))
                                .animation(.linear, value: downloadProgress)
                            
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.accentColor)
                        }
                    }
                    .buttonStyle(.plain)
                } else if isWaiting {
                    // Waiting in queue - spinning indicator
                    Button(action: { downloadManager.cancelDownload(video.id) }) {
                        ZStack {
                            Circle()
                                .stroke(Color.gray.opacity(0.3), lineWidth: 2.5)
                                .frame(width: 22, height: 22)
                            
                            ProgressView()
                                .scaleEffect(0.6)
                            
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Waiting in queue...")
                } else {
                    Button(action: {
                        // Use original AerialVideo from downloadManager to preserve correct source
                        if let originalVideo = downloadManager.videos.first(where: { $0.id == video.aerialId || $0.id == video.id }) {
                            downloadManager.downloadVideo(originalVideo, quality: video.quality ?? "1080p-H264", to: folderPath)
                        } else {
                            // Fallback to reconstructed video
                            downloadManager.downloadVideo(aerialVideo, quality: video.quality ?? "1080p-H264", to: folderPath)
                        }
                    }) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.gray.opacity(0.1))
        )
        .help("\(video.filename) (Stream)")
        .onAppear {
            loadThumbnail()
        }
        .onDisappear {
            // Cancel pending thumbnail request if not yet loaded
            if thumbnail == nil {
                thumbnailCache.cancelRequest(for: video.id)
            }
        }
    }
    
    private func loadThumbnail() {
        // Use thumbnailURL if available, otherwise fall back to remoteURL
        guard let thumbURL = video.thumbnailURL ?? video.remoteURL else { return }
        // Create a temporary AerialVideo to use the thumbnail cache
        let aerialVideo = AerialVideo(
            id: video.id,
            name: video.filename,
            category: video.category,
            source: "",
            timeOfDay: "",
            url1080pH264: thumbURL
        )
        thumbnailCache.getThumbnail(for: aerialVideo, quality: "1080p-H264", index: index) { image in
            thumbnail = image
        }
    }
}


// MARK: - Video Thumbnail Button
struct VideoThumbnailButton: View {
    let video: VideoItem
    let action: () -> Void
    var onDelete: (() -> Void)? = nil
    @ObservedObject private var cache = ThumbnailCache.shared
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: action) {
                ZStack(alignment: .bottomTrailing) {

                    let _ = cache.lastUpdate

                    if let thumbnail = video.loadThumbnail() {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(16/9, contentMode: .fill)
                            .frame(height: 120)
                            .clipped()
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(height: 120)
                            .overlay {
                                VStack(spacing: 4) {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                    Text("Generating...")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                    }

                    if let quality = video.quality, !quality.isEmpty {
                        QualityBadge(text: quality)
                            .padding(6)
                    }
                }
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            
            // Video name
            Text(video.filename)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
                .foregroundColor(.primary)
            
            // Action buttons row
            HStack(spacing: 8) {
                // Set as wallpaper
                Button(action: action) {
                    Image(systemName: "display")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .help("Set as Wallpaper")
                
                // Show in Finder
                Button(action: {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: video.path)])
                }) {
                    Image(systemName: "folder")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Show in Finder")
                
                Spacer()
                
                // Downloaded indicator
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.green)
                
                // Delete button
                Button(action: { showDeleteConfirmation = true }) {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .foregroundColor(.red.opacity(0.8))
                .help("Delete")
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.gray.opacity(0.1))
        )
        .help(video.filename)
        .confirmationDialog("Delete \"\(video.filename)\"?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                onDelete?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will move the video to Trash.")
        }
    }
}

// MARK: - Quality Badge
struct QualityBadge: View {
    let text: String
    
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.black, lineWidth: 1)
            )
    }
}
class DisplayManager: ObservableObject {
    @Published var displays: [DisplayObjc] = []
    @Published var selectedDisplays: Set<UInt32> = []

    init() {
        sharedEngine?.scanDisplays()
        updateDisplays()
        CGDisplayRegisterReconfigurationCallback(displayReconfigCallback, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        CGDisplayRemoveReconfigurationCallback(displayReconfigCallback, Unmanaged.passUnretained(self).toOpaque())
    }

    func updateDisplays() {
        
        sharedEngine?.scanDisplays()
        
        DispatchQueue.main.async { [weak self] in
                    self?.displays = sharedEngine?.getDisplays() as? [DisplayObjc] ?? []
                }
        
        
        
    }
}

private func displayReconfigCallback(
    _ display: CGDirectDisplayID,
    _ flags: UInt32,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo = userInfo else { return }
    let manager = Unmanaged<DisplayManager>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async {
        manager.updateDisplays()
        manager.selectedDisplays.removeAll()
        
    }
    
}


// MARK: - Display Dock View
struct DisplayDockView: View {
    let displays: [DisplayObjc]
    @Binding var selectedDisplays: Set<UInt32>
    @Namespace private var namespace
    
    var body: some View {
        GlassEffectContainer(spacing: 10.0) {
            HStack(spacing: 10) {
                ForEach(displays, id: \.screen) { display in
                    DisplayButton(
                        display: display,
                        isSelected: selectedDisplays.contains(display.screen)
                    ) {
                        withAnimation(.easeOut(duration: 0.25)) {
                            if selectedDisplays.contains(display.screen) {
                                selectedDisplays.remove(display.screen)
                            } else {
                                selectedDisplays.insert(display.screen)
                            }
                        }
                    }
                    .matchedGeometryEffect(id: display.screen, in: namespace)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .animation(.spring(response: 0.4, dampingFraction: 0.75), value: displays.map { $0.screen })
        }
    }
}

// MARK: - Display Button
struct DisplayButton: View {
    let display: DisplayObjc
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Spacer()

                Text(display.getDisplayName())
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)

                Text(display.getResolution())
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .frame(width: 200, height: 80)
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
            .glassEffect(
                .clear.interactive(),
                in: .rect(cornerRadius: isSelected ? 26 : 20, style: .continuous)
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(
                        cornerRadius: 26,
                        style: .continuous
                    )
                    .stroke(Color.yellow, lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.03 : 1.0)
        .shadow(
            color: isSelected
                ? Color.yellow.opacity(0.45)
                : Color.black.opacity(0.15),
            radius: isSelected ? 20 : 10,
            y: 8
        )
        .animation(
            .spring(
                response: 0.45,
                dampingFraction: 0.75
            ),
            value: isSelected
        )
    }
    
}


// MARK: - Settings View
struct SettingsView: View {
    @ObservedObject var viewModel: WallpaperViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showFolderPicker = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text("Settings")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button(action: {
                                                dismiss()
                                            }) {
                                                Image(systemName: "xmark.circle.fill")
                                            }
                                            .buttonStyle(BorderlessButtonStyle())
                                            .glassEffect(.clear.tint(.red))
                                                                       .font(Font.system(size: 16, weight: .bold, design: .default))
                
            }
            
            .padding(.bottom, 8)
            
            ScrollView {
                VStack(alignment: .leading, spacing:20) {
                    // Folder Selection
                    SettingRow(title: "Wallpaper Folder") {
                        HStack {
                            TextField("Select folder or type path", text: $viewModel.folderPath)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                            
                            Button("Select Folder 📁") {
                                selectFolder()
                            }
                            
                            Button("Show in Finder 🗂") {
                                openInFinder()
                            }
                        }
                    }
                    
                    
                    Divider()
                    
                    // Streaming Quality
                    SettingRow(title: "Streaming Quality") {
                        Picker("", selection: Binding(
                            get: { UserDefaults.standard.string(forKey: "streaming_quality") ?? "1080p-H264" },
                            set: { UserDefaults.standard.set($0, forKey: "streaming_quality") }
                        )) {
                            Text("1080p H264").tag("1080p-H264")
                            Text("1080p SDR").tag("1080p-SDR")
                            Text("1080p HDR").tag("1080p-HDR")
                            Text("4K SDR").tag("4K-SDR")
                            Text("4K HDR").tag("4K-HDR")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 150)
                    }
                    
                    Divider()
                    
                    // Video Volume
                    SettingRow(title: "Video Volume") {
                        HStack {
                            Slider(value: $viewModel.volume, in: 0...100, step: 1)
                                .frame(width: 200)
                                .onChange(of: viewModel.volume) { newValue in
                                    sharedEngine?.updateVolume(newValue)
                                }
                                
                            
                            Text("\(Int(viewModel.volume))%")
                                .frame(width: 60, alignment: .leading)
                                .monospacedDigit()
                        }
                    }
                    
                    Divider()
                    
                    // Clear Cache
                    SettingRow(title: "Clear Cache") {
                        Button("Clear Cache 🗑️") {
                            viewModel.clearCache()
                        }
                    }
                    
                    // Reset User Data
                    SettingRow(title: "Reset UserData") {
                        Button("Reset") {
                            viewModel.resetUserData()
                        }
                    }
                }
                .padding()
            }
        }
        .padding()
        .frame(width: 600, height: 500)
        .background(.ultraThinMaterial)
        .glassEffect(.regular, in: .rect(cornerRadius: 1))
    }
    
    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Select Wallpaper Folder"
        panel.prompt = "Choose"
        
        if panel.runModal() == .OK, let url = panel.url {
            viewModel.folderPath = url.path
            sharedEngine?.selctFolder(url.path())
            viewModel.reloadContent()
        }
    }
    
    private func openInFinder() {
        if let url = URL(string: "file://\(viewModel.folderPath)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Setting Row
struct SettingRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    
    var body: some View {
        HStack {
            Text(title)
                .frame(width: 200, alignment: .leading)
            content
            Spacer()
        }
    }
}

struct VideoItem: Identifiable {
    let id: String
    var filename: String  // Can be overwritten from metadata
    let path: String
    let thumbnailPath: String
    var quality: String?
    var category: String = "Nature"
    var isRemote: Bool = false  // True for streamable Aerial videos
    var remoteURL: String?      // URL for streaming
    var thumbnailURL: String?   // URL for thumbnail generation (1080p-H264)
    var source: String = "Local" // Source (Local, macOS 26, tvOS 16, etc.)
    var aerialId: String?       // Original Aerial video ID (for duplicate detection)
    var duration: Double?       // Video duration in seconds
    var description: String?    // Video description
    var availableQualities: [String]? // List of available quality options
    
    init(filename: String, path: String, thumbnailPath: String, quality: String? = nil, category: String = "Nature", isRemote: Bool = false, remoteURL: String? = nil, thumbnailURL: String? = nil, source: String = "Local", aerialId: String? = nil, duration: Double? = nil, description: String? = nil, availableQualities: [String]? = nil) {
        self.id = aerialId ?? (isRemote ? (remoteURL ?? UUID().uuidString) : UUID().uuidString)
        self.filename = filename
        self.path = path
        self.thumbnailPath = thumbnailPath
        self.quality = quality
        self.category = category
        self.isRemote = isRemote
        self.remoteURL = remoteURL
        self.thumbnailURL = thumbnailURL
        self.source = source
        self.aerialId = aerialId
        self.duration = duration
        self.description = description
        self.availableQualities = availableQualities
    }
    
    func loadThumbnail() -> NSImage? {
        return ThumbnailCache.shared.image(for: thumbnailPath)
    }
    
    static func categorize(filename: String) -> String {
        let lower = filename.lowercased()
        
        if lower.contains("underwater") || lower.contains("sea") || lower.contains("ocean") || lower.contains("coral") || lower.contains("fish") || lower.contains("jellyfish") {
            return "Underwater"
        }
        
        let cities = ["new york", "dubai", "london", "san francisco", "hong kong", "los angeles", "tokyo", "chicago", "shanghai", "singapore", "city", "urban", "skyline", "downtown"]
        for city in cities {
            if lower.contains(city) {
                return "Cities"
            }
        }
        
        if lower.contains("earth") || lower.contains("planet") || lower.contains("space") || lower.contains("iss") || lower.contains("aurora") {
            return "Planet Earth"
        }
        
        return "Nature"
    }
}
class ThumbnailCache: ObservableObject {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    @Published var lastUpdate = Date()
    
    private init() {
        cache.countLimit = 100
        cache.totalCostLimit = 50 * 1024 * 1024 // 50MB memory limit
        
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(thumbnailSaved(_:)),
            name: NSNotification.Name("ThumbnailSaved"),
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(thumbnailsGenerated),
            name: NSNotification.Name("ThumbnailsGenerated"),
            object: nil
        )
    }
    
    @objc private func thumbnailSaved(_ notification: Notification) {
        if let path = notification.userInfo?["path"] as? String {
            
            cache.removeObject(forKey: path as NSString)
        }
        DispatchQueue.main.async {
            self.lastUpdate = Date()
        }
    }
    
    @objc private func thumbnailsGenerated() {
        
        cache.removeAllObjects()
        DispatchQueue.main.async {
            self.lastUpdate = Date()
        }
    }
    
    func image(for path: String) -> NSImage? {
        if let cached = cache.object(forKey: path as NSString) {
            return cached
        }
        
        // Try jpg first, then fall back to png (legacy)
        var actualPath = path
        if !FileManager.default.fileExists(atPath: path) {
            // Try alternate extension
            if path.hasSuffix(".jpg") {
                let pngPath = (path as NSString).deletingPathExtension + ".png"
                if FileManager.default.fileExists(atPath: pngPath) {
                    actualPath = pngPath
                }
            } else if path.hasSuffix(".png") {
                let jpgPath = (path as NSString).deletingPathExtension + ".jpg"
                if FileManager.default.fileExists(atPath: jpgPath) {
                    actualPath = jpgPath
                }
            }
        }
        
        guard FileManager.default.fileExists(atPath: actualPath),
              let img = NSImage(contentsOfFile: actualPath) else {
            return nil
        }
        
        // Estimate cost based on image size (width * height * 4 bytes per pixel)
        let cost = Int(img.size.width * img.size.height * 4)
        cache.setObject(img, forKey: path as NSString, cost: cost)
        return img
    }
    
    func clearCache() {
        cache.removeAllObjects()
        lastUpdate = Date()
    }
}





class WallpaperViewModel: ObservableObject {

    @Published var videos: [VideoItem] = []
    @Published var displays: [DisplayObjc] = []
    @Published var folderPath: String = ""
    @Published var scaleMode: String = "fill"
    @Published var randomOnStartup: Bool = false
    @Published var pauseOnAppFocus: Bool = true
    @Published var volume: Double = 50.0
    private var currentReloadID = UUID()

    private let defaults = UserDefaults.standard
    let engine: WallpaperEngine

    init(engine: WallpaperEngine = sharedEngine ?? WallpaperEngine.shared()) {
        self.engine = engine
        loadSettings()
        self.engine.setupNotifications()
    }

    deinit {
        engine.removeNotifications()
    }

    func loadSettings() {
        folderPath = engine.getFolderPath()
        scaleMode = defaults.string(forKey: "scale_mode") ?? "fill"
        randomOnStartup = defaults.bool(forKey: "random")
        pauseOnAppFocus = defaults.bool(forKey: "pauseOnAppFocus")
        volume = Double(defaults.float(forKey: "wallpapervolumeprecentage"))
    }
    
    func reloadContent() {
        engine.checkFolderPath()
        
        // Clear thumbnail cache to force fresh load
        ThumbnailCache.shared.clearCache()
        
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: folderPath) else { return }

        let videoFiles = files.filter { f in
            let e = (f as NSString).pathExtension.lowercased()
            return e == "mp4" || e == "mov"
        }

        let reloadID = UUID()
        currentReloadID = reloadID

        DispatchQueue.global(qos: .userInitiated).async {
            let newVideos: [VideoItem] = videoFiles.map { f in
                let full = (self.folderPath as NSString).appendingPathComponent(f)
                let base = (f as NSString).deletingPathExtension
                let thumbPath = (self.engine.thumbnailCachePath() as NSString?)?.appendingPathComponent("\(base).jpg") ?? ""
                
                var item = VideoItem(filename: f, path: full, thumbnailPath: thumbPath)
                
                // Read metadata from JSON if exists
                let metadataPath = (self.folderPath as NSString).appendingPathComponent("\(base).json")
                if let jsonData = FileManager.default.contents(atPath: metadataPath),
                   let metadata = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    item.source = metadata["source"] as? String ?? "Local"
                    item.category = metadata["category"] as? String ?? VideoItem.categorize(filename: f)
                    item.aerialId = metadata["id"] as? String
                    item.quality = metadata["quality"] as? String
                    // Use saved name if available
                    if let savedName = metadata["name"] as? String, !savedName.isEmpty {
                        item.filename = savedName
                    }
                } else {
                    // Unknown file (no metadata) - mark as Uploaded
                    item.source = "Local"
                    item.category = "Uploaded"
                }
                
                self.engine.videoQualityBadge(for: URL(fileURLWithPath: full)){badge in item.quality = badge}
                return item
            }

            DispatchQueue.main.async {
                if reloadID == self.currentReloadID {
                    self.videos = newVideos
                    
                    // Check if any thumbnails are missing and generate once
                    let missingThumbnails = newVideos.filter { $0.loadThumbnail() == nil }
                    if !missingThumbnails.isEmpty {
                        NSLog("Found \(missingThumbnails.count) videos without thumbnails, generating...")
                        self.engine.generateThumbnails()
                    }
                }
            }
        }
    }

    func deleteVideo(_ video: VideoItem) {
        let fileURL = URL(fileURLWithPath: video.path)
        let metadataURL = fileURL.deletingPathExtension().appendingPathExtension("json")

        do {
            try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
            // Also delete metadata JSON if exists
            if FileManager.default.fileExists(atPath: metadataURL.path) {
                try? FileManager.default.trashItem(at: metadataURL, resultingItemURL: nil)
            }
            // Also remove from slideshow if selected
            SlideshowManager.shared.removeVideo(path: video.path)
            // Notify download manager to remove from downloaded IDs
            if let aerialId = video.aerialId {
                NotificationCenter.default.post(name: NSNotification.Name("VideoDeleted"), object: aerialId)
            }
            // Reload content to update the grid
            reloadContent()
        } catch {
            NSLog("Failed to delete video: \(error.localizedDescription)")
        }
    }

    func loadDisplays() {
        displays = sharedEngine?.getDisplays() as! [DisplayObjc]
    }

    func startWallpaper(video: VideoItem, displays: [UInt32]) {
        let arr = displays.map { NSNumber(value: $0) }
        engine.startWallpaper(withPath: video.path, onDisplays: arr)
    }

    func clearCache() {
        engine.clearCache()
        ThumbnailCache.shared.clearCache()
        reloadContent()
    }

    func resetUserData() {
        engine.resetUserData()
        loadSettings()
        reloadContent()
    }

    private func getDisplayName(for id: CGDirectDisplayID) -> String {
        for s in NSScreen.screens {
            if let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               n.uint32Value == id {
                return s.localizedName
            }
        }
        return "Display \(id)"
    }
}

// MARK: - Aerial Video Loader (singleton wrapper for accessing aerial videos)
class AerialVideoLoader {
    static let shared = AerialVideoLoader()
    
    var videos: [AerialVideo] {
        return AerialDownloadManager.shared.videos
    }
    
    func loadIfNeeded() {
        if AerialDownloadManager.shared.videos.isEmpty && !AerialDownloadManager.shared.isLoading {
            AerialDownloadManager.shared.loadSources { [weak self] in
                AerialDownloadManager.shared.loadVideos()
            }
        }
    }
}

// MARK: - Smart Randomizer
class SmartRandomizer {
    static let shared = SmartRandomizer()
    
    private var playedHistory: [String] = []
    private let historyKey = "smart_random_history"
    
    private init() {
        loadHistory()
    }
    
    private func loadHistory() {
        playedHistory = UserDefaults.standard.stringArray(forKey: historyKey) ?? []
    }
    
    private func saveHistory() {
        UserDefaults.standard.set(playedHistory, forKey: historyKey)
    }
    
    func clearHistory() {
        playedHistory.removeAll()
        precomputedNextVideo = nil
        saveHistory()
    }
    
    /// Precomputed video for preloading
    private var precomputedNextVideo: String?
    
    /// Get the next video, precomputing it if needed
    func getNextVideo(from pool: [String]) -> String? {
        // If we have a precomputed video and it's still in the pool, use it
        if let precomputed = precomputedNextVideo, pool.contains(precomputed) {
            precomputedNextVideo = nil
            playedHistory.append(precomputed)
            saveHistory()
            return precomputed
        }
        
        guard !pool.isEmpty else { return nil }
        
        // Filter out already played videos
        let unplayed = pool.filter { !playedHistory.contains($0) }
        
        if unplayed.isEmpty {
            // All videos played - reset history and start fresh
            playedHistory.removeAll()
            saveHistory()
            let next = pool.randomElement()
            if let next = next {
                playedHistory.append(next)
                saveHistory()
            }
            return next
        }
        
        let next = unplayed.randomElement()!
        playedHistory.append(next)
        saveHistory()
        return next
    }
    
    /// Precompute the next video for preloading - returns the video that will be used next
    func precomputeNextVideo(from pool: [String]) -> String? {
        guard !pool.isEmpty else { return nil }
        
        // Don't recompute if already have one
        if let existing = precomputedNextVideo, pool.contains(existing) {
            return existing
        }
        
        // Filter out already played videos
        let unplayed = pool.filter { !playedHistory.contains($0) }
        
        let next: String?
        if unplayed.isEmpty {
            // All videos played - would start fresh
            next = pool.randomElement()
        } else {
            next = unplayed.randomElement()
        }
        
        precomputedNextVideo = next
        return next
    }
    
    func getVideoCategory(filename: String) -> String {
        let lower = filename.lowercased()
        
        if lower.contains("underwater") || lower.contains("sea") || lower.contains("ocean") || lower.contains("coral") || lower.contains("fish") || lower.contains("jellyfish") {
            return "Underwater"
        }
        
        let cities = ["new york", "dubai", "london", "san francisco", "hong kong", "los angeles", "tokyo", "chicago", "shanghai", "singapore", "city", "urban", "skyline", "downtown"]
        for city in cities {
            if lower.contains(city) {
                return "Cities"
            }
        }
        
        if lower.contains("earth") || lower.contains("planet") || lower.contains("space") || lower.contains("iss") || lower.contains("aurora") {
            return "Planet Earth"
        }
        
        return "Nature"
    }
}

// MARK: - Slideshow Manager
class SlideshowManager: ObservableObject {
    static let shared = SlideshowManager()

    @Published var isEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "slideshow_enabled")
            if isEnabled {
                start()
            } else {
                stop()
            }
        }
    }
    
    // Source mode: playlist (selected videos) or categories (random by category)
    @Published var sourceMode: SourceMode = .playlist {
        didSet {
            UserDefaults.standard.set(sourceMode.rawValue, forKey: "slideshow_source_mode")
            SmartRandomizer.shared.clearHistory()
        }
    }

    @Published var selectedVideoPaths: [String] = [] {
        didSet {
            UserDefaults.standard.set(selectedVideoPaths, forKey: "slideshow_videos")
        }
    }
    
    // Categories for category mode
    @Published var selectedCategories: Set<String> = ["Nature", "Cities", "Underwater", "Planet Earth", "Uploaded"] {
        didSet {
            UserDefaults.standard.set(Array(selectedCategories), forKey: "slideshow_categories")
            SmartRandomizer.shared.clearHistory()
        }
    }
    
    // Sources for category mode (macOS 26, tvOS 16, etc.)
    @Published var selectedSources: Set<String> = [] {
        didSet {
            UserDefaults.standard.set(Array(selectedSources), forKey: "slideshow_sources")
            SmartRandomizer.shared.clearHistory()
        }
    }
    
    @Published var onlyLocalVideos: Bool = true {
        didSet {
            UserDefaults.standard.set(onlyLocalVideos, forKey: "slideshow_only_local")
            SmartRandomizer.shared.clearHistory()
        }
    }

    @Published var intervalValue: Double = 30 {
        didSet {
            UserDefaults.standard.set(intervalValue, forKey: "slideshow_interval")
            restartIfNeeded()
        }
    }

    @Published var intervalUnit: IntervalUnit = .minutes {
        didSet {
            UserDefaults.standard.set(intervalUnit.rawValue, forKey: "slideshow_unit")
            restartIfNeeded()
        }
    }

    @Published var syncDisplays: Bool = true {
        didSet {
            UserDefaults.standard.set(syncDisplays, forKey: "slideshow_sync")
        }
    }
    
    @Published var switchMode: SwitchMode = .timerOnly {
        didSet {
            UserDefaults.standard.set(switchMode.rawValue, forKey: "slideshow_switch_mode")
            restartIfNeeded()
        }
    }

    private var timer: Timer?
    private var lastAppliedIndex: Int = -1
    private var videoEndObserver: NSObjectProtocol?
    private var lastVideoEndSwitchTime: Date = .distantPast
    private let videoEndDebounceInterval: TimeInterval = 2.0

    enum IntervalUnit: String, CaseIterable {
        case seconds = "seconds"
        case minutes = "minutes"
        case hours = "hours"

        var displayName: String {
            switch self {
            case .seconds: return "seconds"
            case .minutes: return "minutes"
            case .hours: return "hours"
            }
        }

        var multiplier: Double {
            switch self {
            case .seconds: return 1
            case .minutes: return 60
            case .hours: return 3600
            }
        }
    }
    
    enum SwitchMode: String, CaseIterable {
        case timerOnly = "timer"
        case videoEndOnly = "videoEnd"
        case timerOrVideoEnd = "timerOrVideoEnd"
        
        var displayName: String {
            switch self {
            case .timerOnly: return "Timer only"
            case .videoEndOnly: return "Video end only"
            case .timerOrVideoEnd: return "Timer or video end"
            }
        }
    }
    
    enum SourceMode: String, CaseIterable {
        case playlist = "playlist"
        case categories = "categories"
        
        var displayName: String {
            switch self {
            case .playlist: return "Playlist"
            case .categories: return "Categories"
            }
        }
    }

    private init() {
        loadSettings()
        setupVideoEndNotification()
    }

    private func loadSettings() {
        isEnabled = UserDefaults.standard.bool(forKey: "slideshow_enabled")
        selectedVideoPaths = UserDefaults.standard.stringArray(forKey: "slideshow_videos") ?? []
        intervalValue = UserDefaults.standard.double(forKey: "slideshow_interval")
        if intervalValue == 0 { intervalValue = 30 }

        if let unitString = UserDefaults.standard.string(forKey: "slideshow_unit"),
           let unit = IntervalUnit(rawValue: unitString) {
            intervalUnit = unit
        }
        syncDisplays = UserDefaults.standard.object(forKey: "slideshow_sync") as? Bool ?? true
        
        if let modeString = UserDefaults.standard.string(forKey: "slideshow_switch_mode"),
           let mode = SwitchMode(rawValue: modeString) {
            switchMode = mode
        }
        
        // Load source mode settings
        if let sourceModeString = UserDefaults.standard.string(forKey: "slideshow_source_mode"),
           let mode = SourceMode(rawValue: sourceModeString) {
            sourceMode = mode
        }
        
        if let cats = UserDefaults.standard.stringArray(forKey: "slideshow_categories") {
            selectedCategories = Set(cats)
        }
        
        if let sources = UserDefaults.standard.stringArray(forKey: "slideshow_sources") {
            selectedSources = Set(sources)
        }
        
        onlyLocalVideos = UserDefaults.standard.object(forKey: "slideshow_only_local") as? Bool ?? true

        if isEnabled && canStart() {
            start()
        }
    }
    
    func canStart() -> Bool {
        switch sourceMode {
        case .playlist:
            return selectedVideoPaths.count >= 2
        case .categories:
            return !selectedCategories.isEmpty && !buildVideoPool().isEmpty
        }
    }

    /// Call after screen unlock to re-apply settings and start slideshow if enabled.
    func reloadSettingsAfterUnlock() {
        loadSettings()
    }
    
    private func setupVideoEndNotification() {
        // Listen for video end notification from daemon
        videoEndObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("VideoPlaybackDidEnd"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleVideoEnd()
        }
        
        // Also listen via Darwin notification center
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer = observer else { return }
                let manager = Unmanaged<SlideshowManager>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.handleVideoEnd()
                }
            },
            "com.live.wallpaper.videoEnded" as CFString,
            nil,
            .deliverImmediately
        )
        
        // Listen for preload notification
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer = observer else { return }
                let manager = Unmanaged<SlideshowManager>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    manager.handlePreloadRequest()
                }
            },
            "com.live.wallpaper.preloadNext" as CFString,
            nil,
            .deliverImmediately
        )
    }
    
    private func handlePreloadRequest() {
        guard isEnabled, canStart() else { return }
        guard switchMode == .videoEndOnly || switchMode == .timerOrVideoEnd else { return }
        
        NSLog("[Slideshow] Preload requested, determining next video")
        
        let pool = buildVideoPool()
        guard !pool.isEmpty else { return }
        
        // Get displays
        sharedEngine?.scanDisplays()
        let displays = sharedEngine?.getDisplays() as? [DisplayObjc] ?? []
        guard !displays.isEmpty else { return }
        
        // Precompute the next video
        let nextVideo = SmartRandomizer.shared.precomputeNextVideo(from: pool)
        
        guard let videoPath = nextVideo else { return }
        
        // Set preload path for each display daemon
        let defaults = UserDefaults.standard
        for display in displays {
            let key = "PreloadVideo_\(display.screen)"
            defaults.set(videoPath, forKey: key)
        }
        defaults.synchronize()
        
        // Notify daemons to preload
        let notificationName = CFNotificationName("com.live.wallpaper.preloadVideo" as CFString)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            notificationName,
            nil,
            nil,
            true
        )
        
        NSLog("[Slideshow] Preload triggered for: \(videoPath)")
    }
    
    private func handleVideoEnd() {
        guard isEnabled, canStart() else { return }
        guard switchMode == .videoEndOnly || switchMode == .timerOrVideoEnd else { return }
        
        // Debounce: several daemons (displays) can post at once
        let now = Date()
        if now.timeIntervalSince(lastVideoEndSwitchTime) < videoEndDebounceInterval { return }
        lastVideoEndSwitchTime = now
        
        NSLog("[Slideshow] Video ended, switching wallpaper")
        switchWallpaper()
        
        // Reset timer if in combined mode
        if switchMode == .timerOrVideoEnd {
            restartTimer()
        }
    }
    
    private func start() {
        stop()
        guard canStart() else { return }
        
        if switchMode == .timerOnly || switchMode == .timerOrVideoEnd {
            startTimer()
        }
    }
    
    private func stop() {
        stopTimer()
    }

    private func startTimer() {
        stopTimer()
        guard canStart() else { return }

        let interval = intervalValue * intervalUnit.multiplier
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.handleTimerFired()
        }
    }
    
    private func handleTimerFired() {
        guard isEnabled, canStart() else { return }
        guard switchMode == .timerOnly || switchMode == .timerOrVideoEnd else { return }
        
        NSLog("[Slideshow] Timer fired, switching wallpaper")
        switchWallpaper()
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    private func restartTimer() {
        if switchMode == .timerOnly || switchMode == .timerOrVideoEnd {
            startTimer()
        }
    }

    private func restartIfNeeded() {
        if isEnabled {
            start()
        }
    }

    func addVideo(path: String) {
        if !selectedVideoPaths.contains(path) {
            selectedVideoPaths.append(path)
        }
    }

    func removeVideo(path: String) {
        selectedVideoPaths.removeAll { $0 == path }
    }

    func clearAll() {
        selectedVideoPaths.removeAll()
    }

    /// Public method to switch to next wallpaper (called from tray menu)
    func switchToNextWallpaper() {
        sharedEngine?.scanDisplays()
        let displays = sharedEngine?.getDisplays() as? [DisplayObjc] ?? []
        
        // Use the same pool as slideshow
        let pool = buildVideoPool()
        guard !pool.isEmpty else { return }
        
        if syncDisplays {
            guard let videoPath = SmartRandomizer.shared.getNextVideo(from: pool) else { return }
            let displayIDs = displays.map { NSNumber(value: $0.screen) }
            sharedEngine?.transition(toVideo: videoPath, onDisplays: displayIDs)
        } else {
            for display in displays {
                guard let videoPath = SmartRandomizer.shared.getNextVideo(from: pool) else { continue }
                sharedEngine?.transition(toVideo: videoPath, onDisplays: [NSNumber(value: display.screen)])
            }
        }
    }

    private func switchWallpaper() {
        // Build video pool based on source mode
        let pool = buildVideoPool()
        guard !pool.isEmpty else { return }

        sharedEngine?.scanDisplays()
        let displays = sharedEngine?.getDisplays() as? [DisplayObjc] ?? []

        if syncDisplays {
            // Same wallpaper on all monitors with smooth crossfade using smart randomizer
            guard let videoPath = SmartRandomizer.shared.getNextVideo(from: pool) else { return }

            let displayIDs = displays.map { NSNumber(value: $0.screen) }
            sharedEngine?.transition(toVideo: videoPath, onDisplays: displayIDs)
        } else {
            // Different wallpaper on each monitor with smooth crossfade using smart randomizer
            for display in displays {
                guard let videoPath = SmartRandomizer.shared.getNextVideo(from: pool) else { continue }
                sharedEngine?.transition(toVideo: videoPath, onDisplays: [NSNumber(value: display.screen)])
            }
        }
    }
    
    /// Build video pool based on current source mode
    func buildVideoPool() -> [String] {
        switch sourceMode {
        case .playlist:
            return selectedVideoPaths
        case .categories:
            return buildCategoryPool()
        }
    }
    
    private func buildCategoryPool() -> [String] {
        var pool: [String] = []
        
        // Get folder path for local videos
        guard let folderPath = sharedEngine?.getFolderPath() else { return pool }
        
        // Local videos (only if no sources selected OR "Local" is selected)
        if selectedSources.isEmpty || selectedSources.contains("Local") {
            let fileManager = FileManager.default
            if let files = try? fileManager.contentsOfDirectory(atPath: folderPath) {
                for file in files {
                    let ext = (file as NSString).pathExtension.lowercased()
                    if ext == "mp4" || ext == "mov" {
                        let fullPath = (folderPath as NSString).appendingPathComponent(file)
                        let base = (file as NSString).deletingPathExtension
                        
                        // Read category from metadata JSON if exists
                        var category: String
                        var source: String = "Local"
                        let metadataPath = (folderPath as NSString).appendingPathComponent("\(base).json")
                        if let jsonData = fileManager.contents(atPath: metadataPath),
                           let metadata = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                            category = metadata["category"] as? String ?? "Uploaded"
                            source = metadata["source"] as? String ?? "Local"
                        } else {
                            // No metadata = uploaded file
                            category = "Uploaded"
                        }
                        
                        // Filter by category
                        if !selectedCategories.contains(category) {
                            continue
                        }
                        
                        // Filter by source (if sources are selected and not "Local")
                        if !selectedSources.isEmpty && !selectedSources.contains("Local") && !selectedSources.contains(source) {
                            continue
                        }
                        
                        pool.append(fullPath)
                    }
                }
            }
        }
        
        // Remote videos (if not only local)
        if !onlyLocalVideos {
            AerialVideoLoader.shared.loadIfNeeded()
            let quality = UserDefaults.standard.string(forKey: "streaming_quality") ?? "1080p-H264"
            let aerialVideos = AerialVideoLoader.shared.videos
            let downloadedIDs = AerialDownloadManager.shared.downloadedVideoIDs
            
            for video in aerialVideos {
                // Skip if already downloaded (use local version instead)
                if downloadedIDs.contains(video.id) {
                    continue
                }
                // Filter by category
                if !selectedCategories.contains(video.category) {
                    continue
                }
                // Filter by source (if sources are selected)
                if !selectedSources.isEmpty && !selectedSources.contains(video.source) {
                    continue
                }
                if let url = video.getURL(forQuality: quality) {
                    pool.append(url)
                }
            }
        }
        
        return pool
    }

    func getThumbnailPath(for videoPath: String) -> String {
        let filename = (videoPath as NSString).lastPathComponent
        let base = (filename as NSString).deletingPathExtension
        return (sharedEngine?.thumbnailCachePath() as NSString?)?.appendingPathComponent("\(base).jpg") ?? ""
    }
}

// MARK: - Slideshow View
struct SlideshowView: View {
    @ObservedObject var slideshowManager = SlideshowManager.shared
    @ObservedObject var viewModel: WallpaperViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text("Slideshow Settings")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(BorderlessButtonStyle())
                .glassEffect(.clear.tint(.red))
                .font(.system(size: 16, weight: .bold))
            }
            .padding(.bottom, 8)

            // Enable toggle
            SettingRow(title: "Enable Slideshow") {
                Toggle("", isOn: $slideshowManager.isEnabled)
                    .toggleStyle(.switch)
                    .disabled(!slideshowManager.canStart())
            }
            
            // Source mode (Playlist vs Categories)
            SettingRow(title: "Source") {
                Picker("", selection: $slideshowManager.sourceMode) {
                    ForEach(SlideshowManager.SourceMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            // Switch mode
            SettingRow(title: "Switch mode") {
                Picker("", selection: $slideshowManager.switchMode) {
                    ForEach(SlideshowManager.SwitchMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 160)
            }
            
            // Interval settings (only show if timer is used)
            if slideshowManager.switchMode != .videoEndOnly {
                SettingRow(title: "Switch every") {
                    HStack {
                        TextField("", value: $slideshowManager.intervalValue, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)

                        Picker("", selection: $slideshowManager.intervalUnit) {
                            ForEach(SlideshowManager.IntervalUnit.allCases, id: \.self) { unit in
                                Text(unit.displayName).tag(unit)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 100)
                    }
                }
            }

            // Sync displays toggle
            SettingRow(title: "Sync displays") {
                Toggle("", isOn: $slideshowManager.syncDisplays)
                    .toggleStyle(.switch)
            }
            Text("When enabled, all monitors show the same wallpaper")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 200)

            Divider()

            // Source-specific settings
            if slideshowManager.sourceMode == .playlist {
                // Selected wallpapers section (Playlist mode)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Selected Wallpapers")
                            .font(.headline)
                        Spacer()
                        Text("\(slideshowManager.selectedVideoPaths.count) wallpapers")
                            .foregroundColor(.secondary)
                    }

                    // Drop zone
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(isDropTargeted ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.1))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(
                                        isDropTargeted ? Color.accentColor : Color.gray.opacity(0.3),
                                        style: StrokeStyle(lineWidth: 2, dash: [8])
                                    )
                            )

                        if slideshowManager.selectedVideoPaths.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.system(size: 40))
                                    .foregroundColor(.secondary)
                                Text("Drag & drop wallpapers here")
                                    .foregroundColor(.secondary)
                                Text("or select from the list below")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(slideshowManager.selectedVideoPaths, id: \.self) { path in
                                        SlideshowThumbnailView(
                                            path: path,
                                            thumbnailPath: slideshowManager.getThumbnailPath(for: path),
                                            onRemove: {
                                                slideshowManager.removeVideo(path: path)
                                            }
                                        )
                                    }
                                }
                                .padding(8)
                            }
                        }
                    }
                    .frame(height: 140)
                    .onDrop(of: [.fileURL, .text], isTargeted: $isDropTargeted) { providers in
                        handleDrop(providers: providers)
                    }

                    HStack {
                        Button("Clear All") {
                            slideshowManager.clearAll()
                        }
                        .disabled(slideshowManager.selectedVideoPaths.isEmpty)

                        Spacer()
                    }
                }

                Divider()

                // Available wallpapers to add
                VStack(alignment: .leading, spacing: 8) {
                    Text("Available Wallpapers (click to add)")
                        .font(.headline)

                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 8) {
                            ForEach(viewModel.videos) { video in
                                SlideshowAvailableVideoView(
                                    video: video,
                                    isSelected: slideshowManager.selectedVideoPaths.contains(video.path),
                                    onTap: {
                                        if slideshowManager.selectedVideoPaths.contains(video.path) {
                                            slideshowManager.removeVideo(path: video.path)
                                        } else {
                                            slideshowManager.addVideo(path: video.path)
                                        }
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }
                .frame(maxHeight: 200)
            } else {
                // Categories mode settings
                VStack(alignment: .leading, spacing: 12) {
                    Text("Select Categories")
                        .font(.headline)
                    
                    let allCategories = ["Nature", "Cities", "Underwater", "Planet Earth", "Uploaded"]
                    
                    ForEach(allCategories, id: \.self) { category in
                        HStack {
                            Toggle(category, isOn: Binding(
                                get: { slideshowManager.selectedCategories.contains(category) },
                                set: { enabled in
                                    if enabled {
                                        slideshowManager.selectedCategories.insert(category)
                                    } else {
                                        slideshowManager.selectedCategories.remove(category)
                                    }
                                }
                            ))
                            Spacer()
                        }
                    }
                    
                    Divider()
                    
                    SettingRow(title: "Only local videos") {
                        Toggle("", isOn: $slideshowManager.onlyLocalVideos)
                            .toggleStyle(.switch)
                    }
                    Text("When disabled, streaming videos from internet will be included")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 200)
                    
                    // Show video count
                    let pool = slideshowManager.buildVideoPool()
                    Text("\(pool.count) videos available in selected categories")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .frame(width: 550, height: 650)
        .background(.ultraThinMaterial)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil),
                       ["mp4", "mov"].contains(url.pathExtension.lowercased()) {
                        DispatchQueue.main.async {
                            slideshowManager.addVideo(path: url.path)
                        }
                    }
                }
            }
        }
        return true
    }
}

// MARK: - Slideshow Tab View (for main window tab)
struct SlideshowTabView: View {
    @ObservedObject var slideshowManager = SlideshowManager.shared
    @ObservedObject var viewModel: WallpaperViewModel
    @State private var isDropTargeted = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Enable toggle
                SettingRow(title: "Enable Slideshow") {
                    Toggle("", isOn: $slideshowManager.isEnabled)
                        .toggleStyle(.switch)
                        .disabled(!slideshowManager.canStart())
                }
                
                // Source mode (Playlist vs Categories)
                SettingRow(title: "Source") {
                    Picker("", selection: $slideshowManager.sourceMode) {
                        ForEach(SlideshowManager.SourceMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }

                // Switch mode
                SettingRow(title: "Switch mode") {
                    Picker("", selection: $slideshowManager.switchMode) {
                        ForEach(SlideshowManager.SwitchMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 160)
                }
                
                // Interval settings (only show if timer is used)
                if slideshowManager.switchMode != .videoEndOnly {
                    SettingRow(title: "Switch every") {
                        HStack {
                            TextField("", value: $slideshowManager.intervalValue, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)

                            Picker("", selection: $slideshowManager.intervalUnit) {
                                ForEach(SlideshowManager.IntervalUnit.allCases, id: \.self) { unit in
                                    Text(unit.displayName).tag(unit)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 100)
                        }
                    }
                }

                // Sync displays toggle
                SettingRow(title: "Sync displays") {
                    Toggle("", isOn: $slideshowManager.syncDisplays)
                        .toggleStyle(.switch)
                }
                Text("When enabled, all monitors show the same wallpaper")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 200)

                Divider()

                // Source-specific settings
                if slideshowManager.sourceMode == .playlist {
                    playlistModeContent
                } else {
                    categoriesModeContent
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    @ViewBuilder
    private var playlistModeContent: some View {
        // Selected wallpapers section (Playlist mode)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Selected Wallpapers")
                    .font(.headline)
                Spacer()
                Text("\(slideshowManager.selectedVideoPaths.count) wallpapers")
                    .foregroundColor(.secondary)
            }

            // Drop zone
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(isDropTargeted ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(
                                isDropTargeted ? Color.accentColor : Color.gray.opacity(0.3),
                                style: StrokeStyle(lineWidth: 2, dash: [8])
                            )
                    )

                if slideshowManager.selectedVideoPaths.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("Drag & drop wallpapers here")
                            .foregroundColor(.secondary)
                        Text("or select from the list below")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(slideshowManager.selectedVideoPaths, id: \.self) { path in
                                SlideshowThumbnailView(
                                    path: path,
                                    thumbnailPath: slideshowManager.getThumbnailPath(for: path),
                                    onRemove: {
                                        slideshowManager.removeVideo(path: path)
                                    }
                                )
                            }
                        }
                        .padding(8)
                    }
                }
            }
            .frame(height: 140)
            .onDrop(of: [.fileURL, .text], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers: providers)
            }

            HStack {
                Button("Clear All") {
                    slideshowManager.clearAll()
                }
                .disabled(slideshowManager.selectedVideoPaths.isEmpty)

                Spacer()
            }
        }

        Divider()

        // Available wallpapers to add
        VStack(alignment: .leading, spacing: 8) {
            Text("Available Wallpapers (click to add)")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 8) {
                ForEach(viewModel.videos) { video in
                    SlideshowAvailableVideoView(
                        video: video,
                        isSelected: slideshowManager.selectedVideoPaths.contains(video.path),
                        onTap: {
                            if slideshowManager.selectedVideoPaths.contains(video.path) {
                                slideshowManager.removeVideo(path: video.path)
                            } else {
                                slideshowManager.addVideo(path: video.path)
                            }
                        }
                    )
                }
            }
            .padding(.horizontal, 4)
        }
    }
    
    @ViewBuilder
    private var categoriesModeContent: some View {
        // Categories mode settings
        VStack(alignment: .leading, spacing: 12) {
            Text("Select Categories")
                .font(.headline)
            
            let allCategories = ["Nature", "Cities", "Underwater", "Planet Earth", "Uploaded"]
            
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 8) {
                ForEach(allCategories, id: \.self) { category in
                    Toggle(category, isOn: Binding(
                        get: { slideshowManager.selectedCategories.contains(category) },
                        set: { enabled in
                            if enabled {
                                slideshowManager.selectedCategories.insert(category)
                            } else {
                                slideshowManager.selectedCategories.remove(category)
                            }
                        }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
            
            Divider()
            
            SettingRow(title: "Only local videos") {
                Toggle("", isOn: $slideshowManager.onlyLocalVideos)
                    .toggleStyle(.switch)
            }
            Text("When disabled, streaming videos from internet will be included")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 200)
            
            // Source selection (only when not local-only)
            if !slideshowManager.onlyLocalVideos {
                Divider()
                
                Text("Select Sources")
                    .font(.headline)
                
                let availableSources = Array(Set(AerialDownloadManager.shared.videos.map { $0.source })).sorted()
                let allSourceOptions = ["Local"] + availableSources
                
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 8) {
                    ForEach(allSourceOptions, id: \.self) { source in
                        Toggle(source, isOn: Binding(
                            get: { 
                                slideshowManager.selectedSources.isEmpty || slideshowManager.selectedSources.contains(source) 
                            },
                            set: { enabled in
                                // If currently empty (all selected), populate with all then remove unchecked
                                if slideshowManager.selectedSources.isEmpty && !enabled {
                                    slideshowManager.selectedSources = Set(allSourceOptions)
                                    slideshowManager.selectedSources.remove(source)
                                } else if enabled {
                                    slideshowManager.selectedSources.insert(source)
                                    // If all are now selected, clear the set (means "all")
                                    if slideshowManager.selectedSources == Set(allSourceOptions) {
                                        slideshowManager.selectedSources.removeAll()
                                    }
                                } else {
                                    slideshowManager.selectedSources.remove(source)
                                }
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
                
                Text("All checked = all sources included")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Divider()
            
            // Show video count
            let pool = slideshowManager.buildVideoPool()
            Text("\(pool.count) videos available")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .onAppear {
            // Load aerial videos for source list
            if AerialDownloadManager.shared.videos.isEmpty {
                AerialDownloadManager.shared.loadVideos()
            }
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil),
                       ["mp4", "mov"].contains(url.pathExtension.lowercased()) {
                        DispatchQueue.main.async {
                            slideshowManager.addVideo(path: url.path)
                        }
                    }
                }
            }
        }
        return true
    }
}

// MARK: - Slideshow Thumbnail View
struct SlideshowThumbnailView: View {
    let path: String
    let thumbnailPath: String
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let thumbnail = NSImage(contentsOfFile: thumbnailPath) {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(16/9, contentMode: .fill)
                    .frame(width: 120, height: 70)
                    .clipped()
                    .cornerRadius(8)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 120, height: 70)
                    .cornerRadius(8)
                    .overlay {
                        Image(systemName: "video")
                            .foregroundColor(.secondary)
                    }
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.white)
                    .background(Circle().fill(Color.black.opacity(0.5)))
            }
            .buttonStyle(.plain)
            .padding(4)
        }
    }
}

// MARK: - Slideshow Available Video View
struct SlideshowAvailableVideoView: View {
    let video: VideoItem
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomTrailing) {
                if let thumbnail = video.loadThumbnail() {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(16/9, contentMode: .fill)
                        .frame(height: 70)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 70)
                }

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .background(Circle().fill(Color.white))
                        .padding(4)
                }
            }
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.green : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Aerial Video Model
struct AerialVideo: Identifiable {
    var id: String
    var name: String
    var category: String
    var source: String  // Source name (macOS 26, tvOS 16, etc.)
    var timeOfDay: String
    var duration: TimeInterval?  // Video duration in seconds
    var url4KSDR: String?
    var url4KHDR: String?
    var url1080pSDR: String?
    var url1080pHDR: String?
    var url1080pH264: String?
    
    func getURL(forQuality quality: String) -> String? {
        // First try the requested quality
        let preferred: String? = {
            switch quality {
            case "4K-SDR": return url4KSDR
            case "4K-HDR": return url4KHDR
            case "1080p-SDR": return url1080pSDR
            case "1080p-HDR": return url1080pHDR
            case "1080p-H264": return url1080pH264
            default: return nil
            }
        }()
        // Fallback to any available URL if preferred not available
        return preferred ?? url1080pH264 ?? url1080pSDR ?? url4KSDR ?? url4KHDR ?? url1080pHDR
    }
}

// MARK: - Aerial JSON Structure
struct AerialCategory: Codable {
    let videos: [AerialVideoRaw]
}

struct AerialVideoRaw: Codable {
    let id: String
    let timeOfDay: String?
    let url4KSDR: String?
    let url4KHDR: String?
    let url1080pSDR: String?
    let url1080pHDR: String?
    let url1080pH264: String?
    let accessibilityLabel: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case timeOfDay
        case url4KSDR = "url-4K-SDR"
        case url4KHDR = "url-4K-HDR"
        case url1080pSDR = "url-1080-SDR"
        case url1080pHDR = "url-1080-HDR"
        case url1080pH264 = "url-1080-H264"
        case accessibilityLabel
    }
}

// Official Apple format (entries.json)
struct AerialEntriesJSON: Codable {
    let version: Int?
    let initialAssetCount: Int?
    let assets: [AerialAsset]?
}

struct AerialAsset: Codable {
    let id: String
    let accessibilityLabel: String?
    let url4KSDR: String?
    let url4KSDR240FPS: String?
    let url4KHDR: String?
    let url1080pSDR: String?
    let url1080pHDR: String?
    let url1080pH264: String?
    let timeOfDay: String?

    enum CodingKeys: String, CodingKey {
        case id
        case accessibilityLabel
        case url4KSDR = "url-4K-SDR"
        case url4KSDR240FPS = "url-4K-SDR-240FPS"
        case url4KHDR = "url-4K-HDR"
        case url1080pSDR = "url-1080-SDR"
        case url1080pHDR = "url-1080-HDR"
        case url1080pH264 = "url-1080-H264"
        case timeOfDay
    }
}

// MARK: - Aerial Thumbnail Cache
class AerialThumbnailCache: ObservableObject {
    static let shared = AerialThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    private var loading: Set<String> = []
    private let maxConcurrentLoads = 3
    private var pendingRequests: [(video: AerialVideo, quality: String, index: Int, completion: (NSImage?) -> Void)] = []
    private var cancelledRequests: Set<String> = []
    
    private init() {
        cache.countLimit = 50
        cache.totalCostLimit = 30 * 1024 * 1024 // 30MB limit for aerial thumbnails
    }
    
    /// Cancel a pending request when view disappears
    func cancelRequest(for videoId: String) {
        cancelledRequests.insert(videoId)
        pendingRequests.removeAll { $0.video.id == videoId }
    }
    
    /// Get thumbnail with index for priority ordering (lower index = higher priority)
    func getThumbnail(for video: AerialVideo, quality: String = "1080p-SDR", index: Int = Int.max, completion: @escaping (NSImage?) -> Void) {
        let cacheKey = "\(video.id)-\(quality)"
        
        // Remove from cancelled if re-requested
        cancelledRequests.remove(video.id)
        
        if let cached = cache.object(forKey: cacheKey as NSString) {
            completion(cached)
            return
        }
        
        if loading.contains(cacheKey) {
            return
        }
        
        // Limit concurrent loads to reduce network/CPU pressure
        if loading.count >= maxConcurrentLoads {
            // Insert sorted by index (top-to-bottom order)
            let insertIndex = pendingRequests.firstIndex { $0.index > index } ?? pendingRequests.count
            pendingRequests.insert((video, quality, index, completion), at: insertIndex)
            return
        }
        
        loading.insert(cacheKey)
        
        // Always use 1080p-H264 for thumbnails - smallest and fastest to decode
        let urlString = video.url1080pH264 ?? video.url1080pSDR ?? video.url4KSDR
        
        guard let urlStr = urlString, let url = URL(string: urlStr) else {
            loading.remove(cacheKey)
            processNextPending()
            completion(nil)
            return
        }
        
        // Load asset asynchronously first to ensure tracks are available
        let asset = AVAsset(url: url)
        
        asset.loadValuesAsynchronously(forKeys: ["tracks"]) { [weak self] in
            guard let self = self else { return }
            
            var error: NSError?
            let tracksStatus = asset.statusOfValue(forKey: "tracks", error: &error)
            
            guard tracksStatus == .loaded else {
                DispatchQueue.main.async {
                    self.loading.remove(cacheKey)
                    self.processNextPending()
                    completion(nil)
                }
                return
            }
            
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 180)
            // Allow some tolerance to avoid seeking issues
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            
            let timePoint = CMTime(seconds: 1.0, preferredTimescale: 600)
            
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: timePoint)]) { [weak self] _, cgImage, _, result, _ in
                guard let self = self else { return }
                
                DispatchQueue.main.async {
                    self.loading.remove(cacheKey)
                    self.processNextPending()
                    
                    if result == .succeeded, let cgImage = cgImage {
                        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                        let cost = cgImage.width * cgImage.height * 4
                        self.cache.setObject(nsImage, forKey: cacheKey as NSString, cost: cost)
                        completion(nsImage)
                    } else {
                        completion(nil)
                    }
                }
            }
        }
    }
    
    private func processNextPending() {
        // Skip cancelled requests
        while !pendingRequests.isEmpty && cancelledRequests.contains(pendingRequests.first!.video.id) {
            pendingRequests.removeFirst()
        }
        
        guard !pendingRequests.isEmpty, loading.count < maxConcurrentLoads else { return }
        let request = pendingRequests.removeFirst()
        getThumbnail(for: request.video, quality: request.quality, index: request.index, completion: request.completion)
    }
    
    /// Clean up cancelled requests periodically
    func cleanupCancelled() {
        cancelledRequests.removeAll()
    }
}

// MARK: - Aerial Source Model
struct AerialSource: Codable, Identifiable {
    let id: String
    let name: String
    let url: String
    let format: String
    let description: String?
    let lastUpdated: String?
}

struct AerialSourcesManifest: Codable {
    let version: Int?
    let sources: [AerialSource]
}

// MARK: - Aerial Download Manager
class AerialDownloadManager: ObservableObject {
    static let shared = AerialDownloadManager()

    @Published var videos: [AerialVideo] = []
    @Published var sources: [AerialSource] = []
    @Published var isLoading = false
    @Published var isLoadingSources = false
    @Published var downloadProgress: [String: Double] = [:]
    @Published var downloadingIDs: Set<String> = []  // Currently downloading
    @Published var waitingIDs: Set<String> = []      // Waiting in queue
    @Published var errorMessage: String?
    @Published var downloadedVideoIDs: Set<String> = []  // IDs of downloaded videos

    private var downloadTasks: [String: URLSessionDownloadTask] = [:]
    private var progressObservers: [String: NSKeyValueObservation] = [:]
    private var downloadQueue: [(video: AerialVideo, quality: String, folderPath: String)] = []
    private var isProcessingQueue = false
    
    // Default sources if manifest fails to load
    private let defaultSources: [AerialSource] = [
        AerialSource(id: "macos26", name: "macOS 26", url: "https://sylvan.apple.com/itunes-assets/Aerials126/v4/82/2e/34/822e344c-f5d2-878c-3d56-508d5b09ed61/resources-26-0-1.tar", format: "tar", description: "High framerate videos from macOS 26", lastUpdated: nil),
        AerialSource(id: "tvos16", name: "tvOS 16", url: "https://sylvan.apple.com/Aerials/resources-16.tar", format: "tar", description: "Apple TV screensavers from tvOS 16", lastUpdated: nil),
        AerialSource(id: "tvos13", name: "tvOS 13", url: "https://sylvan.apple.com/Aerials/resources-13.tar", format: "tar", description: "Apple TV screensavers from tvOS 13", lastUpdated: nil),
        AerialSource(id: "community", name: "Community Videos", url: "https://aerialscreensaver.github.io/community/", format: "community", description: "From Joshua Michaels & Hal Bergman", lastUpdated: nil)
    ]
    
    // Manifest URL - can be hosted externally or use default sources
    private let sourcesManifestURL = "https://raw.githubusercontent.com/EvolveEcosystem/screensaver.evolve.aerial/master/resources/sources.json"
    
    // Map category names to video types
    static func getVideoTypeStatic(from categoryName: String) -> String {
        let lowercased = categoryName.lowercased()
        
        // Underwater
        if lowercased.contains("underwater") || lowercased.contains("sea") || lowercased.contains("ocean") || lowercased.contains("coral") {
            return "Underwater"
        }
        
        // Cities
        if lowercased.contains("city") || lowercased.contains("urban") || 
           lowercased.contains("hong kong") || lowercased.contains("london") || 
           lowercased.contains("new york") || lowercased.contains("san francisco") || 
           lowercased.contains("los angeles") || lowercased.contains("dubai") ||
           lowercased.contains("beijing") || lowercased.contains("shanghai") ||
           lowercased.contains("tokyo") || lowercased.contains("paris") ||
           lowercased.contains("chicago") || lowercased.contains("miami") ||
           lowercased.contains("hawaii") && (lowercased.contains("honolulu") || lowercased.contains("waikiki")) {
            return "Cities"
        }
        
        // Planet Earth (space/ISS views)
        if lowercased.contains("earth") || lowercased.contains("planet") || 
           lowercased.contains("space") || lowercased.contains("iss") ||
           lowercased.contains("international space station") {
            return "Planet Earth"
        }
        
        // Default to Nature
        return "Nature"
    }

    private init() {
        // Load default sources initially
        sources = defaultSources
        
        // Listen for video deletions to update downloadedVideoIDs
        NotificationCenter.default.addObserver(forName: NSNotification.Name("VideoDeleted"), object: nil, queue: .main) { [weak self] notification in
            if let videoId = notification.object as? String {
                self?.downloadedVideoIDs.remove(videoId)
            }
        }
    }
    
    /// Scan folder for downloaded video IDs from metadata files
    func scanDownloadedVideos(in folderPath: String) {
        var ids = Set<String>()
        let fileManager = FileManager.default
        
        guard let files = try? fileManager.contentsOfDirectory(atPath: folderPath) else { return }
        
        for file in files {
            guard file.hasSuffix(".json") else { continue }
            let jsonPath = (folderPath as NSString).appendingPathComponent(file)
            
            if let data = fileManager.contents(atPath: jsonPath),
               let metadata = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let videoId = metadata["id"] as? String {
                ids.insert(videoId)
            }
        }
        
        DispatchQueue.main.async {
            self.downloadedVideoIDs = ids
        }
    }
    
    /// Check if video is downloaded by ID
    func isDownloadedByID(_ videoID: String) -> Bool {
        return downloadedVideoIDs.contains(videoID)
    }
    
    func loadSources(completion: (() -> Void)? = nil) {
        guard !isLoadingSources else {
            completion?()
            return
        }
        isLoadingSources = true
        
        guard let url = URL(string: sourcesManifestURL) else {
            sources = defaultSources
            isLoadingSources = false
            completion?()
            return
        }
        
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isLoadingSources = false
                
                if let error = error {
                    print("Failed to load sources manifest: \(error.localizedDescription), using defaults")
                    self?.sources = self?.defaultSources ?? []
                    completion?()
                    return
                }
                
                guard let data = data else {
                    self?.sources = self?.defaultSources ?? []
                    completion?()
                    return
                }
                
                do {
                    let decoder = JSONDecoder()
                    let manifest = try decoder.decode(AerialSourcesManifest.self, from: data)
                    self?.sources = manifest.sources
                    print("Loaded \(manifest.sources.count) sources from manifest")
                } catch {
                    print("Failed to parse sources manifest: \(error.localizedDescription), using defaults")
                    self?.sources = self?.defaultSources ?? []
                }
                completion?()
            }
        }.resume()
    }
    
    func discoverSources() {
        // Try to discover sources by checking known URLs
        var discoveredSources: [AerialSource] = []
        let knownURLs: [(String, String, String)] = [
            ("community", "Community Videos", "https://raw.githubusercontent.com/EvolveEcosystem/screensaver.evolve.aerial/master/resources/lib/aerial.json"),
            ("macos26", "macOS 26", "https://sylvan.apple.com/Aerials/2x/entries.json"),
            ("tvos16", "tvOS 16", "https://sylvan.apple.com/Aerials/2x/entries.json"),
            ("tvos13", "tvOS 13", "https://sylvan.apple.com/Aerials/2x/entries.json")
        ]
        
        let group = DispatchGroup()
        
        for (id, name, urlString) in knownURLs {
            group.enter()
            guard let url = URL(string: urlString) else {
                group.leave()
                continue
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 5.0
            
            URLSession.shared.dataTask(with: request) { _, response, _ in
                defer { group.leave() }
                
                if let httpResponse = response as? HTTPURLResponse,
                   httpResponse.statusCode == 200 {
                    let format = urlString.contains("entries.json") ? "entries" : "categories"
                    discoveredSources.append(AerialSource(
                        id: id,
                        name: name,
                        url: urlString,
                        format: format,
                        description: nil,
                        lastUpdated: nil
                    ))
                }
            }.resume()
        }
        
        group.notify(queue: .main) { [weak self] in
            if !discoveredSources.isEmpty {
                self?.sources = discoveredSources
                print("Discovered \(discoveredSources.count) available sources")
            }
        }
    }

    func loadVideos() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        videos = []

        let group = DispatchGroup()
        var allVideos: [AerialVideo] = []
        var errors: [String] = []

        for source in sources {
            group.enter()
            guard let url = URL(string: source.url) else {
                errors.append("Invalid URL for \(source.name)")
                group.leave()
                continue
            }
            
            let sourceName = source.name
            let sourceFormat = source.format

            URLSession.shared.dataTask(with: url) { data, response, error in
                defer { group.leave() }
                
                if let error = error {
                    errors.append("\(sourceName): \(error.localizedDescription)")
                    return
                }

                guard let data = data else {
                    errors.append("\(sourceName): No data received")
                    return
                }

                if sourceFormat == "tar" {
                    // TAR archive - need to extract and find entries.json
                    self.processTARArchive(data: data, sourceName: sourceName) { videos, errorMsg in
                        if let errorMsg = errorMsg {
                            errors.append(errorMsg)
                        }
                        allVideos.append(contentsOf: videos)
                    }
                } else if sourceFormat == "community" {
                    // Community format - try to load from known community JSON
                    self.loadCommunitySource(sourceName: sourceName, group: group) { videos, errorMsg in
                        if let errorMsg = errorMsg {
                            errors.append(errorMsg)
                        }
                        allVideos.append(contentsOf: videos)
                    }
                } else {
                    // JSON formats (entries or categories)
                    do {
                        let decoder = JSONDecoder()
                        var sourceVideoCount = 0
                        
                        if sourceFormat == "entries" {
                            // Official Apple format (entries.json)
                            let entriesJSON = try decoder.decode(AerialEntriesJSON.self, from: data)
                            
                            if let assets = entriesJSON.assets {
                                for asset in assets {
                                    let categoryName = asset.accessibilityLabel ?? "Unknown"
                                    let videoType = AerialDownloadManager.getVideoTypeStatic(from: categoryName)
                                    
                                let video = AerialVideo(
                                    id: asset.id,
                                    name: categoryName,
                                    category: videoType,
                                    source: sourceName,
                                    timeOfDay: asset.timeOfDay ?? "day",
                                    duration: nil,
                                    url4KSDR: asset.url4KSDR ?? asset.url4KSDR240FPS,
                                    url4KHDR: asset.url4KHDR,
                                    url1080pSDR: asset.url1080pSDR,
                                    url1080pHDR: asset.url1080pHDR,
                                    url1080pH264: asset.url1080pH264
                                )
                                allVideos.append(video)
                                sourceVideoCount += 1
                            }
                        }
                        print("\(sourceName): Loaded \(sourceVideoCount) videos from entries format")
                        } else {
                            // Community format (categories)
                            let categoriesDict = try decoder.decode([String: AerialCategory].self, from: data)
                            
                            for (categoryName, category) in categoriesDict {
                                let videoType = AerialDownloadManager.getVideoTypeStatic(from: categoryName)
                                for videoRaw in category.videos {
                                    let video = AerialVideo(
                                        id: videoRaw.id,
                                        name: categoryName,
                                        category: videoType,
                                        source: sourceName,
                                        timeOfDay: videoRaw.timeOfDay ?? "day",
                                        duration: nil,
                                        url4KSDR: videoRaw.url4KSDR,
                                        url4KHDR: videoRaw.url4KHDR,
                                        url1080pSDR: videoRaw.url1080pSDR,
                                        url1080pHDR: videoRaw.url1080pHDR,
                                        url1080pH264: videoRaw.url1080pH264
                                    )
                                    allVideos.append(video)
                                    sourceVideoCount += 1
                                }
                            }
                            print("\(sourceName): Loaded \(sourceVideoCount) videos from \(categoriesDict.count) categories")
                        }
                    } catch {
                        errors.append("\(sourceName): Failed to parse - \(error.localizedDescription)")
                    }
                }
            }.resume()
        }

        group.notify(queue: .main) { [weak self] in
            self?.isLoading = false
            self?.videos = allVideos
            print("Loaded \(allVideos.count) videos from \(self?.sources.count ?? 0) sources")
            if !errors.isEmpty && allVideos.isEmpty {
                self?.errorMessage = errors.joined(separator: "\n")
            } else if !errors.isEmpty {
                // Some sources failed but we have videos
                print("Some sources failed: \(errors.joined(separator: ", "))")
            }
            // Load durations for all videos
            self?.loadDurationsForVideos()
        }
    }
    
    private func loadDurationsForVideos() {
        for index in videos.indices {
            let video = videos[index]
            guard video.duration == nil else { continue }
            
            let urlString = video.url4KSDR ?? video.url1080pSDR ?? video.url4KHDR ?? video.url1080pHDR ?? video.url1080pH264
            guard let urlStr = urlString, let url = URL(string: urlStr) else { continue }
            
            let asset = AVAsset(url: url)
            asset.loadValuesAsynchronously(forKeys: ["duration"]) { [weak self] in
                var error: NSError?
                let durationStatus = asset.statusOfValue(forKey: "duration", error: &error)
                
                if durationStatus == .loaded {
                    let duration = CMTimeGetSeconds(asset.duration)
                    DispatchQueue.main.async {
                        if index < self?.videos.count ?? 0 {
                            self?.videos[index].duration = duration.isFinite && duration > 0 ? duration : nil
                        }
                    }
                }
            }
        }
    }
    
    private func processTARArchive(data: Data, sourceName: String, completion: @escaping ([AerialVideo], String?) -> Void) {
        // Save TAR to temp file
        let tempDir = FileManager.default.temporaryDirectory
        let tempTarURL = tempDir.appendingPathComponent("\(sourceName.replacingOccurrences(of: " ", with: "_")).tar")
        
        do {
            try data.write(to: tempTarURL)
            
            // Extract TAR using system tar command
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xf", tempTarURL.path, "-C", tempDir.path]
            
            try process.run()
            process.waitUntilExit()
            
            // Look for entries.json in extracted files
            let entriesJSONURL = tempDir.appendingPathComponent("entries.json")
            
            var videos: [AerialVideo] = []
            var errorMessage: String?
            
            if FileManager.default.fileExists(atPath: entriesJSONURL.path) {
                if let jsonData = try? Data(contentsOf: entriesJSONURL) {
                    let decoder = JSONDecoder()
                    if let entriesJSON = try? decoder.decode(AerialEntriesJSON.self, from: jsonData) {
                        if let assets = entriesJSON.assets {
                            var sourceVideoCount = 0
                            for asset in assets {
                                let categoryName = asset.accessibilityLabel ?? "Unknown"
                                let videoType = AerialDownloadManager.getVideoTypeStatic(from: categoryName)
                                
                                let video = AerialVideo(
                                    id: asset.id,
                                    name: categoryName,
                                    category: videoType,
                                    source: sourceName,
                                    timeOfDay: asset.timeOfDay ?? "day",
                                    duration: nil,
                                    url4KSDR: asset.url4KSDR ?? asset.url4KSDR240FPS,
                                    url4KHDR: asset.url4KHDR,
                                    url1080pSDR: asset.url1080pSDR,
                                    url1080pHDR: asset.url1080pHDR,
                                    url1080pH264: asset.url1080pH264
                                )
                                videos.append(video)
                                sourceVideoCount += 1
                            }
                            print("\(sourceName): Loaded \(sourceVideoCount) videos from TAR archive")
                        }
                    }
                }
            }
            
            // Cleanup
            try? FileManager.default.removeItem(at: tempTarURL)
            try? FileManager.default.removeItem(at: entriesJSONURL)
            
            completion(videos, errorMessage)
        } catch {
            completion([], "\(sourceName): Failed to process TAR - \(error.localizedDescription)")
        }
    }
    
    private func loadCommunitySource(sourceName: String, group: DispatchGroup, completion: @escaping ([AerialVideo], String?) -> Void) {
        // Try known community JSON URLs
        let communityURLs = [
            "https://raw.githubusercontent.com/EvolveEcosystem/screensaver.evolve.aerial/master/resources/lib/aerial.json"
        ]
        
        for communityURL in communityURLs {
            guard let url = URL(string: communityURL) else { continue }
            
            group.enter()
            URLSession.shared.dataTask(with: url) { data, response, error in
                defer { group.leave() }
                
                var errorMessage: String?
                var videos: [AerialVideo] = []
                
                if let error = error {
                    errorMessage = "\(sourceName): \(error.localizedDescription)"
                } else if let data = data {
                    do {
                        let decoder = JSONDecoder()
                        let categoriesDict = try decoder.decode([String: AerialCategory].self, from: data)
                        
                        var sourceVideoCount = 0
                        for (categoryName, category) in categoriesDict {
                            let videoType = AerialDownloadManager.getVideoTypeStatic(from: categoryName)
                            for videoRaw in category.videos {
                                let video = AerialVideo(
                                    id: videoRaw.id,
                                    name: categoryName,
                                    category: videoType,
                                    source: sourceName,
                                    timeOfDay: videoRaw.timeOfDay ?? "day",
                                    duration: nil,
                                    url4KSDR: videoRaw.url4KSDR,
                                    url4KHDR: videoRaw.url4KHDR,
                                    url1080pSDR: videoRaw.url1080pSDR,
                                    url1080pHDR: videoRaw.url1080pHDR,
                                    url1080pH264: videoRaw.url1080pH264
                                )
                                videos.append(video)
                                sourceVideoCount += 1
                            }
                        }
                        print("\(sourceName): Loaded \(sourceVideoCount) videos from \(categoriesDict.count) categories")
                    } catch {
                        errorMessage = "\(sourceName): Failed to parse - \(error.localizedDescription)"
                    }
                } else {
                    errorMessage = "\(sourceName): No data received"
                }
                
                DispatchQueue.main.async {
                    completion(videos, errorMessage)
                }
            }.resume()
            return // Only try first URL
        }
    }

    /// Add video to download queue
    func downloadVideo(_ video: AerialVideo, quality: String = "4K-SDR", to folderPath: String) {
        // Skip if already downloaded or in queue
        if downloadedVideoIDs.contains(video.id) || downloadingIDs.contains(video.id) || waitingIDs.contains(video.id) {
            return
        }
        
        // Add to queue
        downloadQueue.append((video, quality, folderPath))
        waitingIDs.insert(video.id)
        
        // Start processing queue if not already
        processDownloadQueue()
    }
    
    private func processDownloadQueue() {
        guard !isProcessingQueue, !downloadQueue.isEmpty else { return }
        isProcessingQueue = true
        
        let (video, quality, folderPath) = downloadQueue.removeFirst()
        waitingIDs.remove(video.id)
        
        startDownload(video: video, quality: quality, folderPath: folderPath)
    }
    
    private func startDownload(video: AerialVideo, quality: String, folderPath: String) {
        let urlString: String?
        switch quality {
        case "4K-HDR":
            urlString = video.url4KHDR
        case "4K-SDR":
            urlString = video.url4KSDR
        case "1080p-SDR":
            urlString = video.url1080pSDR
        case "1080p-HDR":
            urlString = video.url1080pHDR
        case "1080p-H264":
            urlString = video.url1080pH264
        default:
            urlString = video.url4KSDR ?? video.url1080pSDR
        }

        guard let urlStr = urlString, let url = URL(string: urlStr) else {
            errorMessage = "No download URL available for \(quality)"
            isProcessingQueue = false
            processDownloadQueue()
            return
        }

        downloadingIDs.insert(video.id)
        downloadProgress[video.id] = 0

        let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
            DispatchQueue.main.async {
                self?.downloadingIDs.remove(video.id)
                self?.downloadProgress.removeValue(forKey: video.id)
                self?.downloadTasks.removeValue(forKey: video.id)
                self?.progressObservers.removeValue(forKey: video.id)
                self?.isProcessingQueue = false
            }

            if let error = error {
                DispatchQueue.main.async {
                    self?.errorMessage = "Download failed: \(error.localizedDescription)"
                    self?.processDownloadQueue()
                }
                return
            }

            guard let tempURL = tempURL else {
                DispatchQueue.main.async {
                    self?.processDownloadQueue()
                }
                return
            }

            let filename = url.lastPathComponent
            let destURL = URL(fileURLWithPath: folderPath).appendingPathComponent(filename)

            do {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: destURL)
                
                // Save metadata JSON
                let metadataURL = destURL.deletingPathExtension().appendingPathExtension("json")
                let metadata: [String: Any] = [
                    "id": video.id,
                    "name": video.name,
                    "source": video.source,
                    "category": video.category,
                    "timeOfDay": video.timeOfDay,
                    "quality": quality
                ]
                if let jsonData = try? JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted) {
                    try? jsonData.write(to: metadataURL)
                }

                DispatchQueue.main.async {
                    // Add to downloaded IDs
                    self?.downloadedVideoIDs.insert(video.id)
                    // Notify that download completed
                    NotificationCenter.default.post(name: NSNotification.Name("AerialVideoDownloaded"), object: nil)
                    // Process next in queue
                    self?.processDownloadQueue()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.errorMessage = "Failed to save file: \(error.localizedDescription)"
                    self?.processDownloadQueue()
                }
            }
        }

        // Track progress
        let observation = task.progress.observe(\.fractionCompleted, options: [.new, .initial]) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            DispatchQueue.main.async {
                self?.downloadProgress[video.id] = fraction
            }
        }
        
        progressObservers[video.id] = observation
        downloadTasks[video.id] = task
        task.resume()
    }

    func cancelDownload(_ videoID: String) {
        // Remove from queue if waiting
        downloadQueue.removeAll { $0.video.id == videoID }
        waitingIDs.remove(videoID)
        
        // Cancel active download
        downloadTasks[videoID]?.cancel()
        progressObservers[videoID]?.invalidate()
        downloadTasks.removeValue(forKey: videoID)
        progressObservers.removeValue(forKey: videoID)
        downloadingIDs.remove(videoID)
        downloadProgress.removeValue(forKey: videoID)
    }

    func isDownloaded(_ video: AerialVideo, quality: String, in folderPath: String) -> Bool {
        // Check by ID first (most reliable)
        if downloadedVideoIDs.contains(video.id) {
            return true
        }
        
        // Fallback to file check
        let urlString: String?
        switch quality {
        case "4K-HDR":
            urlString = video.url4KHDR
        case "4K-SDR":
            urlString = video.url4KSDR
        case "1080p-SDR":
            urlString = video.url1080pSDR
        case "1080p-HDR":
            urlString = video.url1080pHDR
        case "1080p-H264":
            urlString = video.url1080pH264
        default:
            urlString = video.url4KSDR
        }

        guard let urlStr = urlString, let url = URL(string: urlStr) else { return false }
        let filename = url.lastPathComponent
        let destPath = (folderPath as NSString).appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: destPath)
    }
}

// MARK: - Aerial Browser View
struct AerialBrowserView: View {
    @ObservedObject var downloadManager = AerialDownloadManager.shared
    @ObservedObject var viewModel: WallpaperViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSource: String = "All"
    @State private var selectedQuality: String = "4K-SDR"

    var sources: [String] {
        var srcs = Set(downloadManager.videos.map { $0.source })
        return ["All"] + srcs.sorted()
    }

    var filteredVideos: [AerialVideo] {
        if selectedSource == "All" {
            return downloadManager.videos
        }
        return downloadManager.videos.filter { $0.source == selectedSource }
    }
    
    var groupedByCategory: [String: [AerialVideo]] {
        Dictionary(grouping: filteredVideos) { $0.category }
    }
    
    var sortedCategories: [String] {
        groupedByCategory.keys.sorted()
    }
    

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Apple Aerial Wallpapers")
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()

                Picker("Quality", selection: $selectedQuality) {
                    Text("4K SDR").tag("4K-SDR")
                    Text("4K HDR").tag("4K-HDR")
                    Text("1080p SDR").tag("1080p-SDR")
                    Text("1080p HDR").tag("1080p-HDR")
                    Text("1080p H264").tag("1080p-H264")
                }
                .pickerStyle(.menu)
                .frame(width: 130)
            }
            .padding()

            // Source filter
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(sources, id: \.self) { source in
                        Button(action: { selectedSource = source }) {
                            Text(source)
                                .font(.system(size: 12, weight: selectedSource == source ? .bold : .regular))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(selectedSource == source ? Color.accentColor : Color.gray.opacity(0.2))
                                )
                                .foregroundColor(selectedSource == source ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 8)

            if let error = downloadManager.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding()
            }

            // Video grid
            if downloadManager.isLoading {
                Spacer()
                ProgressView("Loading Aerial videos...")
                Spacer()
            } else if downloadManager.videos.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "cloud.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.secondary)
                    Text("No videos loaded")
                        .font(.headline)
                    Button("Load Videos") {
                        downloadManager.loadVideos()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(sortedCategories, id: \.self) { category in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(category)
                                    .font(.headline)
                                    .padding(.horizontal)
                                
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200))], spacing: 12) {
                                    let categoryVideos = groupedByCategory[category] ?? []
                                    ForEach(Array(categoryVideos.enumerated()), id: \.element.id) { idx, video in
                                        AerialVideoCard(
                                            video: video,
                                            quality: selectedQuality,
                                            isDownloaded: downloadManager.isDownloaded(video, quality: selectedQuality, in: viewModel.folderPath),
                                            isDownloading: downloadManager.downloadingIDs.contains(video.id),
                                            progress: downloadManager.downloadProgress[video.id] ?? 0,
                                            onDownload: {
                                                downloadManager.downloadVideo(video, quality: selectedQuality, to: viewModel.folderPath)
                                            },
                                            onCancel: {
                                                downloadManager.cancelDownload(video.id)
                                            },
                                            index: idx
                                        )
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                    .padding(.vertical)
                }
            }
        }
        .background(.ultraThinMaterial)
        .onAppear {
            if downloadManager.sources.isEmpty {
                downloadManager.loadSources {
                    if downloadManager.videos.isEmpty {
                        downloadManager.loadVideos()
                    }
                }
            } else if downloadManager.videos.isEmpty {
                downloadManager.loadVideos()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("AerialVideoDownloaded"))) { _ in
            viewModel.reloadContent()
        }
    }
}

// MARK: - Aerial Video Card
struct AerialVideoCard: View {
    let video: AerialVideo
    let quality: String
    let isDownloaded: Bool
    let isDownloading: Bool
    let progress: Double
    let onDownload: () -> Void
    let onCancel: () -> Void
    var index: Int = 0  // For priority-based thumbnail loading
    
    @StateObject private var thumbnailCache = AerialThumbnailCache.shared
    @State private var thumbnail: NSImage?
    
    private func formatDuration(_ duration: TimeInterval?) -> String {
        guard let duration = duration, duration > 0 else {
            return "—"
        }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        if minutes > 0 {
            return String(format: "%d:%02d", minutes, seconds)
        }
        return String(format: "0:%02d", seconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Video thumbnail
            ZStack {
                if let thumbnail = thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(16/9, contentMode: .fill)
                        .frame(height: 110)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: video.timeOfDay == "night" ? [.indigo, .black] : [.blue, .cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(height: 110)
                    
                    VStack {
                        Image(systemName: video.timeOfDay == "night" ? "moon.stars.fill" : "sun.max.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white.opacity(0.8))

                        Text(video.name)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                }
            }
            .cornerRadius(8)
            .onAppear {
                loadThumbnail()
            }
            .onDisappear {
                if thumbnail == nil {
                    thumbnailCache.cancelRequest(for: video.id)
                }
            }
            .onChange(of: quality) { _ in
                thumbnail = nil
                loadThumbnail()
            }

            // Info & download button
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(video.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)

                    Text(formatDuration(video.duration))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if isDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 22))
                } else if isDownloading {
                    Button(action: onCancel) {
                        ZStack {
                            Circle()
                                .stroke(Color.gray.opacity(0.3), lineWidth: 3)
                                .frame(width: 28, height: 28)

                            Circle()
                                .trim(from: 0, to: progress)
                                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .frame(width: 28, height: 28)
                                .rotationEffect(.degrees(-90))
                                .animation(.linear, value: progress)

                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.accentColor)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: onDownload) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.gray.opacity(0.1))
        )
    }
    
    private func loadThumbnail() {
        thumbnailCache.getThumbnail(for: video, quality: quality, index: index) { image in
            thumbnail = image
        }
    }
}

#Preview {
    ContentView()
    SettingsView(viewModel: WallpaperViewModel())
}


