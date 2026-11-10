import AppKit
import SwiftUI

/// L'icône de l'app, dessinée en code pour rester reproductible :
///   Tempo --app-icon icon.png   écrit l'image de 1024 × 1024 ; make-icon.sh en tire AppIcon.icns.
/// Elle reprend le style Montre : l'anneau d'usage qui se colore à mesure que le quota s'épuise,
/// l'aiguille du modèle suivi, et l'encoche du rythme.
struct AppIconArt: View {
    private let green = Color(red: 0.20, green: 0.80, blue: 0.42)
    private let yellow = Color(red: 0.98, green: 0.80, blue: 0.20)
    private let orange = Color(red: 1.00, green: 0.55, blue: 0.16)
    private let violet = Color(red: 0.62, green: 0.57, blue: 0.97)

    var body: some View {
        ZStack {
            // Le carré aux coins continus des icônes macOS, avec sa marge et son ombre.
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(
                    colors: [
                        Color(red: 0.22, green: 0.16, blue: 0.45),
                        Color(red: 0.10, green: 0.08, blue: 0.24),
                        Color(red: 0.03, green: 0.22, blue: 0.30),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .overlay(
                    RoundedRectangle(cornerRadius: 185, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 4)
                )
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 14)

            // Piste de l'anneau
            Circle()
                .stroke(Color.white.opacity(0.11), lineWidth: 66)
                .frame(width: 520, height: 520)

            // Usage : du vert vers l'orange. Le dégradé commence 20° avant l'arc, pour que sa jointure
            // tombe dans la partie vide et que le bout arrondi du départ reste d'un vert franc.
            Circle()
                .trim(from: 0, to: 0.62)
                .stroke(
                    AngularGradient(
                        stops: [
                            .init(color: green, location: 0),
                            .init(color: green, location: 0.07),
                            .init(color: yellow, location: 0.37),
                            .init(color: orange, location: 0.675),
                            .init(color: orange, location: 1),
                        ],
                        center: .center,
                        startAngle: .degrees(-20),
                        endAngle: .degrees(340)
                    ),
                    style: StrokeStyle(lineWidth: 66, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: 520, height: 520)

            // Encoche du rythme, à l'extérieur de l'anneau
            Capsule()
                .fill(Color.white.opacity(0.92))
                .frame(width: 18, height: 54)
                .offset(y: -330)
                .rotationEffect(.degrees(241))

            // Aiguille du modèle suivi
            Capsule()
                .fill(LinearGradient(colors: [violet.opacity(0.85), violet], startPoint: .bottom, endPoint: .top))
                .frame(width: 38, height: 210)
                .offset(y: -88)
                .rotationEffect(.degrees(40))
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
            Circle()
                .fill(violet)
                .frame(width: 76, height: 76)
            Circle()
                .fill(Color(red: 0.10, green: 0.08, blue: 0.24))
                .frame(width: 26, height: 26)
        }
        .frame(width: 1024, height: 1024)
    }

    @MainActor
    static func write(to path: String) {
        let renderer = ImageRenderer(content: AppIconArt())
        renderer.scale = 1
        guard
            let image = renderer.cgImage,
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print(path)
    }
}
