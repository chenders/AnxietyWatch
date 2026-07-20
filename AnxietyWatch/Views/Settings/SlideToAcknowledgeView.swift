import SwiftUI

struct SlideToAcknowledgeView: View {
    var title: String = "Slide to dismiss alarm"
    var onAcknowledge: () -> Void

    @State private var offset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.2))
                Text(title)
                    .frame(maxWidth: .infinity)
                    .foregroundColor(.secondary)
                    .font(.subheadline)
                
                Capsule()
                    .fill(Color.red)
                    .frame(width: max(50, 50 + offset))
                
                Circle()
                    .fill(Color.white)
                    .shadow(radius: 2)
                    .frame(width: 46, height: 46)
                    .padding(2)
                    .offset(x: offset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if value.translation.width > 0 {
                                    offset = min(value.translation.width, geo.size.width - 50)
                                }
                            }
                            .onEnded { value in
                                if offset >= geo.size.width - 60 {
                                    onAcknowledge()
                                }
                                withAnimation(.spring()) {
                                    offset = 0
                                }
                            }
                    )
            }
        }
        .frame(height: 50)
    }
}
