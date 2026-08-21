//
//  SettingsSchema.swift
//  DataEngine
//

import Foundation

/// The name of one setting, stable across releases because it is a persistence key.
public struct SettingKey: Sendable, Hashable, RawRepresentable, ExpressibleByStringLiteral, Codable {

    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public init(_ rawValue: String) { self.rawValue = rawValue }

    public init(stringLiteral value: String) { self.rawValue = value }

}

public extension SettingKey {

    // The keys the network engines share, named once so a config written by one and
    // read by another agrees with itself.
    static let host: SettingKey = "host"
    static let port: SettingKey = "port"
    static let database: SettingKey = "database"
    static let schema: SettingKey = "schema"
    static let username: SettingKey = "username"
    static let password: SettingKey = "password"
    static let useTLS: SettingKey = "useTLS"
    static let fileURL: SettingKey = "fileURL"

}

/// One field of a connection's configuration.
public struct SettingField: Sendable {

    public enum Kind: Sendable {

        case text(placeholder: String? = nil)

        /// Held in the Keychain, never in the store, and never echoed back to screen.
        case secret

        /// A long secret that is pasted rather than typed — a service-account JSON
        /// key, a PEM private key. Same storage rules as ``secret``; different field.
        case secretDocument(placeholder: String? = nil)

        case number(default: Int? = nil)

        /// A security-scoped file. Persisted as a bookmark, resolved at connect time.
        ///
        /// `allowedExtensions` empty means any file, which is not a degenerate case: an
        /// OpenSSH private key is `id_ed25519` with no extension at all, and a filter
        /// would hide every file the user came to pick.
        case file(allowedExtensions: [String], startingIn: FileLocation = .anywhere)

        case toggle(default: Bool = false)

        /// One of a fixed set.
        ///
        /// `default` is what the editor shows when nothing is stored — which is not the
        /// same as what a new connection starts with (`EngineDefinition.defaults`), and
        /// matters for the case that has no defaults to apply: a connection saved before
        /// the choice existed. Set it to whatever the reader's own fallback is, so the
        /// picker cannot show one thing while the engine does another.
        case choice(options: [Option], default: String? = nil)

        /// Whether a value of this kind is a secret and must not be persisted in the
        /// store. The one question the persistence layer asks, so it is answered here
        /// rather than by a list of key names kept in step by hand.
        public var isSecret: Bool {
            switch self {
            case .secret, .secretDocument: true
            case .text, .number, .file, .toggle, .choice: false
            }
        }

        /// Whether this field names a file, and therefore needs a security-scoped
        /// bookmark rather than only a stored string.
        public var isFile: Bool {
            if case .file = self { true } else { false }
        }

    }

    /// Where a file picker should open, and what it should be willing to show.
    ///
    /// Named places rather than a `URL`, because a schema is built in a package that has
    /// no business knowing where this user's home is — and under the App Sandbox it would
    /// get the answer wrong anyway: `NSHomeDirectory()` is the container, not the home
    /// the file actually lives in. The app resolves these.
    public enum FileLocation: Sendable, Hashable {

        /// Wherever the panel last was. The normal case.
        case anywhere

        /// `~/.ssh`, with hidden files shown.
        ///
        /// Both halves are needed and neither is cosmetic. A dotfile directory is not
        /// reachable in an open panel without `showsHiddenFiles`, and a user told to
        /// "choose your private key" with the panel parked in Documents has been given a
        /// puzzle rather than a picker.
        case sshDirectory

    }

    public struct Option: Sendable, Hashable {

        public let value: String
        public let label: String

        public init(value: String, label: String) {
            self.value = value
            self.label = label
        }

    }

    /// When a field applies at all.
    ///
    /// Snowflake is what forced this: it authenticates seven different ways, and the
    /// fields are almost disjoint between them — a passcode belongs to MFA, an Okta URL
    /// to Okta, and SSO through the browser needs no credential field at all. Drawn
    /// unconditionally that is eight inputs of which at most three ever apply, and no
    /// indication which.
    ///
    /// Deliberately a value rather than a closure: a schema is `Sendable`, is read on
    /// the main actor to draw the editor and off it to open a session, and a predicate
    /// that could consult anything else would make "which fields does this connection
    /// have" unanswerable without running it.
    public enum Condition: Sendable {

        case always

        /// Shown only while `key`'s value is one of `values`.
        case when(SettingKey, oneOf: [String])

        public func isSatisfied(by values: SettingsValues) -> Bool {
            switch self {
            case .always:
                true

            case .when(let key, let expected):
                values.string(key).map(expected.contains) ?? false
            }
        }

    }

    public let key: SettingKey

    public let label: String

    public let kind: Kind

    /// Whether a connection is unusable without it. Not enforced on save — a
    /// half-filled connection must still keep its name — only reported at connect time,
    /// where there is already a failure path.
    ///
    /// Read together with ``visibility``: a field that does not apply is never missing,
    /// however required it is when it does.
    public let isRequired: Bool

    /// One line under the field. For the settings whose name is not self-explanatory,
    /// which for the warehouses is most of them.
    public let help: String?

    public let visibility: Condition

    public var isSecret: Bool { kind.isSecret }

    public var isFile: Bool { kind.isFile }

    public init(
        _ key: SettingKey,
        label: String,
        kind: Kind,
        isRequired: Bool = false,
        help: String? = nil,
        visibility: Condition = .always
    ) {
        self.key = key
        self.label = label
        self.kind = kind
        self.isRequired = isRequired
        self.help = help
        self.visibility = visibility
    }

}

/// What one engine needs in order to connect, described rather than drawn.
///
/// The editor is generated from this. That is the point: a config editor written by
/// hand per engine is a view, a Core Data entity, a branch in
/// `ConnectionConfigEditor` and a pair of cases in `ConnectionsList.create` — five
/// things to add per engine, and four of them are the same shape every time. BigQuery
/// takes no host, no port, no user and no password, so the alternative here was not a
/// fourth hand-written editor but a fourth *entity*.
///
/// It also settles where secrets live: a field is `.secret` or it is not, the
/// persistence layer reads that flag, and no list of privileged key names has to be
/// kept in step with it.
public struct SettingsSchema: Sendable {

    public struct Section: Sendable {

        public let title: String?

        public let footnote: String?

        public let fields: [SettingField]

        public init(_ title: String? = nil, footnote: String? = nil, fields: [SettingField]) {
            self.title = title
            self.footnote = footnote
            self.fields = fields
        }

    }

    public let sections: [Section]

    public init(sections: [Section]) {
        self.sections = sections
    }

    /// Every field the schema declares, whether or not it currently applies.
    ///
    /// The right list for anything asking what this *engine* is — where its secrets
    /// live, whether it takes a file. Use ``fields(for:)`` to draw an editor or to
    /// check a configuration, where a field that does not apply must not count.
    public var fields: [SettingField] {
        sections.flatMap(\.fields)
    }

    /// The fields that apply to `values`.
    public func fields(for values: SettingsValues) -> [SettingField] {
        fields.filter { $0.visibility.isSatisfied(by: values) }
    }

    public func field(for key: SettingKey) -> SettingField? {
        fields.first { $0.key == key }
    }

    /// The keys whose values belong in the Keychain.
    ///
    /// Every secret the schema declares, including the ones a given configuration is
    /// not currently using. A password typed under one authenticator has to survive a
    /// look at another and back, and — more importantly — deleting a connection has to
    /// clear secrets the current mode cannot see.
    public var secretKeys: Set<SettingKey> {
        Set(fields.filter { $0.kind.isSecret }.map(\.key))
    }

}

public extension SettingsSchema.Section {

    /// The section's fields that apply to `values`, or nil where none do — a section
    /// whose every field is conditional should not draw as an empty titled box.
    func fields(for values: SettingsValues) -> [SettingField]? {
        let visible = fields.filter { $0.visibility.isSatisfied(by: values) }

        return visible.isEmpty ? nil : visible
    }

}

// MARK: - Values

/// A filled-in configuration, assembled at connect time.
///
/// Deliberately not the persisted form. The store holds the non-secret values; the
/// Keychain holds the rest; this is the two merged, and it exists only for as long as
/// it takes to open a session. Nothing writes one back.
public struct SettingsValues: Sendable {

    private var storage: [SettingKey: String]

    public init(_ storage: [SettingKey: String] = [:]) {
        self.storage = storage
    }

    public subscript(key: SettingKey) -> String? {
        get { storage[key] }
        set { storage[key] = newValue }
    }

    /// The value, or nil where it is absent *or blank*. A field the user cleared and a
    /// field they never filled in are the same thing to every caller here, and treating
    /// them differently is how an empty host becomes `""` instead of `localhost`.
    public func string(_ key: SettingKey) -> String? {
        guard let value = storage[key], !value.isEmpty else { return nil }

        return value
    }

    public func string(_ key: SettingKey, default fallback: String) -> String {
        string(key) ?? fallback
    }

    public func int(_ key: SettingKey) -> Int? {
        string(key).flatMap(Int.init)
    }

    public func int(_ key: SettingKey, default fallback: Int) -> Int {
        int(key) ?? fallback
    }

    /// A TCP port: the stored value where it is one, `fallback` where it is not.
    ///
    /// `UInt16` because that is exactly the range a port has — 0…65535 — and the drivers
    /// used to say `Int16`, which is *signed* and stops at 32767. Every port above that
    /// trapped on conversion: a database on 50000, and every SSH tunnel, whose loopback
    /// port comes from the kernel's ephemeral range and is therefore always above it.
    ///
    /// Out of range is treated as "not a port" and falls back rather than trapping.
    /// Mistyping 99999 is a thing people do, and `Int16(99999)` is a crash.
    public func port(_ key: SettingKey = .port, default fallback: UInt16) -> UInt16 {
        guard let value = int(key), let port = UInt16(exactly: value) else { return fallback }

        return port
    }

    public func bool(_ key: SettingKey, default fallback: Bool = false) -> Bool {
        guard let value = string(key) else { return fallback }

        return (value as NSString).boolValue
    }

    public func url(_ key: SettingKey) -> URL? {
        string(key).flatMap(URL.init(string:))
    }

    /// Reports the first required field the schema declares and this does not have.
    /// Called by an engine at the top of `makeSession`, so a missing setting fails as
    /// itself rather than as whatever the driver says when handed an empty host.
    ///
    /// Only fields that currently apply. A required field belonging to an authenticator
    /// the connection is not using is not missing — it is irrelevant, and reporting it
    /// would make an SSO connection refuse to open until a private key was pasted in.
    public func firstMissingRequirement(of schema: SettingsSchema) -> SettingField? {
        schema.fields(for: self).first { $0.isRequired && string($0.key) == nil }
    }

}
