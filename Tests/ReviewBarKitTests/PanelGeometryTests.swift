import CoreGraphics
import Testing
@testable import ReviewBarKit

@Suite struct PanelGeometryTests {
    // 14" MacBook Pro-ish numbers: 1512×982 points, 38pt menu bar/notch.
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)

    @Test func notchRectFromAuxiliaryAreas() {
        let notch = PanelGeometry.notchRect(
            screenFrame: screen, safeAreaTop: 38,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 944, width: 656, height: 38),
            auxiliaryTopRightArea: CGRect(x: 856, y: 944, width: 656, height: 38))
        #expect(notch == CGRect(x: 656, y: 944, width: 200, height: 38))
    }

    @Test func notchRectFallsBackToCenteredWidth() {
        let notch = PanelGeometry.notchRect(
            screenFrame: screen, safeAreaTop: 38,
            auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: nil)
        #expect(notch?.width == PanelGeometry.fallbackNotchWidth)
        #expect(notch?.midX == screen.midX)
        #expect(notch?.maxY == screen.maxY)
    }

    @Test func noNotchWithoutSafeArea() {
        let notch = PanelGeometry.notchRect(
            screenFrame: screen, safeAreaTop: 0,
            auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: nil)
        #expect(notch == nil)
    }

    @Test func windowFrameHugsNotchedScreenTop() {
        let geometry = PanelGeometry(
            screenFrame: screen, visibleFrame: visible,
            notch: CGRect(x: 656, y: 944, width: 200, height: 38))
        let frame = geometry.windowFrame(size: CGSize(width: 540, height: 800))
        #expect(frame.maxY == screen.maxY)
        #expect(frame.midX == 756)
        #expect(frame.size == CGSize(width: 540, height: 800))
    }

    @Test func virtualNotchStandsInOnNotchlessScreens() {
        let external = PanelGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1415),
            notch: nil)
        let virtual = external.virtualNotch
        #expect(virtual.midX == 1280)
        #expect(virtual.maxY == 1440)
        #expect(virtual.height == 25)  // menu bar thickness
        #expect(virtual.width == PanelGeometry.fallbackNotchWidth)
        #expect(external.adoptingVirtualNotch.notch == virtual)

        // A real notch is never replaced.
        let notched = PanelGeometry(
            screenFrame: screen, visibleFrame: visible,
            notch: CGRect(x: 656, y: 944, width: 200, height: 38))
        #expect(notched.adoptingVirtualNotch == notched)
    }

    @Test func windowFrameAnchorsUnderMenuIconWithoutNotch() {
        let geometry = PanelGeometry(
            screenFrame: screen, visibleFrame: visible, notch: nil)
        // Window is 540 wide but its visible content is 420, centered.
        let anchored = geometry.windowFrame(
            size: CGSize(width: 540, height: 800), anchorX: 1300, contentWidth: 420)
        #expect(anchored.midX == 1294)  // clamped: 1512 - 420/2 - 8
        // An anchor with room stays put; the notch overrides any anchor.
        let free = geometry.windowFrame(
            size: CGSize(width: 540, height: 800), anchorX: 900, contentWidth: 420)
        #expect(free.midX == 900)
        let notched = PanelGeometry(
            screenFrame: screen, visibleFrame: visible,
            notch: CGRect(x: 656, y: 944, width: 200, height: 38))
        let pinned = notched.windowFrame(
            size: CGSize(width: 540, height: 800), anchorX: 1300, contentWidth: 420)
        #expect(pinned.midX == 756)
    }

    @Test func windowFrameFloatsBelowMenuBarWithoutNotch() {
        let geometry = PanelGeometry(
            screenFrame: screen, visibleFrame: visible, notch: nil)
        let frame = geometry.windowFrame(size: CGSize(width: 540, height: 800))
        #expect(frame.maxY == visible.maxY - PanelGeometry.floatingTopMargin)
        #expect(frame.midX == visible.midX)
        #expect(geometry.hasNotch == false)
    }
}
