//
//  MenuBarItemImageCache.swift
//  Ice
//

import Cocoa
import Combine

/// Cache for menu bar item images.
final class MenuBarItemImageCache: ObservableObject {
    /// The cached item images.
    @Published private(set) var images = [MenuBarItemInfo: CGImage]()

    /// The screen of the cached item images.
    private(set) var screen: NSScreen?

    /// The height of the menu bar of the cached item images.
    private(set) var menuBarHeight: CGFloat?

    /// The shared app state.
    private weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// Creates a cache with the given app state.
    init(appState: AppState) {
        self.appState = appState
    }

    /// Sets up the cache.
    @MainActor
    func performSetup() {
        configureCancellables()
    }

    /// Configures the internal observers for the cache.
    @MainActor
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        if let appState {
            Publishers.Merge3(
                // Update every 3 seconds at minimum.
                Timer.publish(every: 3, on: .main, in: .default).autoconnect().mapToVoid(),

                // Update when the active space or screen parameters change.
                Publishers.Merge(
                    NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification),
                    NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
                )
                .mapToVoid(),

                // Update when the average menu bar color or cached items change.
                Publishers.Merge(
                    appState.menuBarManager.$averageColorInfo.removeDuplicates().mapToVoid(),
                    appState.itemManager.$itemCache.removeDuplicates().mapToVoid()
                )
            )
            .throttle(for: 0.5, scheduler: DispatchQueue.main, latest: false)
            .sink { [weak self] in
                guard let self else {
                    return
                }
                Task.detached {
                    await self.updateCache()
                }
            }
            .store(in: &c)
        }

        cancellables = c
    }

    /// Returns a Boolean value that indicates whether the cache contains at least _some_
    /// images for the given section.
    @MainActor
    func hasImages(for section: MenuBarSection.Name) -> Bool {
        let items = appState?.itemManager.itemCache.allItems(for: section) ?? []
        return !Set(items.map { $0.info }).isDisjoint(with: images.keys)
    }

    /// Captures the images of the current menu bar items and returns a dictionary containing
    /// the images, keyed by the current menu bar item infos.
    func createImages(for section: MenuBarSection.Name, screen: NSScreen) async -> [MenuBarItemInfo: CGImage] {
        guard let appState else {
            return [:]
        }

        let items = await appState.itemManager.itemCache.allItems(for: section)

        var images = [MenuBarItemInfo: CGImage]()
        let backingScaleFactor = screen.backingScaleFactor
        let displayBounds = CGDisplayBounds(screen.displayID)
        let option: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]
        let defaultItemThickness = NSStatusBar.system.thickness * backingScaleFactor

        var itemInfos = [CGWindowID: MenuBarItemInfo]()
        var itemFrames = [CGWindowID: CGRect]()
        var windowIDs = [CGWindowID]()
        var frame = CGRect.null

        for item in items {
            let windowID = item.windowID
            guard
                // Use the most up-to-date window frame.
                let itemFrame = Bridging.getWindowFrame(for: windowID),
                itemFrame.minY == displayBounds.minY
            else {
                continue
            }
            itemInfos[windowID] = item.info
            itemFrames[windowID] = itemFrame
            windowIDs.append(windowID)
            frame = frame.union(itemFrame)
        }

        if
            let compositeImage = ScreenCapture.captureWindows(windowIDs, option: option),
            CGFloat(compositeImage.width) == frame.width * backingScaleFactor
        {
            for windowID in windowIDs {
                guard
                    let itemInfo = itemInfos[windowID],
                    let itemFrame = itemFrames[windowID]
                else {
                    continue
                }

                let frame = CGRect(
                    x: (itemFrame.origin.x - frame.origin.x) * backingScaleFactor,
                    y: (itemFrame.origin.y - frame.origin.y) * backingScaleFactor,
                    width: itemFrame.width * backingScaleFactor,
                    height: itemFrame.height * backingScaleFactor
                )

                guard let itemImage = compositeImage.cropping(to: frame) else {
                    continue
                }

                images[itemInfo] = itemImage
            }
        } else {
            Logger.imageCache.warning("Composite image capture failed. Attempting to capturing items individually.")

            for windowID in windowIDs {
                guard
                    let itemInfo = itemInfos[windowID],
                    let itemFrame = itemFrames[windowID]
                else {
                    continue
                }

                let frame = CGRect(
                    x: 0,
                    y: ((itemFrame.height * backingScaleFactor) / 2) - (defaultItemThickness / 2),
                    width: itemFrame.width * backingScaleFactor,
                    height: defaultItemThickness
                )

                guard
                    let itemImage = ScreenCapture.captureWindow(windowID, option: option),
                    let croppedImage = itemImage.cropping(to: frame)
                else {
                    continue
                }

                images[itemInfo] = croppedImage
            }
        }

        return images
    }

    /// Updates the cache with the current menu bar item images, without checking whether
    /// caching is necessary.
    func updateCacheWithoutChecks(sections: [MenuBarSection.Name]) async {
        actor Context {
            var images = [MenuBarItemInfo: CGImage]()

            func merge(_ other: [MenuBarItemInfo: CGImage]) {
                images.merge(other) { (_, new) in new }
            }
        }

        guard
            let appState,
            let screen = NSScreen.main
        else {
            return
        }

        let context = Context()

        for section in sections {
            guard await !appState.itemManager.itemCache.allItems(for: section).isEmpty else {
                continue
            }
            let sectionImages = await createImages(for: section, screen: screen)
            guard !sectionImages.isEmpty else {
                Logger.imageCache.warning("Update image cache failed for \(section.logString)")
                continue
            }
            await context.merge(sectionImages)
        }

        let task = Task { @MainActor in
            self.images = await context.images
        }
        await task.value

        self.screen = screen
        self.menuBarHeight = screen.getMenuBarHeight()
    }

    /// Updates the cache with the current menu bar item images, if necessary.
    func updateCache() async {
        guard let appState else {
            return
        }

        let isIceBarPresented = await appState.navigationState.isIceBarPresented
        let isSearchPresented = await appState.navigationState.isSearchPresented
        let isSettingsPresented: Bool

        if !isIceBarPresented && !isSearchPresented {
            guard await appState.navigationState.isAppFrontmost else {
                Logger.imageCache.debug("Skipping image cache as Ice Bar not visible, app not frontmost")
                return
            }

            isSettingsPresented = await appState.navigationState.isSettingsPresented

            guard isSettingsPresented else {
                Logger.imageCache.debug("Skipping image cache as Ice Bar not visible, Settings not visible")
                return
            }

            guard case .menuBarLayout = await appState.navigationState.settingsNavigationIdentifier else {
                Logger.imageCache.debug("Skipping image cache as Ice Bar not visible, Settings visible but not on Menu Bar Layout pane")
                return
            }
        } else {
            isSettingsPresented = await appState.navigationState.isSettingsPresented
        }

        if let lastItemMoveStartDate = await appState.itemManager.lastItemMoveStartDate {
            guard Date.now.timeIntervalSince(lastItemMoveStartDate) > 3 else {
                Logger.imageCache.debug("Skipping image cache as an item was recently moved")
                return
            }
        }

        var sectionsNeedingDisplay = [MenuBarSection.Name]()
        if isSettingsPresented || isSearchPresented {
            sectionsNeedingDisplay = MenuBarSection.Name.allCases
        } else if
            isIceBarPresented,
            let section = await appState.menuBarManager.iceBarPanel.currentSection
        {
            sectionsNeedingDisplay.append(section)
        }

        await updateCacheWithoutChecks(sections: sectionsNeedingDisplay)
    }
}

// MARK: - Logger
private extension Logger {
    static let imageCache = Logger(category: "MenuBarItemImageCache")
}
