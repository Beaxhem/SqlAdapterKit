//
//  FilePath.swift
//  DataEngine
//

import Foundation

/// Spelling a file's path the way an engine needs to receive it.
///
/// `URL.path()` percent-encodes by default, which is right for a URL and wrong for
/// everything here: engines open paths, not URLs. A file picked from Downloads called
/// `export-3 - export-3.csv.csv` reached DuckDB as
/// `/Users/…/export-3%20-%20export-3.csv.csv` and came back
/// *"No files found that match the pattern"* — a file that was sitting right there, named
/// with the one character most likely to be in a filename a person chose.
///
/// Both adapters and the CSV write-back had it, so it lives here rather than being fixed
/// four times and re-broken the fifth.
public extension URL {

    /// The path as the file system spells it.
    ///
    /// Use for anything handed to an engine as a path: a connection string, a file
    /// argument. For a path going *inside* SQL, use ``sqlPathLiteral``.
    var enginePath: String {
        path(percentEncoded: false)
    }

    /// The path as it must appear inside a single-quoted SQL string literal.
    ///
    /// Doubling the quote is the other half of the same problem: an apostrophe is legal
    /// in a filename and ends the literal in `read_csv('…')`, turning the rest of the
    /// path into syntax. Rare, but it fails the same way — the file is there and the
    /// engine says it is not.
    var sqlPathLiteral: String {
        enginePath.replacingOccurrences(of: "'", with: "''")
    }

}
