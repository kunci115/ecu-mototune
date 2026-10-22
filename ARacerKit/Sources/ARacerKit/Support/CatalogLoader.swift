import Foundation

/// Loads the bundled tuning-table catalog (table_catalog.json) shipped with the package.
func loadCatalog() -> [CalTable] {
    guard let url = Bundle.module.url(forResource: "table_catalog", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let catalog = try? JSONDecoder().decode([CalTable].self, from: data) else { return [] }
    return catalog
}
