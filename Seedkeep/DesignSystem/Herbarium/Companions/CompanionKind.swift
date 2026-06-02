import SwiftUI

/// Dispatch enum for the 36-creature plant-pet bestiary. Mirrors the
/// `PressedPlant.Kind.from(_:)` positional-unlabeled router pattern —
/// substring matching is intentionally avoided here because pet creature
/// kinds are a closed identifier set defined by the server's bestiary
/// (`src/lib/pets/bestiary.ts`). We exact-match the raw identifier and
/// fall through to `.unknown` for forward compat with future creatures.
enum CompanionKind: String, CaseIterable {
    // Common tier (10 base + 4 seasonal = 14)
    case ant
    case brownMoth         = "brown_moth"
    case cicada
    case fieldMouse        = "field_mouse"
    case gardenWorm        = "garden_worm"
    case harvestMouse      = "harvest_mouse"
    case ladybug
    case pillbug
    case robin
    case slug
    case snail
    case sparrow
    case weevil
    case winterWren        = "winter_wren"

    // Uncommon tier (6 base + 4 seasonal = 10)
    case acornWoodpecker   = "acorn_woodpecker"
    case bee
    case dragonfly
    case firefly
    case frog
    case gardenSpider      = "garden_spider"
    case hedgehog
    case hummingbird
    case masonBee          = "mason_bee"
    case snowBunting       = "snow_bunting"

    // Rare tier (4)
    case barnOwl           = "barn_owl"
    case foxKit            = "fox_kit"
    case mockingbird
    case weasel

    // Legendary tier (4)
    case hare
    case heron
    case lynx
    case peacock

    // Mythical tier (4)
    case gardenImp         = "garden_imp"
    case spiritFox         = "spirit_fox"
    case wisp
    case dryad

    // Forward-compat fallback for unknown identifiers.
    case unknown

    /// Exact identifier match; falls back to `.unknown`. Positional
    /// unlabeled argument matches `PressedPlant.Kind.from(_:)` style.
    static func from(_ raw: String?) -> CompanionKind {
        guard let raw = raw?.lowercased(), !raw.isEmpty else { return .unknown }
        return CompanionKind(rawValue: raw) ?? .unknown
    }
}

/// Top-level companion glyph. Mirrors `PressedPlant` — caller picks
/// `size` (default 40pt) and an optional `faded` flag for terminal
/// lifecycle states.
struct CompanionIllustration: View {
    let kind: CompanionKind
    var size: CGFloat = 40
    var faded: Bool = false

    var body: some View {
        ZStack {
            shape
                .frame(width: size, height: size)
                .opacity(faded ? 0.72 : 1.0)
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private var shape: some View {
        switch kind {
        case .ant:              AntIllustration()
        case .brownMoth:        BrownMothIllustration()
        case .cicada:           CicadaIllustration()
        case .fieldMouse:       FieldMouseIllustration()
        case .gardenWorm:       GardenWormIllustration()
        case .harvestMouse:     HarvestMouseIllustration()
        case .ladybug:          LadybugIllustration()
        case .pillbug:          PillbugIllustration()
        case .robin:            RobinIllustration()
        case .slug:             SlugIllustration()
        case .snail:            SnailIllustration()
        case .sparrow:          SparrowIllustration()
        case .weevil:           WeevilIllustration()
        case .winterWren:       WinterWrenIllustration()
        case .acornWoodpecker:  AcornWoodpeckerIllustration()
        case .bee:              BeeIllustration()
        case .dragonfly:        DragonflyIllustration()
        case .firefly:          FireflyIllustration()
        case .frog:             FrogIllustration()
        case .gardenSpider:     GardenSpiderIllustration()
        case .hedgehog:         HedgehogIllustration()
        case .hummingbird:      HummingbirdIllustration()
        case .masonBee:         MasonBeeIllustration()
        case .snowBunting:      SnowBuntingIllustration()
        case .barnOwl:          BarnOwlIllustration()
        case .foxKit:           FoxKitIllustration()
        case .mockingbird:      MockingbirdIllustration()
        case .weasel:           WeaselIllustration()
        case .hare:             HareIllustration()
        case .heron:            HeronIllustration()
        case .lynx:             LynxIllustration()
        case .peacock:          PeacockIllustration()
        case .gardenImp:        GardenImpIllustration()
        case .spiritFox:        SpiritFoxIllustration()
        case .wisp:             WispIllustration()
        case .dryad:            DryadIllustration()
        case .unknown:          UnknownCompanionIllustration()
        }
    }
}

// MARK: - Shared palette for companion illustrations
//
// File-scoped private palette so each individual illustration file can
// build atop `CompanionInk.*` instead of redeclaring its own colors.
// Sub-palettes (e.g. mythical gold) reference `HerbColor.goldInk` at the
// call site rather than getting re-aliased here.
enum CompanionInk {
    // Generic ink + sepia (stems, body outlines, antennae)
    static let outline    = Color(red: 0.21, green: 0.13, blue: 0.06)
    static let outlineSoft = Color(red: 0.31, green: 0.23, blue: 0.13)
    static let sepia      = Color(red: 0.43, green: 0.29, blue: 0.13)
    static let sepiaLight = Color(red: 0.62, green: 0.47, blue: 0.27)

    // Botanical greens (frogs, leafy guys, dryad veins)
    static let leafLight  = Color(red: 0.48, green: 0.54, blue: 0.40)
    static let leafDark   = Color(red: 0.27, green: 0.33, blue: 0.25)

    // Body palette
    static let earth      = Color(red: 0.55, green: 0.40, blue: 0.25)
    static let earthDark  = Color(red: 0.36, green: 0.24, blue: 0.13)
    static let cream      = Color(red: 0.93, green: 0.86, blue: 0.71)
    static let red        = Color(red: 0.61, green: 0.23, blue: 0.14)
    static let rust       = Color(red: 0.71, green: 0.32, blue: 0.16)
    static let amber      = Color(red: 0.79, green: 0.55, blue: 0.18)
    static let dusk       = Color(red: 0.43, green: 0.36, blue: 0.41)
    static let slateBlue  = Color(red: 0.45, green: 0.52, blue: 0.59)
    static let pale       = Color(red: 0.88, green: 0.84, blue: 0.75)
    static let charcoal   = Color(red: 0.20, green: 0.18, blue: 0.16)
    static let teal       = Color(red: 0.20, green: 0.46, blue: 0.49)
    static let violet     = Color(red: 0.45, green: 0.32, blue: 0.51)
}
