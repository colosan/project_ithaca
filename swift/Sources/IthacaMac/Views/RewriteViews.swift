// Rewrite side by side (app-shell spec "다시 쓰기", AppModel+Rewrite.swift): the bar above both sides and the original
// on the left — read only, styled like the manuscript, selectable to copy a line over.
import AppKit
import IthacaDesign
import SwiftUI

/// What is going on and the ways out, above both sides.
struct RewriteBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: T.Space.s100) {
            Icon(.rewrite, size: T.Size.iconSm)
            Text(model.t(.rewriteBanner)).textStyle(.label).lineLimit(1).truncationMode(.tail).help(model.t(.rewriteBanner))
            Spacer(minLength: T.Space.s50)
            if model.rewriteBodyEmpty && !model.editorLocked {
                KitButton(model.t(.rewriteBring), icon: .keepCurrent, variant: .ghost) { model.bringOriginal() }
                    .help(model.t(.rewriteBringHint)).fixedSize()
            }
            KitButton(model.t(.rewriteRevert), icon: .restore, variant: .ghost) { model.revertRewrite() }
                .disabled(model.editorLocked).fixedSize()
            KitButton(model.t(.rewriteDone), icon: .check, variant: .primary) { model.finishRewrite() }.fixedSize()
        }
        .foregroundStyle(Color.inkPrimary)
        .padding(.horizontal, T.Space.s150)
        .padding(.vertical, T.Space.s100)
        .background(RoundedRectangle(cornerRadius: T.Radius.panel).fill(Color.accentSoft))
        .padding(.horizontal, T.Space.s200)
        .padding(.bottom, T.Space.s50)
    }
}

/// The left side: the original's label and count, then its text.
struct OriginalPane: View {
    @Environment(AppModel.self) private var model
    let rewrite: Rewrite
    let sizeClass: T.Layout.SizeClass

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: T.Space.s100) {
                Text(model.t(.rewriteOriginal)).textStyle(.label).foregroundStyle(Color.inkSecondary)
                Text(model.t(.countWithSpaces, ["count": rewrite.count])).textStyle(.caption).foregroundStyle(Color.inkTertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, T.Space.s200)
            .frame(minHeight: T.Size.controlMd)
            OriginalTextView(model: model, text: rewrite.original, sizeClass: sizeClass)
        }
        .background(Color.surfaceList)
    }
}

/// The original's text: the manuscript's look (size, spacing, markup), read only.
struct OriginalTextView: NSViewRepresentable {
    let model: AppModel
    let text: String
    let sizeClass: T.Layout.SizeClass

    final class Coordinator {
        var key: [AnyHashable] = []
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = OriginalNSTextView(usingTextLayoutManager: true)
        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 0
        tv.drawsBackground = false
        tv.isRichText = false
        tv.isEditable = false
        tv.isSelectable = true
        tv.setAccessibilityLabel(model.t(.rewriteOriginal))
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? OriginalNSTextView else { return }
        tv.padX = T.Layout.Editor.paddingX(sizeClass) / 2
        tv.measure = (T.Layout.Editor.measure * model.lineWidth.scale).rounded()
        tv.updateInsets()
        let key: [AnyHashable] = [text, model.textSize, model.lineSpacing, model.markup, model.firstLineIndent]
        guard key != context.coordinator.key else { return }
        context.coordinator.key = key
        tv.string = text
        if let storage = tv.textStorage {
            storage.beginEditing()
            Styles.apply(to: storage, in: NSRange(location: 0, length: storage.length), size: model.textSize, spacing: model.lineSpacing,
                         markup: model.markup, indent: model.firstLineIndent)
            storage.endEditing()
        }
    }
}

/// Centered measure like the manuscript; plain text on copy.
final class OriginalNSTextView: NSTextView {
    var padX: CGFloat = T.Space.s300
    var measure: CGFloat = T.Layout.Editor.measure

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateInsets()
    }

    func updateInsets() {
        let side = max(padX, (bounds.width - measure) / 2)
        if abs(textContainerInset.width - side) > 0.5 { textContainerInset = NSSize(width: side, height: T.Space.s300) }
    }

    override func copy(_ sender: Any?) {
        guard selectedRange().length > 0 else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((string as NSString).substring(with: selectedRange()), forType: .string)
    }
}
