import AppKit
import EasyPicCore

/// Keep AppKit's live window list while combining the standard View/Window menus.
@MainActor final class ApplicationMenuLayout {
    private var observers: [NSObjectProtocol] = []
    private var queued = false
    private var repairing = false
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    func start() {
        guard observers.isEmpty else { return }
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification, UserDefaults.didChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule() }
            })
        }
        schedule()
    }
    func schedule() {
        guard !queued, !repairing else { return }
        queued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.queued = false; self.mergeMenus()
        }
    }
    private func mergeMenus() {
        guard let main = NSApp.mainMenu,
              let windowItem = main.items.first(where: { $0.submenu != nil && $0.submenu === NSApp.windowsMenu }) ??
                main.items.first(where: { ["Window", "Windows", "窗口", "View & Window", "视图与窗口"].contains($0.title) }),
              let window = windowItem.submenu else { return }
        repairing = true; defer { repairing = false }
        if let viewItem = main.items.first(where: { ["View", "视图", "显示"].contains($0.title) && $0 !== windowItem }),
           let view = viewItem.submenu {
            var insertion = 0
            for item in view.items {
                view.removeItem(item)
                if item.isSeparatorItem {
                    if insertion > 0, !window.item(at: insertion - 1)!.isSeparatorItem {
                        window.insertItem(item, at: insertion); insertion += 1
                    }
                    continue
                }
                let duplicate = window.items.contains {
                    (!$0.keyEquivalent.isEmpty && $0.keyEquivalent == item.keyEquivalent && $0.keyEquivalentModifierMask == item.keyEquivalentModifierMask) ||
                    ($0.title == item.title && $0.action == item.action)
                }
                if !duplicate { window.insertItem(item, at: insertion); insertion += 1 }
            }
            if insertion > 0, insertion < window.numberOfItems,
               !window.item(at: insertion - 1)!.isSeparatorItem, !window.item(at: insertion)!.isSeparatorItem {
                window.insertItem(.separator(), at: insertion)
            }
            main.removeItem(viewItem)
        }
        let title = L10n.text("视图与窗口")
        if windowItem.title != title { windowItem.title = title }
        if window.title != title { window.title = title }
    }
}
