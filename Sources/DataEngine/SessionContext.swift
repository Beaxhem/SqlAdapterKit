//
//  SessionContext.swift
//  DataEngine
//

import Foundation

/// A part of a connection's session state that is not a credential and not a catalog
/// position — Snowflake's role and warehouse, and nothing else today.
///
/// Declared per engine so the control that edits it is drawn from data rather than from
/// a check for which engine this is. An engine that declares none gets no control, which
/// is every engine but Snowflake.
///
/// ## Where a field is edited
///
/// ``invalidatesCatalog`` decides, and it is the whole rule:
///
/// - **It invalidates the catalog** — the connection editor, applied by reconnecting.
///   Snowflake's role determines what `SHOW DATABASES` returns, so changing it throws
///   away the sidebar, possibly the current scope with it, and every open tab's idea of
///   what it is looking at. That is a connection being reconfigured, not a setting being
///   flipped, and it should cost a deliberate trip to the editor.
/// - **It does not** — switchable inline, next to the thing it affects. The warehouse
///   changes only which compute runs a statement; nothing on screen becomes wrong, so
///   there is no reason to make someone reconnect to try a bigger one.
public struct SessionContextField: Sendable, Identifiable {

    /// The settings key this field reads and writes. Deliberately the *same* key the
    /// engine's ``SettingsSchema`` uses, so a value switched inline and a value typed
    /// into the connection editor are one value and not two that drift.
    public let key: SettingKey

    public let label: String

    /// SF Symbol for the inline control.
    public let icon: String

    /// How the app finds out which values are available.
    public let discovery: Discovery

    /// Whether changing this throws away the connection's catalog snapshot.
    public let invalidatesCatalog: Bool

    public var id: SettingKey { key }

    public init(
        key: SettingKey,
        label: String,
        icon: String,
        discovery: Discovery = .freeText,
        invalidatesCatalog: Bool
    ) {
        self.key = key
        self.label = label
        self.icon = icon
        self.discovery = discovery
        self.invalidatesCatalog = invalidatesCatalog
    }

    /// Whether this may be changed from the query editor rather than the connection
    /// editor. The rule stated in one place, so a field added later cannot quietly
    /// answer it differently.
    public var isInlineSwitchable: Bool { !invalidatesCatalog }

}

public extension SessionContextField {

    /// Where the list of choices comes from.
    enum Discovery: Sendable {

        /// Ask the server. The statement must be answerable by any role the connection
        /// might hold and must not need compute — `SHOW WAREHOUSES` and `SHOW ROLES`
        /// both qualify, which is the reason they are what this ships with.
        ///
        /// - Parameter nameColumn: the column holding the value, located by name.
        ///   `SHOW` output is the server's to change and a hard-coded index that drifts
        ///   picks up a neighbouring column silently.
        case query(String, nameColumn: String = "name")

        /// A list the engine already knows.
        case fixed([String])

        /// No way to enumerate it; the user types it.
        case freeText

    }

}
