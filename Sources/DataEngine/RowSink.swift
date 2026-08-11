//
//  RowSink.swift
//  DataEngine
//

import Foundation

/// Writing cells from Swift values.
///
/// The existing byte API — `appendValue(_:length:)`, `appendCString(_:)` — is shaped
/// for the C drivers, which already hold a pointer into memory the library owns and
/// want to copy from it without allocating. The engines being added do not: an HTTP
/// driver has decoded JSON or a `Data` buffer, and reaches the sink holding Swift
/// values.
///
/// These are the bridge, and they are on ``StreamingResultBuilder`` rather than
/// wrapped around it so nothing is interposed on the per-cell path — a wrapper type
/// would be one more retain and one more call per cell, six million times over for
/// the results `docs/grid-invariants.md` §F measures.
public extension StreamingResultBuilder {

    /// Appends `text` as one non-null cell, copying its UTF-8 bytes.
    func append(_ text: String) {
        var text = text

        text.withUTF8 { buffer in
            guard let base = buffer.baseAddress, !buffer.isEmpty else {
                appendEmpty()
                return
            }

            appendValue(base, length: buffer.count)
        }
    }

    /// Appends `text`, or SQL `NULL` where it is absent. The form a JSON-shaped driver
    /// wants, where a missing key and a null are the same thing.
    func append(_ text: String?) {
        guard let text else {
            appendNull()
            return
        }

        append(text)
    }

    /// Appends `bytes` as one non-null cell.
    ///
    /// For a column whose ``CellEncoding`` is `.json` this is how a nested value is
    /// written: the driver hands over the JSON it already has, unparsed, and nothing
    /// on the row path looks inside it. Decoding happens when a cell is expanded.
    func append<Bytes: ContiguousBytes>(bytes: Bytes) {
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress, !buffer.isEmpty else {
                appendEmpty()
                return
            }

            appendValue(base, length: buffer.count)
        }
    }

    /// Appends a whole row of text cells and finishes it. For the low-volume paths —
    /// catalog queries, fixtures, tests — where clarity is worth more than the last
    /// allocation.
    func appendRow(_ values: [String?]) {
        for value in values {
            append(value)
        }

        finishRow()
    }

    /// One empty, non-null cell.
    ///
    /// Split out because an empty Swift string has no base address, and an empty cell
    /// is not a null one — the distinction survives all the way to the grid, which
    /// renders `NULL` differently from `""`.
    private func appendEmpty() {
        withUnsafeBytes(of: UInt8.zero) { buffer in
            // Length 0, so the pointer is never read — it only has to be valid.
            appendValue(buffer.baseAddress!, length: 0)
        }
    }

}
