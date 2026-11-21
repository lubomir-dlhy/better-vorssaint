// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Vorst's own identity. Tools/vorst/rebrand.py skips this file, so the
/// upstream credit keeps its original name.
enum VorstBrand {
    static let name = "Vorst"
    static let credit = "Based on Vorssaint by Vorssaint · GPL-3.0-or-later"
    static let legacyBundleID = "com.vorssaint.utils.dev"

    /// Keys that describe a fan session owned by the legacy app's helper. A new
    /// bundle ID has its own helper, so carrying them over would only block it.
    private static let legacyFanSessionKeys = [
        DefaultsKey.fanControlRecoveryNeeded,
        DefaultsKey.fanControlHelperVersion,
    ]

    /// Moves settings and app data from the earlier bundle ID on the first launch
    /// under the new one, then never again.
    static func migrateLegacyInstallIfNeeded(defaults: UserDefaults = .standard,
                                             fileManager: FileManager = .default) {
        guard let bundleID = Bundle.main.bundleIdentifier, bundleID != legacyBundleID,
              defaults.persistentDomain(forName: bundleID)?.isEmpty ?? true,
              var legacy = defaults.persistentDomain(forName: legacyBundleID), !legacy.isEmpty
        else { return }
        legacyFanSessionKeys.forEach { legacy.removeValue(forKey: $0) }
        defaults.setPersistentDomain(legacy, forName: bundleID)
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return }
        let source = support.appendingPathComponent(legacyBundleID, isDirectory: true)
        let destination = support.appendingPathComponent(bundleID, isDirectory: true)
        if fileManager.fileExists(atPath: source.path), !fileManager.fileExists(atPath: destination.path) {
            try? fileManager.copyItem(at: source, to: destination)
        }
    }
}
