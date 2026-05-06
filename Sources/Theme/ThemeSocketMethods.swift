import Foundation

/// Socket handlers for the `theme.*` and `workspace.set_custom_color` method families.
///
/// Read-only `theme.list`, `theme.get`, `theme.paths`, `theme.dump`, `theme.validate`, `theme.diff`
/// are safe to call from unauthenticated clients. Mutating methods (`theme.set_active`,
/// `theme.clear_active`, `theme.reload`, `theme.inherit`, `workspace.set_custom_color`) must be
/// dispatched by the CLI after authentication (the socket layer already gates them).
///
/// All handlers parse/validate off the calling thread; the only main-actor hop is the minimal
/// state update (`ThemeManager.shared.setActiveTheme(...)` / `forceReloadUserThemes()`).
/// This keeps the socket focus policy intact — no commands below steal macOS focus.
public enum ThemeSocketMethods {

    public static let readOnlyMethods: Set<String> = [
        "theme.list",
        "theme.get",
        "theme.paths",
        "theme.dump",
        "theme.validate",
        "theme.diff"
    ]

    public static let mutatingMethods: Set<String> = [
        "theme.set_active",
        "theme.clear_active",
        "theme.reload",
        "theme.inherit",
        "workspace.set_custom_color"
    ]

    // MARK: - Read-only

    public static func list() -> [String: Any] {
        let descriptors = Self.mainSync { ThemeManager.shared.availableThemes }
        let lightName = Self.mainSync { ThemeManager.shared.activeLightName }
        let darkName = Self.mainSync { ThemeManager.shared.activeDarkName }

        let items: [[String: Any]] = descriptors.map { descriptor in
            var payload: [String: Any] = [
                "name": descriptor.identity.name,
                "display_name": descriptor.identity.displayName,
                "author": descriptor.identity.author,
                "version": descriptor.identity.version,
                "schema": descriptor.identity.schema,
                "source": descriptor.source.rawValue
            ]
            if let path = descriptor.sourcePath {
                payload["source_path"] = path
            }
            if let warning = descriptor.warning {
                payload["warning"] = warning
            }
            payload["is_active_light"] = descriptor.identity.name == lightName
            payload["is_active_dark"] = descriptor.identity.name == darkName
            return payload
        }

        return [
            "themes": items,
            "active_light": lightName,
            "active_dark": darkName
        ]
    }

    public static func get(params: [String: Any]) -> [String: Any] {
        let lightName = Self.mainSync { ThemeManager.shared.activeLightName }
        let darkName = Self.mainSync { ThemeManager.shared.activeDarkName }
        let slot = (params["slot"] as? String)?.lowercased()

        switch slot {
        case "light":
            return ["name": lightName, "slot": "light"]
        case "dark":
            return ["name": darkName, "slot": "dark"]
        default:
            return ["active_light": lightName, "active_dark": darkName]
        }
    }

    public static func paths(pathsOverride: ThemeManager.PathsOverride? = nil) -> [String: Any] {
        let userDir = ThemeManager.userThemesDirectory(override: pathsOverride)
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent(ThemeManager.bundledThemesDirectoryName, isDirectory: true)
            .path ?? "<bundled>"
        return [
            "user_themes_directory": userDir.path,
            "bundled_themes_directory": bundled
        ]
    }

    public static func dumpActive(params: [String: Any]) -> [String: Any] {
        let colorScheme: ThemeContext.ColorScheme
        switch (params["color_scheme"] as? String)?.lowercased() {
        case "light":
            colorScheme = .light
        case "dark":
            colorScheme = .dark
        default:
            colorScheme = Self.mainSync { ThemeManager.currentColorScheme() }
        }

        let json = Self.mainSync {
            let context = ThemeManager.shared.makeContext(colorScheme: colorScheme)
            return ThemeManager.shared.dumpActiveThemeJSON(context: context)
        }

        return ["dump_json": json]
    }

    public static func validate(params: [String: Any]) -> [String: Any] {
        guard let path = params["path"] as? String else {
            return ["ok": false, "error": "missing required parameter: path"]
        }
        let url = URL(fileURLWithPath: path)
        return validateURL(url)
    }

    public static func validateURL(_ url: URL) -> [String: Any] {
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            return ["ok": false, "error": "unable to read file: \(url.path)"]
        }

        do {
            let table = try TomlSubsetParser.parse(file: url.path, source: source)
            let theme = try C11muxTheme.fromToml(table)
            return [
                "ok": true,
                "name": theme.identity.name,
                "display_name": theme.identity.displayName,
                "schema": theme.identity.schema
            ]
        } catch {
            return ["ok": false, "error": String(describing: error)]
        }
    }

    public static func diff(params: [String: Any]) -> [String: Any] {
        guard let a = params["a"] as? String, let b = params["b"] as? String else {
            return ["ok": false, "error": "missing required parameters: a, b"]
        }

        let themeA = resolveThemeForDiff(nameOrPath: a)
        let themeB = resolveThemeForDiff(nameOrPath: b)

        guard let themeA else {
            return ["ok": false, "error": "theme or path not found: \(a)"]
        }
        guard let themeB else {
            return ["ok": false, "error": "theme or path not found: \(b)"]
        }

        let canonicalA = ThemeCanonicalizer.canonicalize(themeA)
        let canonicalB = ThemeCanonicalizer.canonicalize(themeB)
        let changedRoles = ThemeRole.allCases.filter { role in
            themeA.stringValue(for: role) != themeB.stringValue(for: role)
                || themeA.numberValue(for: role) != themeB.numberValue(for: role)
                || themeA.boolValue(for: role) != themeB.boolValue(for: role)
        }
        return [
            "ok": true,
            "a": themeA.identity.name,
            "b": themeB.identity.name,
            "identical": canonicalA == canonicalB,
            "changed_role_count": changedRoles.count,
            "changed_roles": changedRoles.map(\.definition.path)
        ]
    }

    // MARK: - Mutating

    public static func setActive(params: [String: Any]) -> [String: Any] {
        guard let name = params["name"] as? String else {
            return ["ok": false, "error": "missing required parameter: name"]
        }
        let slot = (params["slot"] as? String)?.lowercased() ?? "both"

        let ok: Bool = Self.mainSync {
            switch slot {
            case "light":
                return ThemeManager.shared.setActiveTheme(name: name, for: .light)
            case "dark":
                return ThemeManager.shared.setActiveTheme(name: name, for: .dark)
            case "both":
                return ThemeManager.shared.setActiveThemeForBothSlots(name: name)
            default:
                return false
            }
        }

        if !ok {
            return ["ok": false, "error": "unknown theme or invalid slot"]
        }
        return ["ok": true, "name": name, "slot": slot]
    }

    public static func clearActive() -> [String: Any] {
        Self.mainSync {
            ThemeManager.shared.clearActiveOverrides()
        }
        return ["ok": true]
    }

    public static func reload() -> [String: Any] {
        Self.mainSync {
            ThemeManager.shared.forceReloadUserThemes()
        }
        return ["ok": true]
    }

    public static func inherit(params: [String: Any]) -> [String: Any] {
        guard let parent = params["parent"] as? String,
              let rawChildName = params["as"] as? String else {
            return ["ok": false, "error": "missing required parameters: parent, as"]
        }

        // The child name flows into both a filesystem path component
        // (`<name>.toml` under userThemesDirectory) and the cloned theme's
        // identity in the registry. Validate it strictly *before* any work
        // happens — a malicious `..`-bearing name would otherwise let an
        // authenticated socket client clobber a same-user file outside the
        // user themes directory.
        let childName = rawChildName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let reason = validateChildThemeName(childName) {
            return ["ok": false, "error": "invalid theme name: \(reason)"]
        }

        let parentTheme: C11muxTheme? = Self.mainSync {
            ThemeManager.shared.theme(named: parent)
        }
        guard let parentTheme else {
            return ["ok": false, "error": "unknown parent theme: \(parent)"]
        }

        // Reject names that shadow a bundled theme. User-name collisions are
        // allowed (forking your own theme is a documented use case); bundled
        // collisions over the socket are not.
        let bundledCollision: Bool = Self.mainSync {
            guard let descriptor = ThemeManager.shared.descriptor(named: childName) else {
                return false
            }
            return descriptor.source == .builtin
        }
        if bundledCollision {
            return ["ok": false, "error": "invalid theme name: collides with bundled theme '\(childName)'"]
        }

        let cloned = C11muxTheme(
            identity: .init(
                name: childName,
                displayName: childName,
                author: parentTheme.identity.author,
                version: "0.01.001",
                schema: parentTheme.identity.schema
            ),
            palette: parentTheme.palette,
            variables: parentTheme.variables,
            chrome: parentTheme.chrome,
            behavior: parentTheme.behavior
        )

        let rendered = ThemeCanonicalizer.canonicalize(cloned)
        let userDir = ThemeManager.userThemesDirectory()
        let outputURL = userDir.appendingPathComponent("\(childName).toml")

        // Defense-in-depth: even after the validation above, assert the
        // resolved output path stays under the user themes directory.
        // `standardizedFileURL` collapses `.`/`..` segments; comparing with
        // `hasPrefix` on the standardized paths keeps `/private` and similar
        // platform aliases consistent on both sides.
        let userDirPath = userDir.standardizedFileURL.path
        let outputPath = outputURL.standardizedFileURL.path
        let boundaryPrefix = userDirPath.hasSuffix("/") ? userDirPath : userDirPath + "/"
        if !outputPath.hasPrefix(boundaryPrefix) {
            return ["ok": false, "error": "invalid theme name: out of bounds"]
        }

        let fm = FileManager.default
        if !fm.fileExists(atPath: userDir.path) {
            try? fm.createDirectory(at: userDir, withIntermediateDirectories: true)
        }

        do {
            try rendered.write(to: outputURL, atomically: true, encoding: .utf8)
        } catch {
            return ["ok": false, "error": "failed to write \(outputURL.path): \(error)"]
        }

        return [
            "ok": true,
            "parent": parent,
            "name": childName,
            "path": outputURL.path
        ]
    }

    // MARK: - Theme name validation

    /// Allowed characters for a user-supplied theme name destined for the
    /// user themes directory. ASCII-only on purpose: the name becomes a
    /// filesystem component on a shared multi-OS authoring path.
    private static let allowedThemeNameCharacters: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return set
    }()

    /// Validate a child theme name supplied via `theme.inherit`.
    ///
    /// Returns `nil` when the (already-trimmed) name is acceptable; otherwise
    /// a short reason for inclusion in the socket error response. Bundled-name
    /// collisions are checked by the caller so this helper stays free of
    /// `@MainActor`-isolated `ThemeManager` access.
    ///
    /// Checks ordered so the most specific feedback wins:
    ///   - empty
    ///   - length cap (64 — generous for human-readable theme names)
    ///   - control characters (incl. NUL)
    ///   - path separators (`/`, `\`)
    ///   - `..` traversal substring
    ///   - leading `.` (hidden) or `-` (looks like a flag)
    ///   - allowlist `[A-Za-z0-9._-]`
    static func validateChildThemeName(_ name: String) -> String? {
        if name.isEmpty {
            return "empty"
        }
        if name.count > 64 {
            return "too long (max 64 chars)"
        }
        for scalar in name.unicodeScalars where scalar.value < 0x20 {
            return "contains control character"
        }
        if name.contains("/") || name.contains("\\") {
            return "contains path separator"
        }
        if name.contains("..") {
            return "contains '..'"
        }
        if name.hasPrefix(".") {
            return "must not start with '.'"
        }
        if name.hasPrefix("-") {
            return "must not start with '-'"
        }
        if name.rangeOfCharacter(from: allowedThemeNameCharacters.inverted) != nil {
            return "must match [A-Za-z0-9._-]"
        }
        return nil
    }

    // MARK: - Helpers

    /// Hop to main when needed, run inline when already on main.
    ///
    /// Bare `DispatchQueue.main.sync` would self-deadlock if a caller is already on main —
    /// post-C11-26 the v2 dispatcher routes default-policy commands through main, so any
    /// theme.* handler reached via `processCommand` is now invoked on the main thread.
    /// libdispatch detects the self-wait and traps with EXC_BREAKPOINT
    /// (`__DISPATCH_WAIT_FOR_QUEUE__`). Mirrors `GhosttyTerminalView.performOnMain`
    /// and `TerminalController.v2MainSync`; ThemeSocketMethods isn't @MainActor itself,
    /// so the body has to be marked `@MainActor` explicitly.
    private static func mainSync<T>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { body() }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { body() }
        }
    }

    private static func resolveThemeForDiff(nameOrPath: String) -> C11muxTheme? {
        if nameOrPath.contains("/") || nameOrPath.hasSuffix(".toml") {
            let url = URL(fileURLWithPath: nameOrPath)
            guard let source = try? String(contentsOf: url, encoding: .utf8),
                  let table = try? TomlSubsetParser.parse(file: url.path, source: source),
                  let theme = try? C11muxTheme.fromToml(table) else {
                return nil
            }
            return theme
        }
        return Self.mainSync { ThemeManager.shared.theme(named: nameOrPath) }
    }
}
