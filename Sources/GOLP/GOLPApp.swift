import AppKit
import Carbon
import CoreServices
import SwiftUI

private enum AppConstants {
    static let appName = "06GOLP"
    static let columns = 7
    static let rows = 4
    static let horizontalInset: CGFloat = 32
    static let itemMinWidth: CGFloat = 136
    static let itemHeight: CGFloat = 154
    static let iconSize: CGFloat = 104
    static let folderIconSize: CGFloat = 88
    static let selectionSize: CGFloat = 126
    static let selectionCornerRadius: CGFloat = 47
    static let itemSpacing: CGFloat = 58
    static let searchTopOffset: CGFloat = 120
    static let searchWidth: CGFloat = 460
    static let searchHeight: CGFloat = 48
    static let pageSwipeThreshold: CGFloat = 110
    static let pageAnimation = Animation.spring(response: 0.49, dampingFraction: 0.79, blendDuration: 0)
    static let pageSize = columns * rows
    static let gridWidth = CGFloat(columns) * itemMinWidth + CGFloat(columns - 1) * itemSpacing
    static let gridHeight = CGFloat(rows) * itemHeight + CGFloat(rows - 1) * itemSpacing
}

struct LaunchableApp: Identifiable, Equatable {
    let id: String
    let name: String
    let url: URL
    let icon: NSImage
}

struct LaunchFolder: Identifiable, Equatable {
    let id: String
    let name: String
    let apps: [LaunchableApp]
}

enum LaunchpadItem: Identifiable, Equatable {
    case app(LaunchableApp)
    case folder(LaunchFolder)

    var id: String {
        switch self {
        case .app(let app):
            return "app:\(app.id)"
        case .folder(let folder):
            return "folder:\(folder.id)"
        }
    }
}

@MainActor
final class AppCatalog: ObservableObject {
    @Published private(set) var items: [LaunchpadItem] = []
    @Published private(set) var allApps: [LaunchableApp] = []
    private var hasLoaded = false

    func reloadIfNeeded() {
        guard !hasLoaded else { return }
        reload()
    }

    func reload() {
        let searchRoots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true)
        ]

        var seen = Set<String>()
        var discovered: [LaunchableApp] = []
        var folderAppsByURL: [URL: [LaunchableApp]] = [:]
        var folderNamesByURL: [URL: String] = [:]

        for root in searchRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isApplicationKey, .localizedNameKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            for case let url as URL in enumerator where url.pathExtension == "app" {
                let canonicalPath = url.resolvingSymlinksInPath().path
                guard seen.insert(canonicalPath).inserted else { continue }

                let displayName = localizedAppName(for: url)
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: AppConstants.iconSize, height: AppConstants.iconSize)

                discovered.append(
                    LaunchableApp(
                        id: canonicalPath,
                        name: displayName,
                        url: url,
                        icon: icon
                    )
                )

                if let folderURL = containingFolder(for: url, under: root) {
                    folderAppsByURL[folderURL, default: []].append(discovered[discovered.count - 1])
                    folderNamesByURL[folderURL] = localizedFolderName(for: folderURL)
                }
            }
        }

        let dateCache = Dictionary(
            uniqueKeysWithValues: discovered.map { ($0.id, lastUsedDate(for: $0.url)) }
        ) as [String: Date?]

        let sortedApps = discovered.sorted { byRecency($0, $1, dates: dateCache) }

        let folders = folderAppsByURL.map { folderURL, apps in
            LaunchFolder(
                id: folderURL.path,
                name: folderNamesByURL[folderURL] ?? folderURL.lastPathComponent,
                apps: apps.sorted { byRecency($0, $1, dates: dateCache) }
            )
        }
        .filter { $0.apps.count > 1 }
        .sorted { a, b in
            let da = a.apps.compactMap { dateCache[$0.id] ?? nil }.max()
            let db = b.apps.compactMap { dateCache[$0.id] ?? nil }.max()
            switch (da, db) {
            case (let x?, let y?): return x > y
            case (nil, _?):        return false
            case (_?, nil):        return true
            case (nil, nil):       return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }

        let folderContainedAppIDs = Set(folders.flatMap { $0.apps.map(\.id) })

        let standaloneApps = sortedApps.filter { !folderContainedAppIDs.contains($0.id) }

        let allItems: [LaunchpadItem] = (folders.map(LaunchpadItem.folder) + standaloneApps.map(LaunchpadItem.app))
        items = allItems.sorted { lhs, rhs in
            let dl = itemDate(lhs, dates: dateCache)
            let dr = itemDate(rhs, dates: dateCache)
            switch (dl, dr) {
            case (let x?, let y?): return x > y
            case (nil, _?):        return false
            case (_?, nil):        return true
            case (nil, nil):       return sortName(for: lhs).localizedStandardCompare(sortName(for: rhs)) == .orderedAscending
            }
        }
        allApps = sortedApps
        hasLoaded = true
    }

    private func localizedAppName(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.localizedNameKey])
        if let localizedName = values?.localizedName, !localizedName.isEmpty {
            return localizedName.replacingOccurrences(of: ".app", with: "")
        }

        return url.deletingPathExtension().lastPathComponent
    }

    private func localizedFolderName(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.localizedNameKey])
        return values?.localizedName ?? url.lastPathComponent
    }

    private func containingFolder(for appURL: URL, under root: URL) -> URL? {
        let rootPath = root.standardizedFileURL.path
        let appPath = appURL.standardizedFileURL.path
        guard appPath.hasPrefix(rootPath + "/") else { return nil }

        let relative = String(appPath.dropFirst(rootPath.count + 1))
        let components = relative.split(separator: "/").map(String.init)
        guard components.count > 1, let first = components.first, !first.hasSuffix(".app") else {
            return nil
        }

        return root.appendingPathComponent(first, isDirectory: true)
    }

    private func lastUsedDate(for url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    private func byRecency(_ a: LaunchableApp, _ b: LaunchableApp, dates: [String: Date?]) -> Bool {
        switch (dates[a.id] ?? nil, dates[b.id] ?? nil) {
        case (let x?, let y?): return x > y
        case (nil, _?):        return false
        case (_?, nil):        return true
        case (nil, nil):       return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private func itemDate(_ item: LaunchpadItem, dates: [String: Date?]) -> Date? {
        switch item {
        case .app(let app):       return dates[app.id] ?? nil
        case .folder(let folder): return folder.apps.compactMap { dates[$0.id] ?? nil }.max()
        }
    }

    private func sortName(for item: LaunchpadItem) -> String {
        switch item {
        case .app(let app):    return app.name
        case .folder(let folder): return folder.name
        }
    }
}

@MainActor
final class LaunchpadController: NSObject, ObservableObject {
    let catalog = AppCatalog()

    private var windows: [NSWindow] = []
    private var hotKeyController: HotKeyController?
    private var statusItem: NSStatusItem?
    private var lastPage = 0
    private var lastClosedAt = Date.distantPast
    private var isShowing = false
    private weak var primaryWindow: NSWindow?
    private var screenSignature = ""

    func start() {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        hotKeyController = HotKeyController { [weak self] in
            Task { @MainActor in
                self?.toggle()
            }
        }
        Task { @MainActor in
            catalog.reloadIfNeeded()
        }
    }

    func toggle() {
        isShowing ? hide() : show()
    }

    func show() {
        catalog.reloadIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        let initialPage = Date().timeIntervalSince(lastClosedAt) <= 10 ? lastPage : 0

        guard let primaryScreen = primaryScreen() else { return }
        let currentScreenSignature = screenSignature(for: NSScreen.screens, primaryScreen: primaryScreen)

        if windows.isEmpty || screenSignature != currentScreenSignature {
            rebuildWindows(primaryScreen: primaryScreen, initialPage: initialPage)
            screenSignature = currentScreenSignature
        }

        windows.forEach { $0.orderFront(nil) }
        primaryWindow?.makeKeyAndOrderFront(nil)
        isShowing = true
    }

    func hide() {
        windows.forEach { $0.orderOut(nil) }
        lastClosedAt = Date()
        isShowing = false
    }

    private func rebuildWindows(primaryScreen: NSScreen, initialPage: Int) {
        windows.forEach { $0.orderOut(nil) }

        primaryWindow = nil
        windows = NSScreen.screens.map { screen in
            let navigation = PageNavigation()
            let panelFrame = expandedScreenFrame(for: screen)
            let panel = LaunchpadWindow(
                contentRect: panelFrame,
                navigation: navigation,
                closeAction: { [weak self] in self?.hide() }
            )

            if screen == primaryScreen {
                let content = LaunchpadView(
                    catalog: catalog,
                    navigation: navigation,
                    initialPage: initialPage,
                    pageChangeAction: { [weak self] page in
                        self?.lastPage = page
                    },
                    closeAction: { [weak self] in self?.hide() }
                )
                panel.contentView = NSHostingView(rootView: content)
                panel.setFrame(panelFrame, display: true)
                panel.makeKeyAndOrderFront(nil)
                primaryWindow = panel
            } else {
                let content = LaunchpadBackdropView(closeAction: { [weak self] in self?.hide() })
                panel.contentView = NSHostingView(rootView: content)
                panel.setFrame(panelFrame, display: true)
                panel.orderFront(nil)
            }

            return panel
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let url = Bundle.main.url(forResource: "menubarIcon@2x", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = "06"
        }
        item.button?.toolTip = "06GOLP"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open 06GOLP", action: #selector(openFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Refresh Apps", action: #selector(refreshAppsFromMenu), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit 06GOLP", action: #selector(quitFromMenu), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    private func primaryScreen() -> NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func expandedScreenFrame(for screen: NSScreen) -> NSRect {
        screen.frame.insetBy(dx: -12, dy: -12)
    }

    private func screenSignature(for screens: [NSScreen], primaryScreen: NSScreen) -> String {
        let screenFrames = screens
            .map { NSStringFromRect($0.frame) }
            .sorted()
            .joined(separator: "|")
        return "\(NSStringFromRect(primaryScreen.frame))|\(screenFrames)"
    }

    @objc private func openFromMenu() {
        show()
    }

    @objc private func refreshAppsFromMenu() {
        catalog.reload()
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }
}

final class LaunchpadWindow: NSPanel {
    private let navigation: PageNavigation
    private let closeAction: () -> Void
    private var horizontalScrollDelta: CGFloat = 0
    private var didNavigateDuringCurrentScroll = false
    private var lastGestureNavigationTime: TimeInterval = 0
    private var scrollUnlockWorkItem: DispatchWorkItem?
    private var eventMonitor: Any?

    init(contentRect: NSRect, navigation: PageNavigation, closeAction: @escaping () -> Void) {
        self.navigation = navigation
        self.closeAction = closeAction
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        installEventMonitor()
    }

    deinit {
        scrollUnlockWorkItem?.cancel()
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    private func installEventMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            guard let self, event.window === self else { return event }
            return self.handle(event)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown:
            switch Int(event.keyCode) {
            case kVK_Escape:
                closeAction()
                return nil
            case kVK_LeftArrow:
                navigation.requestPrevious()
                return nil
            case kVK_RightArrow:
                navigation.requestNext()
                return nil
            default:
                return event
            }
        case .scrollWheel:
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.deltaX
            guard abs(delta) > abs(event.scrollingDeltaY) else { return event }
            if event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended {
                horizontalScrollDelta = 0
                didNavigateDuringCurrentScroll = false
                return nil
            }

            guard !didNavigateDuringCurrentScroll else { return nil }
            horizontalScrollDelta += delta

            if horizontalScrollDelta <= -AppConstants.pageSwipeThreshold {
                navigateFromGesture(.next)
            } else if horizontalScrollDelta >= AppConstants.pageSwipeThreshold {
                navigateFromGesture(.previous)
            }
            return nil
        default:
            return event
        }
    }

    private func navigateFromGesture(_ direction: PageNavigation.Direction) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastGestureNavigationTime >= 0.72 else {
            return
        }

        lastGestureNavigationTime = now
        switch direction {
        case .previous:
            navigation.requestPrevious()
        case .next:
            navigation.requestNext()
        }
        lockCurrentScrollGesture()
    }

    private func lockCurrentScrollGesture() {
        horizontalScrollDelta = 0
        didNavigateDuringCurrentScroll = true

        scrollUnlockWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.horizontalScrollDelta = 0
            self?.didNavigateDuringCurrentScroll = false
        }
        scrollUnlockWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05, execute: workItem)
    }
}

@MainActor
final class PageNavigation: ObservableObject {
    enum Direction {
        case previous
        case next
    }

    @Published private(set) var commandID = 0
    private(set) var direction: Direction = .next
    private var lastCommandTime: TimeInterval = 0
    private let minimumCommandInterval: TimeInterval = 0.85

    func requestPrevious() {
        guard canSendCommand() else { return }
        direction = .previous
        commandID += 1
    }

    func requestNext() {
        guard canSendCommand() else { return }
        direction = .next
        commandID += 1
    }

    private func canSendCommand() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastCommandTime >= minimumCommandInterval else {
            return false
        }
        lastCommandTime = now
        return true
    }
}

final class HotKeyController {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        register()
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    private func register() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let controller = Unmanaged<HotKeyController>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                controller.action()
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandler
        )

        let hotKeyID = EventHotKeyID(signature: OSType("GOLP"), id: 1)
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }
}

private extension OSType {
    init(_ string: String) {
        self = string.utf8.reduce(0) { ($0 << 8) + OSType($1) }
    }
}

struct LaunchpadBackdrop: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            Rectangle()
                .fill(.clear)
                .glassEffect(.clear, in: .rect)
                .opacity(0.5)
                .glassEffect(.clear, in: .rect)
                .ignoresSafeArea()
            Color.black.opacity(0.35)
                .ignoresSafeArea()
        } else {
            Color.black.opacity(0.80)
                .ignoresSafeArea()
        }
    }
}

struct LaunchpadBackdropView: View {
    let closeAction: () -> Void

    var body: some View {
        ZStack {
            LaunchpadBackdrop()

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    closeAction()
                }
                .ignoresSafeArea()
        }
    }
}

struct LaunchpadView: View {
    @ObservedObject var catalog: AppCatalog
    @ObservedObject var navigation: PageNavigation
    let initialPage: Int
    let pageChangeAction: (Int) -> Void
    let closeAction: () -> Void

    @State private var searchText = ""
    @State private var page: Int
    @State private var selectedFolder: LaunchFolder?
    @State private var focusSearch = false
    @State private var bounceOffset: CGFloat = 0

    init(
        catalog: AppCatalog,
        navigation: PageNavigation,
        initialPage: Int,
        pageChangeAction: @escaping (Int) -> Void,
        closeAction: @escaping () -> Void
    ) {
        self.catalog = catalog
        self.navigation = navigation
        self.initialPage = initialPage
        self.pageChangeAction = pageChangeAction
        self.closeAction = closeAction
        _page = State(initialValue: initialPage)
    }

    private var filteredItems: [LaunchpadItem] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return catalog.items
        }

        return catalog.allApps
            .filter { $0.name.localizedCaseInsensitiveContains(searchText) }
            .map(LaunchpadItem.app)
    }

    private var pageCount: Int {
        max(1, Int(ceil(Double(filteredItems.count) / Double(AppConstants.pageSize))))
    }

    private var itemPages: [[LaunchpadItem]] {
        guard !filteredItems.isEmpty else { return [[]] }
        return stride(from: 0, to: filteredItems.count, by: AppConstants.pageSize).map { start in
            let end = min(start + AppConstants.pageSize, filteredItems.count)
            return Array(filteredItems[start..<end])
        }
    }

    var body: some View {
        ZStack {
            LaunchpadBackdrop()

            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    if selectedFolder != nil {
                        selectedFolder = nil
                    } else {
                        closeAction()
                    }
                }
                .ignoresSafeArea()

            VStack {
                GlassSearchField(text: $searchText, focusTrigger: $focusSearch)
                    .frame(width: AppConstants.searchWidth, height: AppConstants.searchHeight)
                    .padding(.top, AppConstants.searchTopOffset)
                    .onChange(of: searchText) { _, _ in
                        moveToPage(0, direction: .previous)
                    }

                Spacer()
            }

            VStack(spacing: 34) {
                Spacer(minLength: 190)

                PageStrip(
                    pages: itemPages,
                    currentPage: min(page, pageCount - 1),
                    bounceOffset: bounceOffset,
                    openFolderAction: { folder in
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                            selectedFolder = folder
                        }
                    },
                    closeAction: closeAction
                )
                .frame(maxWidth: .infinity)

                PageControl(currentPage: min(page, pageCount - 1), pageCount: pageCount)

                Spacer(minLength: 54)
            }

            if selectedFolder != nil {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedFolder = nil
                        }
                    }
                    .transition(.opacity)
                    .zIndex(1)
            }

            if let selectedFolder {
                FolderOverlay(
                    folder: selectedFolder,
                    closeAction: {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                            self.selectedFolder = nil
                        }
                    },
                    launchAction: closeAction
                )
                .transition(.scale(scale: 0.88).combined(with: .opacity))
                .zIndex(2)
            }
        }
        .foregroundStyle(.white)
        .onAppear {
            page = min(page, pageCount - 1)
            pageChangeAction(page)
            focusSearch = true
        }
        .onExitCommand {
            if selectedFolder != nil {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                    selectedFolder = nil
                }
            } else {
                closeAction()
            }
        }
        .onMoveCommand { direction in
            switch direction {
            case .left:
                if page > 0 { moveToPage(page - 1, direction: .previous) }
                else { triggerEdgeBounce(.previous) }
            case .right:
                if page < pageCount - 1 { moveToPage(page + 1, direction: .next) }
                else { triggerEdgeBounce(.next) }
            default:
                break
            }
        }
        .onChange(of: navigation.commandID) { _, _ in
            switch navigation.direction {
            case .previous:
                if page > 0 { moveToPage(page - 1, direction: .previous) }
                else { triggerEdgeBounce(.previous) }
            case .next:
                if page < pageCount - 1 { moveToPage(page + 1, direction: .next) }
                else { triggerEdgeBounce(.next) }
            }
        }
        .onChange(of: page) { _, newPage in
            pageChangeAction(newPage)
        }
    }

    private func moveToPage(_ targetPage: Int, direction _: PageNavigation.Direction) {
        let clampedPage = min(max(0, targetPage), pageCount - 1)
        withAnimation(AppConstants.pageAnimation) {
            page = clampedPage
        }
    }

    private func triggerEdgeBounce(_ direction: PageNavigation.Direction) {
        let shift: CGFloat = direction == .previous ? 55 : -55
        withAnimation(.spring(response: 0.22, dampingFraction: 0.5)) {
            bounceOffset = shift
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(130))
            withAnimation(.spring(response: 0.40, dampingFraction: 0.75)) {
                bounceOffset = 0
            }
        }
    }
}

struct GlassSearchField: View {
    @Binding var text: String
    @Binding var focusTrigger: Bool

    var body: some View {
        WhiteSearchTextField(text: $text, focusTrigger: $focusTrigger)
            .padding(.horizontal, 24)
            .frame(height: AppConstants.searchHeight)
            .background {
                RoundedRectangle(cornerRadius: AppConstants.searchHeight / 2, style: .continuous)
                    .fill(.white.opacity(0.13))
                    .background {
                        RoundedRectangle(cornerRadius: AppConstants.searchHeight / 2, style: .continuous)
                            .fill(.white.opacity(0.06))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: AppConstants.searchHeight / 2, style: .continuous)
                            .stroke(.white.opacity(0.22), lineWidth: 1)
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: AppConstants.searchHeight / 2, style: .continuous))
    }
}

struct WhiteSearchTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var focusTrigger: Bool

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "Search"
        field.font = .systemFont(ofSize: 22, weight: .regular)
        field.textColor = .white
        field.delegate = context.coordinator
        configurePlaceholder(for: field)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.textColor = .white
        configurePlaceholder(for: nsView)
        if focusTrigger {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
                focusTrigger = false
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text = field.stringValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField,
                  let editor = field.currentEditor() as? NSTextView else { return }
            editor.textColor = .white
            editor.insertionPointColor = .white
        }
    }
}

private func configurePlaceholder(for field: NSTextField) {
    guard let cell = field.cell as? NSTextFieldCell else { return }
    cell.placeholderAttributedString = NSAttributedString(
        string: "Search",
        attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.62),
            .font: NSFont.systemFont(ofSize: 22, weight: .regular)
        ]
    )
}

struct PageStrip: View {
    let pages: [[LaunchpadItem]]
    let currentPage: Int
    let bounceOffset: CGFloat
    let openFolderAction: (LaunchFolder) -> Void
    let closeAction: () -> Void

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                ForEach(Array(pages.enumerated()), id: \.offset) { _, items in
                    AppGrid(
                        items: items,
                        openFolderAction: openFolderAction,
                        closeAction: closeAction
                    )
                    .frame(width: proxy.size.width)
                }
            }
            .frame(width: proxy.size.width * CGFloat(max(1, pages.count)), alignment: .leading)
            .offset(x: -CGFloat(currentPage) * proxy.size.width + bounceOffset)
            .animation(AppConstants.pageAnimation, value: currentPage)
        }
        .frame(height: AppConstants.gridHeight)
    }
}

struct AppGrid: View {
    let items: [LaunchpadItem]
    let openFolderAction: (LaunchFolder) -> Void
    let closeAction: () -> Void

    private let columns = Array(
        repeating: GridItem(.fixed(AppConstants.itemMinWidth), spacing: AppConstants.itemSpacing),
        count: AppConstants.columns
    )

    var body: some View {
        LazyVGrid(columns: columns, spacing: AppConstants.itemSpacing) {
            ForEach(items) { item in
                switch item {
                case .app(let app):
                    AppIconButton(app: app, closeAction: closeAction)
                case .folder(let folder):
                    FolderIconButton(folder: folder, openAction: openFolderAction)
                }
            }
        }
        .frame(width: AppConstants.gridWidth, height: AppConstants.gridHeight, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct AppIconButton: View {
    let app: LaunchableApp
    let closeAction: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.openApplication(
                at: app.url,
                configuration: NSWorkspace.OpenConfiguration()
            )
            closeAction()
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppConstants.selectionCornerRadius, style: .continuous)
                        .fill(isHovering ? Color.white.opacity(0.17) : Color.clear)

                    Image(nsImage: app.icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: AppConstants.iconSize, height: AppConstants.iconSize)
                        .shadow(color: .black.opacity(0.20), radius: 8, y: 4)
                }
                .frame(width: AppConstants.selectionSize, height: AppConstants.selectionSize)

                Text(app.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.white.opacity(isHovering ? 0.9 : 0))
                    .shadow(color: .black.opacity(isHovering ? 0.7 : 0), radius: 2, y: 1)
                    .frame(width: AppConstants.itemMinWidth, height: 16)
            }
            .frame(width: AppConstants.itemMinWidth, height: AppConstants.itemHeight)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

struct FolderIconButton: View {
    let folder: LaunchFolder
    let openAction: (LaunchFolder) -> Void
    @State private var isHovering = false

    private var previewApps: [LaunchableApp] {
        Array(folder.apps.prefix(9))
    }

    var body: some View {
        Button {
            openAction(folder)
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: AppConstants.selectionCornerRadius, style: .continuous)
                        .fill(isHovering ? Color.white.opacity(0.17) : Color.clear)

                    ZStack {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(.white.opacity(0.18))
                            .overlay {
                                RoundedRectangle(cornerRadius: 26, style: .continuous)
                                    .stroke(.white.opacity(0.30), lineWidth: 1.2)
                            }
                            .shadow(color: .black.opacity(0.20), radius: 8, y: 4)

                        LazyVGrid(
                            columns: Array(repeating: GridItem(.fixed(17), spacing: 4), count: 3),
                            alignment: .leading,
                            spacing: 4
                        ) {
                            ForEach(previewApps) { app in
                                Image(nsImage: app.icon)
                                    .resizable()
                                    .interpolation(.high)
                                    .frame(width: 17, height: 17)
                            }
                        }
                        .frame(width: 59, height: 59, alignment: .topLeading)
                    }
                    .frame(width: AppConstants.folderIconSize, height: AppConstants.folderIconSize)
                }
                .frame(width: AppConstants.selectionSize, height: AppConstants.selectionSize)

                Text(folder.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.white.opacity(isHovering ? 0.9 : 0))
                    .shadow(color: .black.opacity(isHovering ? 0.7 : 0), radius: 2, y: 1)
                    .frame(width: AppConstants.itemMinWidth, height: 16)
            }
            .frame(width: AppConstants.itemMinWidth, height: AppConstants.itemHeight)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

struct FolderOverlay: View {
    let folder: LaunchFolder
    let closeAction: () -> Void
    let launchAction: () -> Void
    private let spacing: CGFloat = 28

    private var columnCount: Int {
        folder.apps.count > 12 ? 5 : 4
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(AppConstants.itemMinWidth), spacing: spacing), count: columnCount)
    }

    private var gridWidth: CGFloat {
        CGFloat(columnCount) * AppConstants.itemMinWidth + CGFloat(columnCount - 1) * spacing
    }

    private var gridHeight: CGFloat {
        let rowCount = max(1, Int(ceil(Double(folder.apps.count) / Double(columnCount))))
        return CGFloat(rowCount) * AppConstants.itemHeight + CGFloat(max(0, rowCount - 1)) * spacing
    }

    var body: some View {
        VStack(spacing: 28) {
            LazyVGrid(columns: columns, spacing: spacing) {
                ForEach(folder.apps) { app in
                    AppIconButton(app: app, closeAction: launchAction)
                }
            }
            .frame(width: gridWidth, height: gridHeight, alignment: .topLeading)
            .padding(34)
            .frame(width: gridWidth + 68, height: gridHeight + 68, alignment: .topLeading)
            .background {
                if #available(macOS 26.0, *) {
                    RoundedRectangle(cornerRadius: 56, style: .continuous)
                        .fill(.clear)
                        .glassEffect(.clear, in: .rect(cornerRadius: 56))
                } else {
                    RoundedRectangle(cornerRadius: 56, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 56, style: .continuous)
                                .stroke(.white.opacity(0.14), lineWidth: 1.35)
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 56, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 6)

            Text(folder.name)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.white.opacity(0.92))
        }
        .padding(.horizontal, 56)
    }
}

struct PageControl: View {
    let currentPage: Int
    let pageCount: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<pageCount, id: \.self) { index in
                Circle()
                    .fill(index == currentPage ? Color.white.opacity(0.9) : Color.white.opacity(0.32))
                    .frame(width: 14, height: 14)
            }
        }
        .frame(height: 32)
    }
}


@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = LaunchpadController()

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }
}
