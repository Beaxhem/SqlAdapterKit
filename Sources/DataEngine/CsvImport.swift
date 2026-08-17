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
/// table under whatever query was in the editor, and neither name was one anybody would
/// choose to type.
public enum CsvImport {

    /// What the imported table is called, whatever the file is called.
    ///
    /// A constant rather than something derived from the filename. A CSV connection holds
    /// exactly one table, so the name carries no information — there is nothing to tell it
    /// apart from — and deriving it made every query start with whatever the exporting
    /// system happened to emit: `SELECT * FROM export_catalog_product_20260429_033045`.
    /// The window title says which file this is; the table name only has to be typeable.
    ///
    /// Deriving it also meant parsing: trimming an extension that might be `.csv` or
    /// `.tsv`, and quoting whatever spaces and dots survived. A constant has none of that,
    /// and it is a legal bare identifier in both engines.
    public static let tableName = "data"

}
