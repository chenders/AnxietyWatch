import SwiftUI

/// Album artwork with deterministic bundled-style treatments for fictional
/// demo songs and remote artwork for real catalog results.
struct SongAlbumArtView: View {
    let urlString: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let urlString, urlString.hasPrefix("demo://") {
                demoCover(String(urlString.dropFirst("demo://".count)))
            } else if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { placeholder }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: max(6, size * 0.1)))
        .accessibilityHidden(true)
    }

    private func demoCover(_ key: String) -> some View {
        ZStack {
            LinearGradient(colors: colors(key), startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().stroke(.white.opacity(0.35), lineWidth: max(1, size * 0.025))
                .frame(width: size * 0.58)
            Circle().fill(.black.opacity(0.28)).frame(width: size * 0.16)
            Image(systemName: key == "paper-satellites" ? "paperplane.fill" : key == "static-summer" ? "waveform" : "moon.stars.fill")
                .font(.system(size: size * 0.24, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .offset(y: -size * 0.27)
            Text(key == "paper-satellites" ? "SMALL\nSIGNALS" : key == "static-summer" ? "LOW TIDE\nRADIO" : "AFTER\nMIDNIGHT")
                .font(.system(size: size * 0.09, weight: .heavy, design: .rounded))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .offset(y: size * 0.29)
        }
    }

    private func colors(_ key: String) -> [Color] {
        switch key {
        case "paper-satellites": return [.indigo, .cyan, .black]
        case "static-summer": return [.orange, .pink, .purple]
        default: return [.blue, .indigo, .black]
        }
    }

    private var placeholder: some View {
        Image(systemName: "music.note")
            .font(.system(size: size * 0.34))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(.quaternary, in: .rect(cornerRadius: max(6, size * 0.1)))
    }
}
