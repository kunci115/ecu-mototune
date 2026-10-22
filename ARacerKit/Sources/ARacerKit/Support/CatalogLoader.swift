import Foundation

/// Loads the bundled tuning-table catalog (table_catalog.json) shipped with the package.
/// NOTE: the shipped catalog is ONE real bike — a Yamaha WR155R bore-up (76 mm × 61.7 mm, 28/25 valves,
/// 45 mm throttle body, aRacer RC MiniX) — not a stock map. See catalogs/README.md for other bikes.
func loadCatalog() -> [CalTable] {
    guard let url = Bundle.module.url(forResource: "table_catalog", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let catalog = try? JSONDecoder().decode([CalTable].self, from: data) else { return [] }
    return catalog
}
