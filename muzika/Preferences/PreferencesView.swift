import SwiftUI

struct PreferencesView: View {
    @Bindable var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var searchSelection: SearchSelection?

    private struct SearchSelection: Equatable {
        let item: PreferencesItem
        private let id = UUID()
    }

    private var results: [PreferencesItem] { PreferencesItem.matching(query) }
    private var pageAnimation: Animation? {
        state.preferences.heroAnimations && !reduceMotion ? .easeInOut(duration: 0.22) : nil
    }
    private var sidebarBackground: AnyShapeStyle {
        if reduceTransparency || contrast == .increased {
            AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
        } else {
            AnyShapeStyle(Material.regular)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= 790 {
                HStack(spacing: 0) {
                    pageList
                        .frame(width: 245)
                    Divider()
                    pageDetail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ZStack {
                    if let page = state.settingsPage {
                        detail(for: page, showBack: true)
                    } else {
                        pageList.transition(.opacity)
                    }
                }
                .animation(pageAnimation, value: state.settingsPage)
            }
        }
    }

    private var pageList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Settings")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 22)
                .padding(.top, 22)
            searchField
                .padding(.horizontal, 18)
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                List(PreferencesPage.allCases, selection: $state.settingsPage) { page in
                    Label(page.title, systemImage: page.symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .liquidGlassHover()
                        .tag(page)
                }
                .listStyle(.sidebar)
            } else if results.isEmpty {
                ContentUnavailableView("No settings found", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(results) { item in
                    Button {
                        select(item)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                            Text(item.page.title).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .liquidGlassHover()
                }
                .listStyle(.sidebar)
            }
        }
        .scrollContentBackground(.hidden)
        .background(sidebarBackground)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search settings", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit {
                    if let first = results.first { select(first) }
                }
                .liquidGlassHover()
            if !query.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") {
                    query = ""
                    searchSelection = nil
                    searchFocused = true
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .liquidGlassHover()
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }

    private func select(_ item: PreferencesItem) {
        searchSelection = SearchSelection(item: item)
        searchFocused = false
        state.settingsPage = item.page
    }

    private var pageDetail: some View {
        ZStack {
            if let page = state.settingsPage {
                detail(for: page, showBack: false)
            } else {
                ContentUnavailableView("Settings", systemImage: "gearshape", description: Text("Select a settings category."))
                    .transition(.opacity)
            }
        }
        .animation(pageAnimation, value: state.settingsPage)
    }

    private func detail(for page: PreferencesPage, showBack: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if showBack {
                Button {
                    state.settingsPage = nil
                } label: {
                    Label("Settings", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .liquidGlassHover()
            }
            Text(page.title)
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            ScrollViewReader { scroll in
                settingsForm(for: page)
                    .padding(.horizontal, -14)
                    .task(id: searchSelection) {
                        guard let searchSelection, searchSelection.item.page == page else { return }
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                            scroll.scrollTo(searchSelection.item, anchor: .center)
                        }
                    }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 22)
        .id(page)
        .transition(.opacity)
    }

    @ViewBuilder
    private func settingsForm(for page: PreferencesPage) -> some View {
        @Bindable var preferences = state.preferences
        @Bindable var history = state.history
        @Bindable var playback = state.playback
        switch page {
        case .appearance:
            Form {
                Section("Effects") {
                    Toggle(PreferencesItem.heroAnimations.title, isOn: $preferences.heroAnimations)
                        .liquidGlassHover()
                        .id(PreferencesItem.heroAnimations)
                    Toggle(PreferencesItem.blurEffects.title, isOn: $preferences.forceBlur)
                        .liquidGlassHover()
                        .id(PreferencesItem.blurEffects)
                }
                Section("Layout") {
                    Picker(PreferencesItem.interfaceSize.title, selection: $preferences.largerInterface) {
                        Text("Smaller").tag(false)
                        Text("Larger").tag(true)
                    }
                    .liquidGlassHover()
                    .id(PreferencesItem.interfaceSize)
                    Picker(PreferencesItem.historyView.title, selection: $preferences.historyGrid) {
                        Text("List").tag(false)
                        Text("Grid").tag(true)
                    }
                    .liquidGlassHover()
                    .id(PreferencesItem.historyView)
                    Toggle(PreferencesItem.continueListening.title, isOn: $history.continueListening)
                        .onChange(of: history.continueListening) { _, value in
                            UserDefaults.standard.set(value, forKey: "appearance.continueListening")
                        }
                        .liquidGlassHover()
                        .id(PreferencesItem.continueListening)
                }
            }
            .formStyle(.grouped)
        case .playback:
            Form {
                Section("Volume and transitions") {
                    Toggle(PreferencesItem.loudVolume.title, isOn: $preferences.confirmLoudVolume)
                        .liquidGlassHover()
                        .id(PreferencesItem.loudVolume)
                    LabeledContent(PreferencesItem.loudVolumeThreshold.title) {
                        Slider(value: $preferences.loudVolumeLevel, in: 0.4...0.95, step: 0.05) {
                            Text(PreferencesItem.loudVolumeThreshold.title)
                        }
                        .frame(maxWidth: 175)
                        .liquidGlassHover()
                        Text(preferences.loudVolumeLevel, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .frame(minWidth: 38)
                    }
                    .disabled(!preferences.confirmLoudVolume)
                    .id(PreferencesItem.loudVolumeThreshold)
                    Toggle(PreferencesItem.gapless.title, isOn: $playback.gapless)
                        .liquidGlassHover()
                        .id(PreferencesItem.gapless)
                    Toggle(PreferencesItem.spatialAudio.title, isOn: $playback.spatialAudio)
                        .help("Uses Spatial Audio when supported by your audio output.")
                        .accessibilityHint("Uses Spatial Audio when supported by your audio output.")
                        .liquidGlassHover()
                        .id(PreferencesItem.spatialAudio)
                }
                Section("Queue") {
                    Toggle(PreferencesItem.noDuplicates.title, isOn: $playback.preventDuplicates)
                        .liquidGlassHover()
                        .id(PreferencesItem.noDuplicates)
                    Toggle(PreferencesItem.lockQueue.title, isOn: $playback.queueLocked)
                        .liquidGlassHover()
                        .id(PreferencesItem.lockQueue)
                }
                Section("Cover art") {
                    Picker(PreferencesItem.coverArt.title, selection: $preferences.coverStyle) {
                        ForEach(CoverStyle.allCases) { style in
                            Text(style.title)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .liquidGlassHover()
                                .tag(style)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Cover art")
                    .pickerStyle(.inline)
                    .id(PreferencesItem.coverArt)
                }
                Section("Listening statistics") {
                    Button(PreferencesItem.listeningStatistics.title) { state.navigate(.statistics) }
                        .liquidGlassHover()
                        .id(PreferencesItem.listeningStatistics)
                }
            }
            .formStyle(.grouped)
        case .lyrics:
            Form {
                Section("Appearance") {
                    LabeledContent(PreferencesItem.lyricsSize.title) {
                        Slider(value: $preferences.lyricsSize, in: 0.8...1.4, step: 0.05) {
                            Text("Lyrics text size")
                        }
                        .frame(maxWidth: 175)
                        .liquidGlassHover()
                        Text(preferences.lyricsSize, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .frame(minWidth: 46)
                        Button("Reset") { preferences.lyricsSize = 1 }
                            .liquidGlassHover()
                            .disabled(preferences.lyricsSize == 1)
                    }
                    .id(PreferencesItem.lyricsSize)
                    Toggle(PreferencesItem.lyricsBlur.title, isOn: $preferences.lyricsBlur)
                        .liquidGlassHover()
                        .id(PreferencesItem.lyricsBlur)
                }
                Section("Lyrics timing") {
                    LabeledContent("All songs") {
                        Slider(value: $preferences.lyricsOffset, in: -2...2, step: 0.05) {
                            Text("Lyrics timing")
                        }
                        .frame(maxWidth: 175)
                        .liquidGlassHover()
                        Text(timingLabel(preferences.lyricsOffset))
                            .monospacedDigit()
                            .frame(minWidth: 82)
                        Button("Reset") { preferences.lyricsOffset = 0 }
                            .liquidGlassHover()
                            .disabled(preferences.lyricsOffset == 0)
                    }
                    .id(PreferencesItem.lyricsTiming)
                }
            }
            .formStyle(.grouped)
        case .localLibrary:
            LibraryPreferences(state: state)
        case .keyboardShortcuts:
            Form {
                ForEach(ShortcutGroup.allCases) { group in
                    Section {
                        ForEach(AppShortcut.allCases.filter { $0.group == group }) { shortcut in
                            LabeledContent(shortcut.title, value: shortcut.hint)
                        }
                    } header: {
                        Text(group.title)
                    }
                }
            }
            .formStyle(.grouped)
            .id(PreferencesItem.keyboardShortcuts)
        case .storage:
            CachePreferences(library: state.library)
        case .about:
            Form {
                Section("App") {
                    LabeledContent(PreferencesItem.version.title, value: ApplicationMetadata.version)
                        .id(PreferencesItem.version)
                    LabeledContent(PreferencesItem.bundleVersion.title, value: ApplicationMetadata.bundleVersion)
                        .id(PreferencesItem.bundleVersion)
                    if let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil) {
                        LicenseDisclosure(url: url)
                            .id(PreferencesItem.license)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func timingLabel(_ offset: Double) -> String {
        guard offset != 0 else { return String(localized: "In sync") }
        let magnitude = abs(offset).formatted(.number.precision(.fractionLength(2)))
        return offset < 0 ? String(localized: "\(magnitude) s earlier") : String(localized: "\(magnitude) s later")
    }
}

private struct LibraryPreferences: View {
    @Bindable var state: AppState
    @State private var removing: LibrarySource?
    @State private var confirmingClear = false
    @State private var showingIssues = false

    var body: some View {
        @Bindable var preferences = state.preferences
        let library = state.library
        Form {
            Section("Display") {
                Picker(PreferencesItem.defaultView.title, selection: $preferences.defaultView) {
                    ForEach(LibraryDefaultView.allCases) { view in Text(view.title).tag(view) }
                }
                .liquidGlassHover()
                .id(PreferencesItem.defaultView)
                Picker(PreferencesItem.audioQuality.title, selection: $preferences.audioQuality) {
                    ForEach(QualityDisplay.allCases) { style in Text(style.title).tag(style) }
                }
                .liquidGlassHover()
                .id(PreferencesItem.audioQuality)
                Picker(PreferencesItem.songTap.title, selection: $preferences.songTap) {
                    ForEach(SongTap.allCases) { action in Text(action.title).tag(action) }
                }
                .liquidGlassHover()
                .id(PreferencesItem.songTap)
            }
            Section("Scan Settings") {
                Picker(PreferencesItem.autoScan.title, selection: $preferences.autoScan) {
                    ForEach(AutoScan.allCases) { policy in Text(policy.title).tag(policy) }
                }
                .liquidGlassHover()
                .id(PreferencesItem.autoScan)
            }
            Section("Folders") {
                ForEach(library.sources) { source in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.name)
                            Text(source.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Text("\(source.status.title) · Tracks: \(source.trackCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            removing = source
                        } label: {
                            Label("Remove library folder", systemImage: "minus.circle")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .liquidGlassHover()
                    }
                }
                Button(PreferencesItem.addFolder.title, systemImage: "plus") {
                    state.chooseFiles(folder: true, appendSource: true)
                }
                .liquidGlassHover()
                .id(PreferencesItem.addFolder)
            }
            Section("Scan Status") {
                LabeledContent("Last scanned") {
                    if let date = library.lastCompletedScan ?? preferences.lastScan {
                        Text(date, style: .relative)
                    } else {
                        Text("Never")
                    }
                }
                .id(PreferencesItem.scanStatus)
                if library.isScanning {
                    if let progress = library.scanProgress {
                        ProgressView(value: Double(progress.completedSources), total: Double(max(1, progress.totalSources))) {
                            Text(library.isScanPaused ? String(localized: "Paused") : progress.currentSourceName ?? String(localized: "Scanning…"))
                        } currentValueLabel: {
                            Text("Files checked: \(progress.checkedFiles)")
                        }
                    } else {
                        ProgressView("Scanning…")
                    }
                    HStack {
                        Button(library.isScanPaused ? String(localized: "Resume") : String(localized: "Pause")) {
                            if library.isScanPaused {
                                library.resumeScan()
                            } else {
                                library.pauseScan()
                            }
                        }
                        .liquidGlassHover()
                        Button("Cancel") { library.cancelScan() }
                            .liquidGlassHover()
                    }
                }
                if let error = library.scanError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
                LabeledContent(PreferencesItem.unreadableFiles.title) {
                    Text(library.scanIssues.count.formatted())
                        .monospacedDigit()
                    Button("Show") { showingIssues = true }
                        .accessibilityLabel("Show unreadable files")
                        .liquidGlassHover()
                        .disabled(library.scanIssues.isEmpty)
                }
                .id(PreferencesItem.unreadableFiles)
            }
            Section("Actions") {
                Group {
                    Button(PreferencesItem.scanLibrary.title) { Task { await state.scan() } }
                        .liquidGlassHover()
                        .id(PreferencesItem.scanLibrary)
                    Button(PreferencesItem.forceScan.title) { Task { await state.scan(force: true) } }
                        .liquidGlassHover()
                        .id(PreferencesItem.forceScan)
                    Button(PreferencesItem.cleanupMissing.title) { Task { await library.cleanupMissingFiles() } }
                        .liquidGlassHover()
                        .id(PreferencesItem.cleanupMissing)
                }
                .disabled(library.sources.isEmpty || library.isScanning)
                Button(PreferencesItem.clearLibrary.title, role: .destructive) { confirmingClear = true }
                    .liquidGlassHover()
                    .disabled(!library.hasIndexedTracks)
                    .id(PreferencesItem.clearLibrary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove library folder", isPresented: Binding(
            get: { removing != nil },
            set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible, presenting: removing) { source in
            Button("Remove", role: .destructive) { state.library.removeSource(source) }
        } message: { source in
            Text("Remove access to \(source.name) and its indexed tracks?")
        }
        .confirmationDialog("Clear Library", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { state.library.clearIndex() }
        } message: {
            Text("Remove all indexed tracks. Your music files stay on disk.")
        }
        .sheet(isPresented: $showingIssues) {
            VStack(alignment: .leading, spacing: 12) {
                Text(PreferencesItem.unreadableFiles.title)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                List(library.scanIssues) { issue in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.url.lastPathComponent)
                        Text(issue.url.path)
                            .textSelection(.enabled)
                        Text(issue.localizedMessage)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Button("Done") { showingIssues = false }
                    .keyboardShortcut(.defaultAction)
                    .liquidGlassHover()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(20)
            .frame(minWidth: 460, idealWidth: 620, minHeight: 320, idealHeight: 440)
        }
    }
}

private struct CachePreferences: View {
    let library: LibraryStore
    @State private var confirmingClear = false

    var body: some View {
        Form {
            Section("Cached Data") {
                LabeledContent("Library cover cache") {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(library.artworkCacheBytes), countStyle: .memory))
                }
                .id(PreferencesItem.coverCache)
                LabeledContent("Images", value: library.artworkCacheCount.formatted())
                Button("Clear", role: .destructive) { confirmingClear = true }
                    .liquidGlassHover()
                    .disabled(library.artworkCacheCount == 0)
                    .id(PreferencesItem.clearCache)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear cache?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { library.clearArtworkCache() }
        }
    }
}

private struct LicenseDisclosure: View {
    let url: URL
    @State private var showingLicense = false

    var body: some View {
        Button(PreferencesItem.license.title) { showingLicense = true }
            .liquidGlassHover()
            .sheet(isPresented: $showingLicense) {
                VStack(alignment: .trailing, spacing: 12) {
                    ScrollView {
                        Text((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button("Done") { showingLicense = false }
                        .keyboardShortcut(.defaultAction)
                        .liquidGlassHover()
                }
                .padding(20)
                .frame(minWidth: 560, idealWidth: 650, minHeight: 400, idealHeight: 540)
            }
    }
}
