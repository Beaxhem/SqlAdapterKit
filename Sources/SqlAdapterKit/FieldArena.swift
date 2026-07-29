//
//  FieldArena.swift
//  SqlAdapterKit
//
//  Created by Illia Senchukov on 25.08.2024.
//

import Foundation

/// A contiguous byte buffer that backs the cell values of a single ``QueryResult``.
///
/// Drivers copy every cell's raw bytes into one arena per result instead of
/// allocating a Swift `String` per cell. Cells reference slices of this buffer
/// by `(offset, length)` — indices, not pointers, so they survive the buffer's
/// growth — and only materialize a `String` on demand (see ``GenericField/value``).
///
/// The arena is written exactly once, by a single ``QueryResultArenaBuilder`` on
/// one thread during ingest, and is only read afterwards. That build-then-freeze
/// discipline (which the builder enforces by never exposing a still-growing
/// arena) is what makes `@unchecked Sendable` sound.
public final class FieldArena: @unchecked Sendable {

    public private(set) var bytes: [UInt8]

    public init(bytes: [UInt8] = []) {
        self.bytes = bytes
    }

    func reserveCapacity(_ minimumCapacity: Int) {
        bytes.reserveCapacity(minimumCapacity)
    }

    /// Appends `length` raw bytes from `pointer` and returns the offset they
    /// were written at. Build-phase only; see the type's discussion.
    func append(_ pointer: UnsafeRawPointer, length: Int) -> Int {
        let offset = bytes.count
        if length > 0 {
            bytes.append(contentsOf: UnsafeRawBufferPointer(start: pointer, count: length))
        }
        return offset
    }

}

/// One cell's committed value.
///
/// Immutable by design: a field is what the database returned. Pending edits are
/// a diff held elsewhere and are never written back into a field — see
/// `docs/grid-invariants.md`, rule B1.
public struct GenericField: @unchecked Sendable, Equatable {

    enum Backing {
        case null
        /// An already-decoded string — inserted rows, mocks, and drivers that hand
        /// over `String`s rather than bytes.
        case string(String)
        /// A slice of a shared ``FieldArena``, decoded to `String` lazily.
        case bytes(FieldArena, offset: Int, length: Int)
    }

    let backing: Backing

    public static let null = GenericField(value: nil)

    /// Stores `value` eagerly as a `String`.
    public init(value: String?) {
        self.backing = value.map { .string($0) } ?? .null
    }

    /// Fast path: reference `length` bytes at `offset` inside `arena` without
    /// decoding. The `String` is produced on first access to ``value``.
    public init(arena: FieldArena, offset: Int, length: Int) {
        self.backing = .bytes(arena, offset: offset, length: length)
    }

    /// The materialized cell value. For arena-backed fields this decodes UTF-8
    /// on each access (no caching yet), so prefer ``isNull`` on hot paths where a
    /// full `String` isn't required.
    public var value: String? {
        switch backing {
        case .null:
            return nil

        case .string(let string):
            return string

        case .bytes(let arena, let offset, let length):
            return arena.bytes.withUnsafeBufferPointer { buffer in
                String(decoding: UnsafeBufferPointer(rebasing: buffer[offset..<offset + length]), as: UTF8.self)
            }
        }
    }

    /// `true` when the cell is SQL `NULL`. Cheap: never decodes.
    public var isNull: Bool {
        if case .null = backing { return true }
        return false
    }

    public static func == (lhs: GenericField, rhs: GenericField) -> Bool {
        lhs.value == rhs.value
    }

}
