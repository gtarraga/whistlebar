import AppKit
import SwiftUI

/// A transparent, nonactivating glyph beside (never over or below) the camera cutout.
final class NotchStatus {
    private let panel: NSPanel
    private let controller: DictationController
    private var screenObserver: NSObjectProtocol?

    init(controller: DictationController) {
        self.controller = controller
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: DictationStatusGlyph(controller: controller))
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.update() }
    }

    deinit {
        if let screenObserver = screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func update(appearance: NSAppearance? = nil) {
        if let appearance = appearance { panel.appearance = appearance }
        guard controller.notchEnabled && (controller.recording || controller.busy) else {
            panel.orderOut(nil)
            return
        }
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let width: CGFloat = 38
        let height: CGFloat
        let x: CGFloat
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            x = controller.notchSide == .left ? left.maxX - width : right.minX
            height = min(screen.safeAreaInsets.top, min(left.height, right.height))
        } else {
            x = screen.frame.midX + (controller.notchSide == .left ? -width : 0)
            height = min(38, max(22, screen.frame.maxY - screen.visibleFrame.maxY))
        }
        panel.setFrame(NSRect(x: x, y: screen.frame.maxY - height,
                              width: width, height: height), display: true)
        panel.orderFrontRegardless()
    }
}

/// The same state and animation in the notch panel and clickable menu-bar item.
struct DictationStatusGlyph: View {
    @ObservedObject var controller: DictationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    private var teal: Color {
        colorScheme == .dark ? Color(red: 51 / 255, green: 212 / 255, blue: 186 / 255)
            : Color(red: 0.02, green: 0.5, blue: 0.43)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || (!controller.recording && !controller.busy))) { timeline in
            Canvas { context, _ in
                let time = reduceMotion ? 0.8 : timeline.date.timeIntervalSinceReferenceDate
                if controller.busy {
                    var spinner = context
                    spinner.translateBy(x: 15, y: 11)
                    spinner.rotate(by: .degrees(time.truncatingRemainder(dividingBy: 1.2) * 300))
                    let ring = Path(ellipseIn: CGRect(x: -6, y: -6, width: 12, height: 12))
                    spinner.stroke(ring, with: .color(teal.opacity(0.2)), lineWidth: 2.5)
                    var arc = Path()
                    arc.addArc(center: .zero, radius: 6, startAngle: .degrees(-90), endAngle: .degrees(180), clockwise: false)
                    spinner.stroke(arc, with: .color(teal), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                } else {
                    let breath = (1 + sin(time * 2)) / 2
                    let voice = controller.recording ? Double(controller.microphoneLevel) : 0
                    let pulse = 0.1 + breath * 0.08
                    let ink = controller.hudWarning && controller.hudNotice != nil ? Color.orange : (colorScheme == .dark ? Color.white : Color.black)
                    for i in 0..<5 {
                        let shape = 0.35 + 0.65 * abs(sin(time * 12 + Double(i) * 1.8))
                        let height = controller.recording ? 2 + pulse * 5 + voice * 15 * shape
                            : 4 + Double(2 - abs(i - 2)) * 3
                        let shake = reduceMotion ? 0 : voice * sin(time * 35) * 0.65
                        let bar = Path(roundedRect: CGRect(x: 4 + Double(i) * 5, y: 11 - height / 2 + shake,
                                                          width: 2.5, height: height), cornerRadius: 1.25)
                        context.fill(bar, with: .color(ink.opacity(controller.recording ? 0.65 + voice * 0.35 : 0.8)))
                    }
                }
            }
            .frame(width: 30, height: 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(controller.message)
    }
}
