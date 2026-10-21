// A bundled CSV for sample-garden screenshots of the import preview (R4, slice C). DEBUG builds only:
// the whole file is compiled out of Release. Launch with `-SeedkeepFixture -SeedkeepCSVImportFixture`
// and the first Seeds screen opens the preview of `csv` once, without the Files picker.
#if DEBUG
import Foundation

enum SeedCSVImportFixture {
    static let launchArgument = "-SeedkeepCSVImportFixture"

    /// Against the sample garden: two updates (Brandywine's packets, Genovese's notes), two new seeds,
    /// a new location ("Seed fridge"), and one row with a bad year.
    static let csv = """
    name,variety,type,company,year,packets,status,stored_in,tags,notes
    Brandywine,,Tomato,Baker Creek,2025,3,active,Seed box,Heirloom,Save seed from the best fruit.
    Genovese,,Basil,Johnny's,2026,2,active,Garage shelf,,Pinch the flowers early.
    Moon and Stars,,Watermelon,Baker Creek,2024,1,wishlist,Seed fridge,Heirloom; Trial,
    Cosmos Sensation,,Cosmos,,2025,2,active,Seed box,Cut flower; Pollinator,
    Mystery packet,,,,20x5,,,,,

    """

    static var data: Data { Data(csv.utf8) }

    @MainActor private static var consumed = false

    /// True once per launch, in sample-garden mode with the launch argument.
    @MainActor
    static func consumeRequest(arguments: [String], isSampleGarden: Bool) -> Bool {
        guard isSampleGarden, arguments.contains(launchArgument), !consumed else { return false }
        consumed = true
        return true
    }
}
#endif
