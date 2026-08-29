//
//  PluginPreferences.swift
//  AtollPluginManager
//
//  Persists which discovered plugins the user has disabled. Discovery finds
//  everything with a manifest; this is a separate, local opt-out on top of
//  that — disabling a plugin here doesn't touch its manifest.
//

import Foundation

enum PluginPreferences {
    private static let disabledPluginIDsKey = "disabledPluginIDs"

    static func disabledPluginIDs() -> Set<String> {
        let stored = UserDefaults.standard.array(forKey: disabledPluginIDsKey) as? [String] ?? []
        return Set(stored)
    }

    static func setDisabledPluginIDs(_ ids: Set<String>) {
        UserDefaults.standard.set(Array(ids), forKey: disabledPluginIDsKey)
    }

    static func setEnabled(_ enabled: Bool, for pluginID: String) {
        var ids = disabledPluginIDs()
        if enabled {
            ids.remove(pluginID)
        } else {
            ids.insert(pluginID)
        }
        setDisabledPluginIDs(ids)
    }
}
