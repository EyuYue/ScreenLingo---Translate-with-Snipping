import Cocoa

// Only the currently running bundle is moved. Never accept a filesystem path from JS,
// invoke a shell, or remove the installation folder / previous-version backups.
@MainActor
extension AppController {
    func beginUninstall() throws {
        guard !isUninstalling, task == nil, !isCapturing, !confirmingFullScreenCapture,
              window.attachedSheet == nil else {
            throw AppError.message("请先结束当前操作，再卸载。")
        }
        let appURL = Bundle.main.bundleURL.standardizedFileURL
        let values = try appURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard appURL.pathExtension == "app", values.isDirectory == true,
              values.isSymbolicLink != true, Bundle(url: appURL)?.bundleIdentifier == "local.screenlingo.app" else {
            throw AppError.message("未找到可卸载的 ScreenLingo 应用，请从已安装的应用中打开设置。")
        }

        showWindow()
        isUninstalling = true
        registerFullScreenHotkey()
        emit(["type": "uninstalling", "value": true])

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "卸载 ScreenLingo？"
        alert.informativeText = "确认后将当前应用移入废纸篓并退出。默认保留本机设置和 API Key；不会删除下载的安装包、旧版备份或其他文件。\n\n应用位置：\n" + appURL.path
        let cancel = alert.addButton(withTitle: "取消")
        cancel.keyEquivalent = "\r"
        let uninstall = alert.addButton(withTitle: "卸载")
        uninstall.keyEquivalent = ""
        uninstall.hasDestructiveAction = true
        let removeData = NSButton(checkboxWithTitle: "同时清除本机设置和 API Key", target: nil, action: nil)
        removeData.state = .off
        removeData.sizeToFit()
        removeData.toolTip = "仅删除 ScreenLingo 的本机设置和钥匙串条目；不会撤销服务商端的 API Key。"
        alert.accessoryView = removeData
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self = self else { return }
            guard response == .alertSecondButtonReturn else {
                self.endUninstallAttempt("已取消卸载。", kind: "info")
                return
            }
            self.recycleApplication(at: appURL, removeData: removeData.state == .on)
        }
    }

    private func recycleApplication(at appURL: URL, removeData: Bool) {
        // Apple's Finder-style Trash operation; never fall back to permanent deletion.
        // Clean data only AFTER a successful move, so a failed move preserves settings.
        NSWorkspace.shared.recycle([appURL]) { [weak self] moved, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard moved[appURL] != nil else {
                    let detail = error?.localizedDescription ?? "系统未确认应用已移入废纸篓。"
                    self.endUninstallAttempt("卸载未完成，本机设置和 API Key 未清除。\n" + detail, kind: "error")
                    return
                }
                var warnings: [String] = []
                if let error = error { warnings.append(error.localizedDescription) }
                if removeData {
                    do { try self.credentials.deleteAll() }
                    catch { warnings.append(error.localizedDescription) }
                    do { try self.removeLocalSettings() }
                    catch { warnings.append("本机设置未完全清除：" + error.localizedDescription) }
                }
                self.finishUninstall(warnings: warnings)
            }
        }
    }

    private func removeLocalSettings() throws {
        // Remove only our settings file and preference domain, not a recursive directory.
        if fm.fileExists(atPath: supportDirectory.path) {
            let values = try supportDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw AppError.message("设置目录不是普通文件夹，未自动处理：" + supportDirectory.path)
            }
            if fm.fileExists(atPath: settingsURL.path) {
                let file = try settingsURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard file.isRegularFile == true || file.isSymbolicLink == true else {
                    throw AppError.message("设置文件类型异常，未自动处理：" + settingsURL.path)
                }
                try fm.removeItem(at: settingsURL)
            }
        }
        window.setFrameAutosaveName("")
        UserDefaults.standard.removePersistentDomain(forName: "local.screenlingo.app")
    }

    private func endUninstallAttempt(_ text: String, kind: String) {
        isUninstalling = false
        registerFullScreenHotkey()
        refreshStatusMenu()
        emit(["type": "uninstalling", "value": false])
        setStatus(text, kind: kind)
    }

    private func finishUninstall(warnings: [String]) {
        bubble.hide()
        overlay.dismiss()
        guard !warnings.isEmpty else {
            isUninstalling = false
            NSApp.terminate(nil)
            return
        }
        // Do not silently claim a full cleanup if Keychain or filesystem access failed.
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "应用已移入废纸篓"
        alert.informativeText = "以下项目仍需手动处理：\n\n" + warnings.joined(separator: "\n")
        alert.addButton(withTitle: "退出")
        alert.beginSheetModal(for: window) { [weak self] _ in
            self?.isUninstalling = false
            NSApp.terminate(nil)
        }
    }
}
