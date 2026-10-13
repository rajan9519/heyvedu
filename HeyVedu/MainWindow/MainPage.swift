import SwiftUI

/// The frame every sidebar page draws its content in, so all pages share the same padding,
/// width and top-left alignment and nothing shifts when switching between them. A page
/// supplies only its own content.
///
/// Pages must not put controls in the window toolbar (`.searchable(placement: .toolbar)`,
/// `.toolbar { … }`): the toolbar only exists while such a page is shown, so the title bar
/// would grow and shrink on every switch. Keep search fields and actions in the content.
struct MainPage<Content: View>: View {
    enum Layout {
        /// Content fills the window height; the page places its own lists and scroll views.
        case fill
        /// The whole page scrolls, for pages taller than the window.
        case scroll
    }

    static var padding: CGFloat { 24 }
    static var maxContentWidth: CGFloat { 980 }

    var layout: Layout = .fill
    var spacing: CGFloat = 16
    @ViewBuilder let content: Content

    var body: some View {
        switch layout {
        case .fill:
            column
                .frame(maxHeight: .infinity, alignment: .top)
        case .scroll:
            ScrollView { column }
        }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(Self.padding)
        .frame(maxWidth: Self.maxContentWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
}
