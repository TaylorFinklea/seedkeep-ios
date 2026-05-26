import SwiftUI

/// Hand-drawn "pressed plant" illustrations rendered as SwiftUI Paths.
/// Maps a Seedkeep customType (free-form string) to the closest
/// botanical shape; unknown types render the generic specimen leaf.
///
/// The visual style mirrors the JSX mockups — sage leaves, sepia stems,
/// muted watercolor washes. Each illustration is monochrome-ish so they
/// read as a coherent set rather than a clipart grab-bag.
struct PressedPlant: View {
    let kind: Kind
    var size: CGFloat = 90
    var faded: Bool = false

    enum Kind {
        case tomato, pepper, bean, pea, carrot, beet, lettuce, kale
        case onion, garlic, cucumber, squash, melon, radish, herb
        case flower, brassica, root, leafyGreen, fruit
        case generic

        /// Best guess from a free-form customType string.
        static func from(_ customType: String?) -> Kind {
            guard let raw = customType?.lowercased(), !raw.isEmpty else { return .generic }
            // Order matters — longer / more-specific matches first.
            let patterns: [(String, Kind)] = [
                ("tomato",   .tomato),
                ("pepper",   .pepper),
                ("chili",    .pepper),
                ("bean",     .bean),
                ("pea",      .pea),
                ("carrot",   .carrot),
                ("beet",     .beet),
                ("radish",   .radish),
                ("onion",    .onion),
                ("garlic",   .garlic),
                ("leek",     .onion),
                ("shallot",  .onion),
                ("cucumber", .cucumber),
                ("cuke",     .cucumber),
                ("zucchini", .squash),
                ("squash",   .squash),
                ("pumpkin",  .squash),
                ("melon",    .melon),
                ("watermelon", .melon),
                ("lettuce",  .lettuce),
                ("kale",     .kale),
                ("spinach",  .leafyGreen),
                ("chard",    .leafyGreen),
                ("arugula",  .leafyGreen),
                ("broccoli", .brassica),
                ("cabbage",  .brassica),
                ("cauliflower", .brassica),
                ("brussels", .brassica),
                ("herb",     .herb),
                ("basil",    .herb),
                ("oregano",  .herb),
                ("rosemary", .herb),
                ("thyme",    .herb),
                ("mint",     .herb),
                ("cilantro", .herb),
                ("parsley",  .herb),
                ("dill",     .herb),
                ("sage",     .herb),
                ("flower",   .flower),
                ("marigold", .flower),
                ("zinnia",   .flower),
                ("sunflower", .flower),
                ("turnip",   .root),
                ("parsnip",  .root),
                ("potato",   .root),
                ("sweet potato", .root),
                ("strawberry", .fruit),
                ("blueberry", .fruit),
                ("raspberry", .fruit),
            ]
            for (needle, kind) in patterns {
                if raw.contains(needle) { return kind }
            }
            return .generic
        }
    }

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
        case .tomato:        TomatoIllustration()
        case .pepper:        PepperIllustration()
        case .bean:          BeanIllustration()
        case .pea:           PeaIllustration()
        case .carrot:        CarrotIllustration()
        case .beet:          BeetIllustration()
        case .lettuce:       LettuceIllustration()
        case .kale:          KaleIllustration()
        case .onion:         OnionIllustration()
        case .garlic:        GarlicIllustration()
        case .cucumber:      CucumberIllustration()
        case .squash:        SquashIllustration()
        case .melon:         MelonIllustration()
        case .radish:        RadishIllustration()
        case .herb:          HerbIllustration()
        case .flower:        FlowerIllustration()
        case .brassica:      BrassicaIllustration()
        case .root:          RootIllustration()
        case .leafyGreen:    LeafyGreenIllustration()
        case .fruit:         FruitIllustration()
        case .generic:       GenericLeafIllustration()
        }
    }
}

// MARK: - Shared palette for illustrations

private enum IllusColor {
    static let leafLight  = Color(red: 0.478, green: 0.541, blue: 0.400)
    static let leafDark   = Color(red: 0.274, green: 0.329, blue: 0.255)
    static let stem       = Color(red: 0.301, green: 0.352, blue: 0.239)
    static let veinDark   = Color(red: 0.212, green: 0.251, blue: 0.165)
    static let red        = Color(red: 0.612, green: 0.227, blue: 0.141)
    static let redDark    = Color(red: 0.416, green: 0.114, blue: 0.078)
    static let redHi      = Color(red: 0.769, green: 0.353, blue: 0.227)
    static let orange     = Color(red: 0.788, green: 0.478, blue: 0.180)
    static let orangeDark = Color(red: 0.514, green: 0.286, blue: 0.094)
    static let purple     = Color(red: 0.549, green: 0.122, blue: 0.271)
    static let purpleDark = Color(red: 0.290, green: 0.055, blue: 0.149)
    static let purpleHi   = Color(red: 0.659, green: 0.204, blue: 0.369)
    static let yellow     = Color(red: 0.875, green: 0.722, blue: 0.302)
    static let white      = Color(red: 0.95,  green: 0.90,  blue: 0.78)
}

// MARK: - Individual illustrations

private struct TomatoIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 200
            ZStack {
                // Stem
                Path { p in
                    p.move(to: CGPoint(x: 100 * s, y: 180 * s))
                    p.addQuadCurve(to: CGPoint(x: 102 * s, y: 110 * s), control: CGPoint(x: 96 * s, y: 140 * s))
                    p.addQuadCurve(to: CGPoint(x: 100 * s,  y: 36 * s), control: CGPoint(x: 110 * s, y: 70 * s))
                }
                .stroke(IllusColor.stem, lineWidth: 1.5 * s)
                // Leaves
                Path { p in
                    p.move(to: CGPoint(x: 100 * s, y: 110 * s))
                    p.addQuadCurve(to: CGPoint(x: 50 * s, y: 78 * s), control: CGPoint(x: 66 * s, y: 100 * s))
                    p.addQuadCurve(to: CGPoint(x: 100 * s, y: 100 * s), control: CGPoint(x: 70 * s, y: 70 * s))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [IllusColor.leafLight, IllusColor.leafDark], startPoint: .topLeading, endPoint: .bottomTrailing))
                Path { p in
                    p.move(to: CGPoint(x: 100 * s, y: 110 * s))
                    p.addQuadCurve(to: CGPoint(x: 154 * s, y: 80 * s), control: CGPoint(x: 132 * s, y: 102 * s))
                    p.addQuadCurve(to: CGPoint(x: 110 * s, y: 100 * s), control: CGPoint(x: 140 * s, y: 70 * s))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [IllusColor.leafLight, IllusColor.leafDark], startPoint: .topLeading, endPoint: .bottomTrailing))
                Path { p in
                    p.move(to: CGPoint(x: 100 * s, y: 70 * s))
                    p.addQuadCurve(to: CGPoint(x: 60 * s, y: 46 * s), control: CGPoint(x: 72 * s, y: 64 * s))
                    p.addQuadCurve(to: CGPoint(x: 100 * s, y: 60 * s), control: CGPoint(x: 78 * s, y: 38 * s))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [IllusColor.leafLight, IllusColor.leafDark], startPoint: .topLeading, endPoint: .bottomTrailing))
                // Fruits
                Ellipse().fill(LinearGradient(colors: [IllusColor.red, IllusColor.redDark], startPoint: .top, endPoint: .bottom))
                    .frame(width: 32 * s, height: 34 * s).offset(x: -16 * s, y: 32 * s)
                Ellipse().fill(LinearGradient(colors: [IllusColor.red, IllusColor.redDark], startPoint: .top, endPoint: .bottom))
                    .frame(width: 36 * s, height: 40 * s).offset(x: 16 * s, y: 42 * s)
                Ellipse().fill(LinearGradient(colors: [IllusColor.red, IllusColor.redDark], startPoint: .top, endPoint: .bottom))
                    .frame(width: 28 * s, height: 30 * s).offset(x: 0, y: 66 * s)
                // Watercolor highlights
                Ellipse().fill(IllusColor.redHi.opacity(0.5))
                    .frame(width: 6 * s, height: 8 * s).offset(x: -20 * s, y: 28 * s)
                Ellipse().fill(IllusColor.redHi.opacity(0.5))
                    .frame(width: 8 * s, height: 10 * s).offset(x: 12 * s, y: 38 * s)
            }
        }
    }
}

private struct PepperIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 90
            ZStack(alignment: .topLeading) {
                // Body — wide-shouldered bell pepper tapering to a slight point
                Path { p in
                    let leftX: CGFloat = 26 * s
                    let rightX: CGFloat = 64 * s
                    let topY: CGFloat = 28 * s
                    let bottomY: CGFloat = 80 * s
                    let centerX: CGFloat = 45 * s
                    p.move(to: CGPoint(x: leftX, y: topY + 4 * s))
                    // Left shoulder curve to wide left flank
                    p.addQuadCurve(
                        to: CGPoint(x: 22 * s, y: 56 * s),
                        control: CGPoint(x: 20 * s, y: 38 * s))
                    // Left flank curve to slightly-pointed bottom
                    p.addQuadCurve(
                        to: CGPoint(x: centerX, y: bottomY),
                        control: CGPoint(x: 28 * s, y: 78 * s))
                    // Bottom up the right flank
                    p.addQuadCurve(
                        to: CGPoint(x: 68 * s, y: 56 * s),
                        control: CGPoint(x: 62 * s, y: 78 * s))
                    // Right shoulder curve to top-right
                    p.addQuadCurve(
                        to: CGPoint(x: rightX, y: topY + 4 * s),
                        control: CGPoint(x: 70 * s, y: 38 * s))
                    // Top dip between the shoulders
                    p.addQuadCurve(
                        to: CGPoint(x: leftX, y: topY + 4 * s),
                        control: CGPoint(x: centerX, y: topY + 12 * s))
                    p.closeSubpath()
                }
                .fill(LinearGradient(
                    colors: [IllusColor.redHi, IllusColor.red, IllusColor.redDark],
                    startPoint: .topLeading, endPoint: .bottomTrailing))

                // Subtle lobing — a vertical highlight line down the front
                Path { p in
                    p.move(to: CGPoint(x: 45 * s, y: 30 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 45 * s, y: 76 * s),
                        control: CGPoint(x: 48 * s, y: 54 * s))
                }
                .stroke(IllusColor.redDark.opacity(0.5), lineWidth: 0.5 * s)

                // Calyx — green papery cap at the top of the pepper
                Path { p in
                    p.move(to: CGPoint(x: 28 * s, y: 32 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 45 * s, y: 26 * s),
                        control: CGPoint(x: 34 * s, y: 22 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 62 * s, y: 32 * s),
                        control: CGPoint(x: 56 * s, y: 22 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 55 * s, y: 36 * s),
                        control: CGPoint(x: 58 * s, y: 36 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 35 * s, y: 36 * s),
                        control: CGPoint(x: 45 * s, y: 30 * s))
                    p.addQuadCurve(
                        to: CGPoint(x: 28 * s, y: 32 * s),
                        control: CGPoint(x: 32 * s, y: 36 * s))
                    p.closeSubpath()
                }
                .fill(IllusColor.leafDark)

                // Stem — short straight green stub on top
                Path { p in
                    p.move(to: CGPoint(x: 45 * s, y: 26 * s))
                    p.addLine(to: CGPoint(x: 45 * s, y: 14 * s))
                }
                .stroke(IllusColor.stem, lineWidth: 2 * s)

                // Highlight — soft glint on the upper-left flank
                Ellipse()
                    .fill(IllusColor.redHi.opacity(0.55))
                    .frame(width: 5 * s, height: 14 * s)
                    .rotationEffect(.degrees(-10))
                    .offset(x: 30 * s, y: 42 * s)
            }
            .frame(width: 90 * s, height: 90 * s)
        }
    }
}

private struct BeanIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 90
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 45 * s, y: 80 * s))
                    p.addQuadCurve(to: CGPoint(x: 44 * s, y: 8 * s), control: CGPoint(x: 48 * s, y: 30 * s))
                }
                .stroke(IllusColor.stem, lineWidth: 1.2 * s)
                Path { p in
                    p.move(to: CGPoint(x: 46 * s, y: 35 * s))
                    p.addQuadCurve(to: CGPoint(x: 14 * s, y: 16 * s), control: CGPoint(x: 26 * s, y: 30 * s))
                    p.addQuadCurve(to: CGPoint(x: 50 * s, y: 24 * s), control: CGPoint(x: 30 * s, y: 8 * s))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [IllusColor.leafLight, IllusColor.leafDark], startPoint: .topLeading, endPoint: .bottomTrailing))
                Path { p in
                    p.move(to: CGPoint(x: 46 * s, y: 35 * s))
                    p.addQuadCurve(to: CGPoint(x: 78 * s, y: 16 * s), control: CGPoint(x: 66 * s, y: 30 * s))
                    p.addQuadCurve(to: CGPoint(x: 42 * s, y: 24 * s), control: CGPoint(x: 62 * s, y: 8 * s))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [IllusColor.leafLight, IllusColor.leafDark], startPoint: .topLeading, endPoint: .bottomTrailing))
                // Bean pods
                Ellipse().fill(Color(red: 0.451, green: 0.333, blue: 0.251))
                    .frame(width: 12 * s, height: 5 * s).rotationEffect(.degrees(-30)).offset(x: -5 * s, y: 27 * s)
                Ellipse().fill(Color(red: 0.451, green: 0.333, blue: 0.251))
                    .frame(width: 12 * s, height: 5 * s).rotationEffect(.degrees(-30)).offset(x: 5 * s, y: 31 * s)
                Ellipse().fill(Color(red: 0.451, green: 0.333, blue: 0.251))
                    .frame(width: 12 * s, height: 5 * s).rotationEffect(.degrees(-30)).offset(x: 0, y: 23 * s)
            }
        }
    }
}

private struct PeaIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 90
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 45 * s, y: 84 * s))
                    p.addQuadCurve(to: CGPoint(x: 45 * s, y: 14 * s), control: CGPoint(x: 50 * s, y: 50 * s))
                }
                .stroke(IllusColor.stem, lineWidth: 1.0 * s)
                // Pod
                Capsule().fill(LinearGradient(colors: [IllusColor.leafLight, IllusColor.leafDark], startPoint: .top, endPoint: .bottom))
                    .frame(width: 14 * s, height: 36 * s).rotationEffect(.degrees(-12)).offset(x: -2 * s, y: 36 * s)
                // Peas inside the pod (tiny circles)
                ForEach(0..<4) { i in
                    Circle().fill(IllusColor.leafLight.opacity(0.85))
                        .frame(width: 7 * s, height: 7 * s)
                        .offset(x: CGFloat(-2 + (i - 2)) * 0.5 * s, y: CGFloat(20 + i * 8) * s)
                }
                // Tendrils
                Path { p in
                    p.move(to: CGPoint(x: 50 * s, y: 20 * s))
                    p.addQuadCurve(to: CGPoint(x: 70 * s, y: 8 * s), control: CGPoint(x: 64 * s, y: 14 * s))
                }
                .stroke(IllusColor.stem, lineWidth: 0.8 * s)
            }
        }
    }
}

private struct CarrotIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 90
            ZStack {
                ForEach(0..<6) { i in
                    Path { p in
                        let start = CGPoint(x: 45 * s, y: 30 * s)
                        let endX  = CGFloat(28 + i * 7) * s
                        let endY  = CGFloat(4 + (i % 2) * 6) * s
                        let ctrlX = CGFloat(36 + i * 3) * s
                        p.move(to: start)
                        p.addQuadCurve(to: CGPoint(x: endX, y: endY), control: CGPoint(x: ctrlX, y: 16 * s))
                    }
                    .stroke(IllusColor.leafDark, lineWidth: 1 * s)
                }
                Path { p in
                    p.move(to: CGPoint(x: 40 * s, y: 30 * s))
                    p.addLine(to: CGPoint(x: 36 * s, y: 80 * s))
                    p.addLine(to: CGPoint(x: 44 * s, y: 86 * s))
                    p.addLine(to: CGPoint(x: 52 * s, y: 80 * s))
                    p.addLine(to: CGPoint(x: 48 * s, y: 30 * s))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [IllusColor.orange, IllusColor.orangeDark], startPoint: .top, endPoint: .bottom))
                // Ridges
                ForEach(0..<3) { i in
                    Path { p in
                        p.move(to: CGPoint(x: 40 * s, y: CGFloat(40 + i * 14) * s))
                        p.addQuadCurve(to: CGPoint(x: 48 * s, y: CGFloat(40 + i * 14) * s), control: CGPoint(x: 44 * s, y: CGFloat(44 + i * 14) * s))
                    }
                    .stroke(Color(red: 0.357, green: 0.184, blue: 0.059), lineWidth: 0.5 * s)
                }
            }
        }
    }
}

private struct BeetIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 90
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 45 * s, y: 36 * s))
                    p.addQuadCurve(to: CGPoint(x: 14 * s, y: 8 * s), control: CGPoint(x: 24 * s, y: 26 * s))
                    p.addQuadCurve(to: CGPoint(x: 50 * s, y: 30 * s), control: CGPoint(x: 30 * s, y: 12 * s))
                    p.closeSubpath()
                }
                .fill(IllusColor.leafDark)
                Path { p in
                    p.move(to: CGPoint(x: 45 * s, y: 36 * s))
                    p.addQuadCurve(to: CGPoint(x: 78 * s, y: 8 * s), control: CGPoint(x: 66 * s, y: 26 * s))
                    p.addQuadCurve(to: CGPoint(x: 42 * s, y: 30 * s), control: CGPoint(x: 60 * s, y: 12 * s))
                    p.closeSubpath()
                }
                .fill(IllusColor.leafLight)
                // Red veins
                Path { p in
                    p.move(to: CGPoint(x: 45 * s, y: 36 * s))
                    p.addQuadCurve(to: CGPoint(x: 60 * s, y: 4 * s), control: CGPoint(x: 60 * s, y: 18 * s))
                }
                .stroke(IllusColor.purple, lineWidth: 0.8 * s)
                Path { p in
                    p.move(to: CGPoint(x: 45 * s, y: 36 * s))
                    p.addQuadCurve(to: CGPoint(x: 26 * s, y: 8 * s), control: CGPoint(x: 32 * s, y: 22 * s))
                }
                .stroke(IllusColor.purple, lineWidth: 0.8 * s)
                // Bulb
                Circle()
                    .fill(RadialGradient(colors: [IllusColor.purpleHi, IllusColor.purple, IllusColor.purpleDark], center: .center, startRadius: 2, endRadius: 22))
                    .frame(width: 40 * s, height: 40 * s).offset(x: 0, y: 18 * s)
                // Taproot
                Path { p in
                    p.move(to: CGPoint(x: 45 * s, y: 80 * s))
                    p.addLine(to: CGPoint(x: 42 * s, y: 86 * s))
                    p.addLine(to: CGPoint(x: 45 * s, y: 90 * s))
                    p.addLine(to: CGPoint(x: 48 * s, y: 86 * s))
                    p.closeSubpath()
                }
                .fill(IllusColor.purpleDark)
            }
        }
    }
}

private struct LettuceIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 90
            ZStack {
                ForEach([34, 26, 18, 10], id: \.self) { r in
                    Circle()
                        .fill(IllusColor.leafLight.opacity(0.5 + Double(34 - r) * 0.04))
                        .frame(width: CGFloat(r * 2) * s, height: CGFloat(r * 2) * s)
                        .overlay(Circle().strokeBorder(IllusColor.leafDark.opacity(0.6), lineWidth: 0.4 * s))
                }
                // Ruffle edge dots
                ForEach(0..<12) { i in
                    let a = Double(i) / 12 * .pi * 2
                    let dx = CGFloat(cos(a)) * 34 * s
                    let dy = CGFloat(sin(a)) * 34 * s
                    Circle()
                        .fill(IllusColor.leafLight)
                        .frame(width: 5 * s, height: 5 * s)
                        .offset(x: dx, y: dy)
                }
                Circle().fill(IllusColor.leafDark).frame(width: 6 * s, height: 6 * s)
            }
        }
    }
}

private struct KaleIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 90
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 45 * s, y: 80 * s))
                    p.addLine(to: CGPoint(x: 45 * s, y: 24 * s))
                }
                .stroke(IllusColor.stem, lineWidth: 1.2 * s)
                ForEach(0..<5) { i in
                    let yOffset = CGFloat(20 + i * 10) * s
                    Path { p in
                        p.move(to: CGPoint(x: 45 * s, y: yOffset))
                        p.addQuadCurve(to: CGPoint(x: (i % 2 == 0 ? 14 : 76) * s, y: yOffset - 8 * s),
                                       control: CGPoint(x: (i % 2 == 0 ? 24 : 66) * s, y: yOffset + 4 * s))
                        p.addQuadCurve(to: CGPoint(x: 45 * s, y: yOffset),
                                       control: CGPoint(x: (i % 2 == 0 ? 30 : 60) * s, y: yOffset + 10 * s))
                        p.closeSubpath()
                    }
                    .fill(IllusColor.leafDark.opacity(0.85))
                }
            }
        }
    }
}

private struct OnionIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 90
            ZStack {
                // Green tops
                ForEach(0..<5) { i in
                    Path { p in
                        let x = CGFloat(35 + i * 5) * s
                        let drift = CGFloat(i - 2)
                        p.move(to: CGPoint(x: x, y: 50 * s))
                        p.addQuadCurve(to: CGPoint(x: x + drift * 4 * s, y: 8 * s),
                                       control: CGPoint(x: x + drift * 6 * s, y: 24 * s))
                    }
                    .stroke(IllusColor.leafLight, lineWidth: 1.8 * s)
                }
                // Bulb
                Ellipse()
                    .fill(LinearGradient(colors: [IllusColor.white, Color(red: 0.745, green: 0.612, blue: 0.443)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 38 * s, height: 32 * s).offset(x: 0, y: 18 * s)
                // Root strands
                ForEach(0..<4) { i in
                    Path { p in
                        let baseX = CGFloat(38 + i * 4) * s
                        p.move(to: CGPoint(x: baseX, y: 72 * s))
                        p.addLine(to: CGPoint(x: baseX + 1 * s, y: 80 * s))
                    }
                    .stroke(IllusColor.stem, lineWidth: 0.5 * s)
                }
            }
        }
    }
}

private struct GarlicIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 90
            ZStack {
                // Top tuft
                ForEach(0..<3) { i in
                    Path { p in
                        let x = CGFloat(40 + i * 5) * s
                        p.move(to: CGPoint(x: x, y: 36 * s))
                        p.addLine(to: CGPoint(x: x, y: 14 * s))
                    }
                    .stroke(IllusColor.leafLight, lineWidth: 1 * s)
                }
                // Bulb
                Path { p in
                    let cx = 45 * s, cy = 52 * s
                    p.move(to: CGPoint(x: cx, y: cy - 16 * s))
                    p.addQuadCurve(to: CGPoint(x: cx + 18 * s, y: cy + 14 * s), control: CGPoint(x: cx + 18 * s, y: cy - 6 * s))
                    p.addQuadCurve(to: CGPoint(x: cx, y: cy + 22 * s), control: CGPoint(x: cx + 6 * s, y: cy + 22 * s))
                    p.addQuadCurve(to: CGPoint(x: cx - 18 * s, y: cy + 14 * s), control: CGPoint(x: cx - 6 * s, y: cy + 22 * s))
                    p.addQuadCurve(to: CGPoint(x: cx, y: cy - 16 * s), control: CGPoint(x: cx - 18 * s, y: cy - 6 * s))
                }
                .fill(IllusColor.white)
                // Clove divisions
                Path { p in
                    p.move(to: CGPoint(x: 45 * s, y: 36 * s))
                    p.addLine(to: CGPoint(x: 45 * s, y: 74 * s))
                }
                .stroke(IllusColor.stem.opacity(0.35), lineWidth: 0.4 * s)
                Path { p in
                    p.move(to: CGPoint(x: 32 * s, y: 50 * s))
                    p.addQuadCurve(to: CGPoint(x: 45 * s, y: 70 * s), control: CGPoint(x: 36 * s, y: 64 * s))
                }
                .stroke(IllusColor.stem.opacity(0.35), lineWidth: 0.4 * s)
                Path { p in
                    p.move(to: CGPoint(x: 58 * s, y: 50 * s))
                    p.addQuadCurve(to: CGPoint(x: 45 * s, y: 70 * s), control: CGPoint(x: 54 * s, y: 64 * s))
                }
                .stroke(IllusColor.stem.opacity(0.35), lineWidth: 0.4 * s)
            }
        }
    }
}

private struct CucumberIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 90
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 10 * s, y: 60 * s))
                    p.addQuadCurve(to: CGPoint(x: 76 * s, y: 50 * s), control: CGPoint(x: 40 * s, y: 56 * s))
                }
                .stroke(IllusColor.stem, lineWidth: 1 * s)
                Path { p in
                    p.move(to: CGPoint(x: 40 * s, y: 50 * s))
                    p.addQuadCurve(to: CGPoint(x: 22 * s, y: 22 * s), control: CGPoint(x: 26 * s, y: 38 * s))
                    p.addQuadCurve(to: CGPoint(x: 50 * s, y: 46 * s), control: CGPoint(x: 42 * s, y: 28 * s))
                    p.closeSubpath()
                }
                .fill(IllusColor.leafLight)
                Capsule().fill(LinearGradient(colors: [IllusColor.leafLight, IllusColor.leafDark], startPoint: .top, endPoint: .bottom))
                    .frame(width: 28 * s, height: 10 * s).rotationEffect(.degrees(-20)).offset(x: 10 * s, y: 18 * s)
                Capsule().fill(LinearGradient(colors: [IllusColor.leafLight, IllusColor.leafDark], startPoint: .top, endPoint: .bottom))
                    .frame(width: 20 * s, height: 8 * s).rotationEffect(.degrees(-10)).offset(x: -13 * s, y: 26 * s)
            }
        }
    }
}

private struct SquashIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 90
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 45 * s, y: 78 * s))
                    p.addQuadCurve(to: CGPoint(x: 30 * s, y: 30 * s), control: CGPoint(x: 26 * s, y: 60 * s))
                }
                .stroke(IllusColor.stem, lineWidth: 1.2 * s)
                Path { p in
                    p.move(to: CGPoint(x: 32 * s, y: 30 * s))
                    p.addQuadCurve(to: CGPoint(x: 12 * s, y: 18 * s), control: CGPoint(x: 20 * s, y: 22 * s))
                    p.addQuadCurve(to: CGPoint(x: 30 * s, y: 24 * s), control: CGPoint(x: 22 * s, y: 14 * s))
                    p.closeSubpath()
                }
                .fill(IllusColor.leafLight)
                // Squash body
                Path { p in
                    let cx = 50 * s, cy = 58 * s
                    p.move(to: CGPoint(x: cx - 18 * s, y: cy - 6 * s))
                    p.addQuadCurve(to: CGPoint(x: cx + 22 * s, y: cy - 4 * s), control: CGPoint(x: cx, y: cy - 22 * s))
                    p.addQuadCurve(to: CGPoint(x: cx + 22 * s, y: cy + 20 * s), control: CGPoint(x: cx + 30 * s, y: cy + 10 * s))
                    p.addQuadCurve(to: CGPoint(x: cx - 18 * s, y: cy + 18 * s), control: CGPoint(x: cx, y: cy + 26 * s))
                    p.addQuadCurve(to: CGPoint(x: cx - 18 * s, y: cy - 6 * s), control: CGPoint(x: cx - 26 * s, y: cy + 8 * s))
                }
                .fill(LinearGradient(colors: [IllusColor.orange, IllusColor.orangeDark], startPoint: .top, endPoint: .bottom))
                // Ribbing
                ForEach(0..<4) { i in
                    Path { p in
                        let x = CGFloat(34 + i * 8) * s
                        p.move(to: CGPoint(x: x, y: 42 * s))
                        p.addQuadCurve(to: CGPoint(x: x, y: 78 * s), control: CGPoint(x: x + 1 * s, y: 60 * s))
                    }
                    .stroke(IllusColor.orangeDark.opacity(0.5), lineWidth: 0.4 * s)
                }
            }
        }
    }
}

private struct MelonIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 90
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 22 * s, y: 60 * s))
                    p.addQuadCurve(to: CGPoint(x: 70 * s, y: 36 * s), control: CGPoint(x: 50 * s, y: 50 * s))
                }
                .stroke(IllusColor.stem, lineWidth: 1 * s)
                Ellipse().fill(LinearGradient(colors: [IllusColor.leafLight, IllusColor.leafDark], startPoint: .top, endPoint: .bottom))
                    .frame(width: 50 * s, height: 36 * s).offset(x: 0, y: 18 * s)
                // Veins
                ForEach(0..<5) { i in
                    Path { p in
                        let cx: CGFloat = 45
                        let cy: CGFloat = 56
                        let a = Double(i) / 4 * .pi - .pi / 2
                        let endX = (cx + CGFloat(cos(a)) * 24) * s
                        let endY = (cy + CGFloat(sin(a)) * 18) * s
                        p.move(to: CGPoint(x: cx * s, y: cy * s))
                        p.addLine(to: CGPoint(x: endX, y: endY))
                    }
                    .stroke(IllusColor.veinDark.opacity(0.45), lineWidth: 0.5 * s)
                }
            }
        }
    }
}

private struct RadishIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 90
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 38 * s, y: 36 * s))
                    p.addQuadCurve(to: CGPoint(x: 26 * s, y: 10 * s), control: CGPoint(x: 28 * s, y: 22 * s))
                }
                .stroke(IllusColor.leafDark, lineWidth: 1 * s)
                Path { p in
                    p.move(to: CGPoint(x: 52 * s, y: 36 * s))
                    p.addQuadCurve(to: CGPoint(x: 64 * s, y: 10 * s), control: CGPoint(x: 62 * s, y: 22 * s))
                }
                .stroke(IllusColor.leafDark, lineWidth: 1 * s)
                Path { p in
                    p.move(to: CGPoint(x: 45 * s, y: 36 * s))
                    p.addQuadCurve(to: CGPoint(x: 45 * s, y: 4 * s), control: CGPoint(x: 46 * s, y: 18 * s))
                }
                .stroke(IllusColor.leafDark, lineWidth: 1 * s)
                // Round red body
                Circle()
                    .fill(RadialGradient(colors: [IllusColor.redHi, IllusColor.red, IllusColor.redDark], center: .center, startRadius: 2, endRadius: 20))
                    .frame(width: 36 * s, height: 36 * s).offset(x: 0, y: 22 * s)
                // Taproot
                Path { p in
                    p.move(to: CGPoint(x: 45 * s, y: 64 * s))
                    p.addLine(to: CGPoint(x: 43 * s, y: 84 * s))
                }
                .stroke(IllusColor.white, lineWidth: 0.8 * s)
            }
        }
    }
}

private struct HerbIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 90
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 45 * s, y: 80 * s))
                    p.addLine(to: CGPoint(x: 45 * s, y: 16 * s))
                }
                .stroke(IllusColor.stem, lineWidth: 1.2 * s)
                ForEach(0..<6) { i in
                    let y = CGFloat(20 + i * 10) * s
                    let isLeft = i % 2 == 0
                    Path { p in
                        p.move(to: CGPoint(x: 45 * s, y: y))
                        let endX = (isLeft ? 28 : 62) * s
                        p.addQuadCurve(to: CGPoint(x: endX, y: y - 6 * s),
                                       control: CGPoint(x: (isLeft ? 35 : 55) * s, y: y - 4 * s))
                        p.addQuadCurve(to: CGPoint(x: 45 * s, y: y),
                                       control: CGPoint(x: (isLeft ? 36 : 54) * s, y: y + 2 * s))
                    }
                    .fill(IllusColor.leafLight)
                }
            }
        }
    }
}

private struct FlowerIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 90
            ZStack(alignment: .topLeading) {
                // Stem — from the soil up to under the flower head
                Path { p in
                    p.move(to: CGPoint(x: 45 * s, y: 82 * s))
                    p.addLine(to: CGPoint(x: 45 * s, y: 32 * s))
                }
                .stroke(IllusColor.stem, lineWidth: 1.2 * s)

                // Leaves on the stem
                Path { p in
                    p.move(to: CGPoint(x: 45 * s, y: 60 * s))
                    p.addQuadCurve(to: CGPoint(x: 22 * s, y: 52 * s), control: CGPoint(x: 30 * s, y: 50 * s))
                    p.addQuadCurve(to: CGPoint(x: 45 * s, y: 60 * s), control: CGPoint(x: 30 * s, y: 62 * s))
                }
                .fill(IllusColor.leafLight)
                Path { p in
                    p.move(to: CGPoint(x: 45 * s, y: 66 * s))
                    p.addQuadCurve(to: CGPoint(x: 68 * s, y: 58 * s), control: CGPoint(x: 60 * s, y: 56 * s))
                    p.addQuadCurve(to: CGPoint(x: 45 * s, y: 66 * s), control: CGPoint(x: 60 * s, y: 68 * s))
                }
                .fill(IllusColor.leafLight)

                // Petals — rendered as Path ellipses around the head center
                ForEach(0..<6, id: \.self) { i in
                    let a = Double(i) / 6 * .pi * 2 - .pi / 2
                    Path { p in
                        let cx: CGFloat = 45 * s
                        let cy: CGFloat = 22 * s
                        let r: CGFloat = 9 * s
                        let petalCenterX = cx + CGFloat(cos(a)) * r
                        let petalCenterY = cy + CGFloat(sin(a)) * r
                        p.addEllipse(in: CGRect(
                            x: petalCenterX - 5 * s,
                            y: petalCenterY - 5 * s,
                            width: 10 * s,
                            height: 10 * s
                        ))
                    }
                    .fill(IllusColor.yellow)
                }

                // Flower center
                Path { p in
                    p.addEllipse(in: CGRect(x: 40 * s, y: 17 * s, width: 10 * s, height: 10 * s))
                }
                .fill(IllusColor.orangeDark)
            }
            .frame(width: 90 * s, height: 90 * s)
        }
    }
}

private struct BrassicaIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 90
            ZStack {
                ForEach(0..<8) { i in
                    Path { p in
                        let a = Double(i) / 8 * .pi * 2
                        let cx: CGFloat = 45 * s
                        let cy: CGFloat = 48 * s
                        let tipX = cx + CGFloat(cos(a)) * 26 * s
                        let tipY = cy + CGFloat(sin(a)) * 26 * s
                        let ctrl1X = cx + CGFloat(cos(a + 0.3)) * 22 * s
                        let ctrl1Y = cy + CGFloat(sin(a + 0.3)) * 22 * s
                        let ctrl2X = cx + CGFloat(cos(a - 0.3)) * 22 * s
                        let ctrl2Y = cy + CGFloat(sin(a - 0.3)) * 22 * s
                        p.move(to: CGPoint(x: cx, y: cy))
                        p.addQuadCurve(to: CGPoint(x: tipX, y: tipY), control: CGPoint(x: ctrl1X, y: ctrl1Y))
                        p.addQuadCurve(to: CGPoint(x: cx, y: cy), control: CGPoint(x: ctrl2X, y: ctrl2Y))
                    }
                    .fill(IllusColor.leafLight.opacity(0.7))
                }
                Circle().fill(IllusColor.leafDark).frame(width: 16 * s, height: 16 * s).offset(x: 0, y: 3 * s)
            }
        }
    }
}

private struct RootIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 90
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 38 * s, y: 28 * s))
                    p.addQuadCurve(to: CGPoint(x: 28 * s, y: 6 * s), control: CGPoint(x: 28 * s, y: 18 * s))
                }
                .stroke(IllusColor.leafDark, lineWidth: 1 * s)
                Path { p in
                    p.move(to: CGPoint(x: 50 * s, y: 28 * s))
                    p.addQuadCurve(to: CGPoint(x: 60 * s, y: 6 * s), control: CGPoint(x: 60 * s, y: 18 * s))
                }
                .stroke(IllusColor.leafDark, lineWidth: 1 * s)
                // Bulb body — squat round root
                Path { p in
                    let cx: CGFloat = 44 * s, cy: CGFloat = 54 * s
                    p.move(to: CGPoint(x: cx - 22 * s, y: cy))
                    p.addQuadCurve(to: CGPoint(x: cx, y: cy + 26 * s), control: CGPoint(x: cx - 18 * s, y: cy + 28 * s))
                    p.addQuadCurve(to: CGPoint(x: cx + 22 * s, y: cy), control: CGPoint(x: cx + 18 * s, y: cy + 28 * s))
                    p.addQuadCurve(to: CGPoint(x: cx, y: cy - 18 * s), control: CGPoint(x: cx + 22 * s, y: cy - 16 * s))
                    p.addQuadCurve(to: CGPoint(x: cx - 22 * s, y: cy), control: CGPoint(x: cx - 22 * s, y: cy - 16 * s))
                }
                .fill(LinearGradient(colors: [Color(red: 0.835, green: 0.722, blue: 0.541), Color(red: 0.514, green: 0.380, blue: 0.227)], startPoint: .top, endPoint: .bottom))
            }
        }
    }
}

private struct LeafyGreenIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 90
            ZStack {
                ForEach(0..<5) { i in
                    let a = (Double(i) / 5 - 0.5) * .pi
                    Path { p in
                        let cx: CGFloat = 45 * s, cy: CGFloat = 70 * s
                        p.move(to: CGPoint(x: cx, y: cy))
                        let tipX = cx + CGFloat(cos(a)) * 32 * s
                        let tipY = cy + CGFloat(sin(a)) * 40 * s - 10 * s
                        p.addQuadCurve(to: CGPoint(x: tipX, y: tipY),
                                       control: CGPoint(x: cx + CGFloat(cos(a)) * 22 * s, y: cy + CGFloat(sin(a)) * 20 * s - 16 * s))
                        p.addQuadCurve(to: CGPoint(x: cx, y: cy),
                                       control: CGPoint(x: cx + CGFloat(cos(a + 0.15)) * 14 * s, y: cy + CGFloat(sin(a + 0.15)) * 12 * s))
                    }
                    .fill(IllusColor.leafLight.opacity(0.85))
                }
            }
        }
    }
}

private struct FruitIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 90
            ZStack {
                // Berry cluster
                Circle().fill(LinearGradient(colors: [IllusColor.red, IllusColor.redDark], startPoint: .top, endPoint: .bottom))
                    .frame(width: 26 * s, height: 26 * s).offset(x: -10 * s, y: 30 * s)
                Circle().fill(LinearGradient(colors: [IllusColor.red, IllusColor.redDark], startPoint: .top, endPoint: .bottom))
                    .frame(width: 28 * s, height: 28 * s).offset(x: 10 * s, y: 38 * s)
                // Leaves
                Path { p in
                    p.move(to: CGPoint(x: 45 * s, y: 30 * s))
                    p.addQuadCurve(to: CGPoint(x: 18 * s, y: 12 * s), control: CGPoint(x: 30 * s, y: 18 * s))
                    p.addQuadCurve(to: CGPoint(x: 45 * s, y: 30 * s), control: CGPoint(x: 28 * s, y: 30 * s))
                }
                .fill(IllusColor.leafLight)
                Path { p in
                    p.move(to: CGPoint(x: 45 * s, y: 30 * s))
                    p.addQuadCurve(to: CGPoint(x: 72 * s, y: 12 * s), control: CGPoint(x: 60 * s, y: 18 * s))
                    p.addQuadCurve(to: CGPoint(x: 45 * s, y: 30 * s), control: CGPoint(x: 62 * s, y: 30 * s))
                }
                .fill(IllusColor.leafLight)
            }
        }
    }
}

private struct GenericLeafIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height) / 90
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: 45 * s, y: 80 * s))
                    p.addQuadCurve(to: CGPoint(x: 45 * s, y: 16 * s), control: CGPoint(x: 48 * s, y: 50 * s))
                }
                .stroke(IllusColor.stem, lineWidth: 1.2 * s)
                Path { p in
                    p.move(to: CGPoint(x: 45 * s, y: 14 * s))
                    p.addQuadCurve(to: CGPoint(x: 20 * s, y: 36 * s), control: CGPoint(x: 18 * s, y: 18 * s))
                    p.addQuadCurve(to: CGPoint(x: 45 * s, y: 72 * s), control: CGPoint(x: 22 * s, y: 60 * s))
                    p.addQuadCurve(to: CGPoint(x: 70 * s, y: 36 * s), control: CGPoint(x: 68 * s, y: 60 * s))
                    p.addQuadCurve(to: CGPoint(x: 45 * s, y: 14 * s), control: CGPoint(x: 72 * s, y: 18 * s))
                }
                .fill(LinearGradient(colors: [IllusColor.leafLight, IllusColor.leafDark], startPoint: .topLeading, endPoint: .bottomTrailing))
                // Center vein
                Path { p in
                    p.move(to: CGPoint(x: 45 * s, y: 16 * s))
                    p.addLine(to: CGPoint(x: 45 * s, y: 70 * s))
                }
                .stroke(IllusColor.veinDark.opacity(0.55), lineWidth: 0.6 * s)
                ForEach(0..<4) { i in
                    Path { p in
                        let y = CGFloat(24 + i * 12) * s
                        p.move(to: CGPoint(x: 45 * s, y: y))
                        p.addQuadCurve(to: CGPoint(x: (i % 2 == 0 ? 28 : 62) * s, y: y + 4 * s),
                                       control: CGPoint(x: (i % 2 == 0 ? 38 : 52) * s, y: y))
                    }
                    .stroke(IllusColor.veinDark.opacity(0.4), lineWidth: 0.4 * s)
                }
            }
        }
    }
}
