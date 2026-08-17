//
//  CsvImport.swift
//  DataEngine
//

import Foundation

/// The shape a CSV file takes once an engine has imported it.
///
/// Here rather than in either adapter because *both* import CSVs and the app lets the
/// user switch between them in an open window — so the two have to agree, and they did
/// not. DuckDB created the table under the file's name with `.csv` trimmed; SQLite under
/// the file's name with the extension left on. Switching engine therefore renamed the
/// table under whatever query was in the editor.
public enum CsvImport {

    /// What the imported table is called.
    ///
    /// Named for the file after all. This was briefly a constant `"data"`, on the
    /// reasoning that a CSV connection holds exactly one table so the name carries no
    /// information — true right up until the window grew a sidebar, and with it the
    /// expectation that you can `CREATE TABLE … AS FROM read_csv(…)` a second file in
    /// beside the first. Once two tables can be in the room, the only thing that says
    /// which is which is where each came from.
    ///
    /// Sanitised rather than taken verbatim: the result is quoted at the point of use, so
    /// spaces would *work*, but this is a name the user has to type in the editor all day.
    /// Anything that isn't a letter, a number or an underscore collapses to a single
    /// underscore. Letters and numbers are judged by Unicode, not ASCII — a file named in
    /// Cyrillic keeps its name rather than becoming a row of underscores — and both
    /// engines accept those quoted.
    ///
    /// A leading digit is prefixed rather than dropped, because dropping it makes
    /// `2026_report.csv` and `report.csv` the same table.
    public static func tableName(for fileUrl: URL) -> String {
        let stem = fileUrl.deletingPathExtension().lastPathComponent

        var sanitized = ""
        var pendingSeparator = false

        for character in stem {
            if character.isLetter || character.isNumber || character == "_" {
                if pendingSeparator, !sanitized.isEmpty {
                    sanitized.append("_")
                }

                sanitized.append(character)
                pendingSeparator = false
            } else {
                // Held rather than appended, so a run of junk — and any junk trailing the
                // name — costs one underscore or none, never a row of them.
                pendingSeparator = true
            }
        }

        guard let first = sanitized.first else { return fallbackTableName }

        // `_2026_report` rather than `2026_report`: a bare leading digit is not an
        // identifier in either engine, and quoting it would leave a table that has to be
        // quoted every time it is named.
        return first.isNumber ? "_" + sanitized : sanitized
    }

    /// What an imported table is called when the filename had nothing usable in it —
    /// `".csv"`, or a name made entirely of punctuation.
    public static let fallbackTableName = "data"

}
