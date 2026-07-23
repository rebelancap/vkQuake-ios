// VKQVisionApp.swift — SwiftUI app entry for the visionOS target.
//
// visionOS requires a SwiftUI `App` to declare an `ImmersiveSpace` (UIKit can't
// open one), so the app entry is SwiftUI — but it only HOSTS the existing
// UIKit/SDL engine (VKQHostViewController boots it) in a WindowGroup, and
// declares the ImmersiveSpace for the stereoscopic 3D mode. All engine/shell
// logic stays in C/ObjC; this file is scene plumbing only.

import SwiftUI
import CompositorServices
import AVFAudio

// Shared bridge the ObjC/C side pokes to open/close the 3D immersive space.
final class VKQAppModel: ObservableObject {
    static let shared = VKQAppModel()
    @Published var immersive = false
    @Published var showSettings = false
    // .mixed = panel in passthrough; .progressive = Digital Crown dials the
    // surroundings dimming ("Dim Surroundings" setting).
    @Published var style: ImmersionStyle = .mixed
}

// Called from VKQHostViewController (button/console cmd paths) to flip the
// SwiftUI state that actually opens/dismisses the space.
@_cdecl("VKQ_SetImmersiveMode")
func VKQ_SetImmersiveMode(_ on: Bool) {
    DispatchQueue.main.async { VKQAppModel.shared.immersive = on }
}

// Placeholder: Crown-dimmable surroundings (progressive immersion) is parked —
// allowing .progressive changes the CompositorServices drawable contract and
// the render loop would need portal-mask support (see ImmersiveSpace note).
@_cdecl("VKQ_SetImmersionDim")
func VKQ_SetImmersionDim(_ dim: Bool) {
}

// In 3D, anchor the app's sound stage to the FRONT of the user — at the panel —
// instead of the (possibly parked-aside) 2D window. Restored on exit.
private func vkqSetAudioFrontStage(_ on: Bool) {
    let session = AVAudioSession.sharedInstance()
    do {
        if on {
            try session.setIntendedSpatialExperience(
                .headTracked(soundStageSize: .medium, anchoringStrategy: .front))
        } else {
            try session.setIntendedSpatialExperience(
                .headTracked(soundStageSize: .automatic, anchoringStrategy: .automatic))
        }
        NSLog("[vkquake] Swift: audio spatial experience -> \(on ? "front" : "automatic")")
    } catch {
        NSLog("[vkquake] Swift: setIntendedSpatialExperience failed: \(error)")
    }
}

// Hosts the UIKit engine bootstrap inside SwiftUI.
struct VKQWindowView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> VKQHostViewController {
        return VKQHostViewController()
    }
    func updateUIViewController(_ vc: VKQHostViewController, context: Context) {}
}

// CompositorServices layer configuration for the immersive (3D) render path.
// Query capabilities so we never request an unsupported combination (that makes
// openImmersiveSpace fail with a generic .error).
struct VKQCompositorConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        let layouts = capabilities.supportedLayouts(options: [])
        // Eye-tracked foveation concentrates rasterization density where the
        // user looks — the same mechanism that keeps system 2D windows crisp.
        // Our panel pass renders with the drawable's rasterization rate map
        // (VKQImmersive.m); enabling it de-blurs the 3D panel. The old
        // "foveation OFF" line was a MoltenVK/Vulkan-era constraint that this
        // native-Metal composite pass never had. CVar-gated for A/B + recovery.
        let fov = capabilities.supportsFoveation && VKQ_Get3DFoveationWanted() != 0
        configuration.isFoveationEnabled = fov
        // TRAP: with LAYERED layout the drawable carries ONE multi-layer rate
        // map, and our per-slice passes always rasterize with layer 0's (left
        // eye's) map — the right eye becomes a head-coupled fisheye. Dedicated
        // layout gives each eye its own texture AND its own rate map, which the
        // texture-map-driven loop targets correctly.
        if fov && layouts.contains(.dedicated) {
            configuration.layout = .dedicated
        } else {
            configuration.layout = layouts.contains(.layered) ? .layered : .dedicated
        }
        configuration.colorFormat = capabilities.supportedColorFormats.first ?? .bgra8Unorm_srgb
        configuration.depthFormat = capabilities.supportedDepthFormats.first ?? .depth32Float
        // Do NOT raise maxRenderQuality — it aborts the compositor at 3D entry
        // (simulator AND device). Foveation alone is the crispness lever.
        NSLog("[vkquake] Swift: compositor configured (layered=\(layouts.contains(.layered)) foveation=\(fov))")
    }
}

// Hosts the UIKit settings table in the SwiftUI sheet: a UIKit modal presented
// directly works in 2D but silently fails over an open ImmersiveSpace
// (quake3e-documented); a SwiftUI sheet presents alongside the 3D panel.
struct VKQSettingsSheet: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        return VKQ_iOS_MakeSettingsNav()
    }
    func updateUIViewController(_ vc: UIViewController, context: Context) {}
}

// Settings "Done" bridge (the UIKit bar button can't dismiss a SwiftUI sheet).
@_cdecl("VKQ_CloseSettingsSheet")
func VKQ_CloseSettingsSheet() {
    DispatchQueue.main.async { VKQAppModel.shared.showSettings = false }
}

// Open the sheet from C (`vkqsettings` console command / test harness).
@_cdecl("VKQ_OpenSettingsSheet")
func VKQ_OpenSettingsSheet() {
    DispatchQueue.main.async { VKQAppModel.shared.showSettings = true }
}

// The window's root View — owns the immersive open/close environment actions
// (only valid inside a View, not the App struct) and the ornament controls.
struct VKQRootView: View {
    @ObservedObject private var model = VKQAppModel.shared
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        VKQWindowView()
            .ignoresSafeArea()
            .onAppear { VKQ_BeaconMark("beacon: VKQRootView appeared (window scene up)") }
            // 3D + settings in a BOTTOM ornament, pushed fully BELOW the window.
            // contentAlignment .top anchors the pill's TOP edge to the window's
            // bottom (quake3e's trick, but downward instead of sideways) — the
            // default center alignment straddled the boundary and overlapped the
            // game content; .padding(.top) adds the clear gap.
            .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
                HStack(spacing: 16) {
                    Button(model.immersive ? "Exit" : "3D") {
                        VKQ_Enter3D(!model.immersive)
                    }
                    Button { model.showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                    }
                }
                .font(.title3) // larger, readable (matching q2repro's button size)
                .buttonStyle(.borderless)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .glassBackgroundEffect()
                .opacity(0.85)
                .padding(.top, 14) // clear gap between the window's bottom edge and the pill
            }
            // WIDE sheet: precision room for the live panel sliders. The header
            // (with Done) is SwiftUI-owned — the UIKit nav bar's Done did not
            // survive presentation from the small parked window, leaving the
            // window-close X as the only exit (which kills the audio session).
            .sheet(isPresented: $model.showSettings) {
                // VStack (bar OWNS its space above the table — the safeAreaInset
                // variant floated translucently over the table's pinned section
                // header, burying the Reset button). Width-only frame: forcing a
                // height taller than the sheet surface makes SwiftUI center-clip
                // the content, which ate the Done bar entirely (D-034).
                VStack(spacing: 0) {
                    HStack {
                        Text("Settings").font(.title3.weight(.semibold))
                        Spacer()
                        Button("Done") { model.showSettings = false }
                            .font(.title3)
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    Divider()
                    VKQSettingsSheet()
                }
                .frame(minWidth: 900)
            }
            .onChange(of: model.immersive) { _, on in
                NSLog("[vkquake] Swift: immersive onChange -> \(on)")
                Task {
                    if on {
                        let r = await openImmersiveSpace(id: "VKQ3D")
                        NSLog("[vkquake] Swift: openImmersiveSpace -> \(String(describing: r))")
                        if case .error = r {
                            // Roll everything back — the engine must not stay
                            // in offscreen mode with the window still visible.
                            VKQ_Enter3D(false)
                        } else {
                            vkqSetAudioFrontStage(true)
                        }
                    } else {
                        await dismissImmersiveSpace()
                        NSLog("[vkquake] Swift: dismissed immersive")
                        vkqSetAudioFrontStage(false)
                        // The window never deactivates under mixed immersion, so
                        // this is the authoritative back-to-2D trigger.
                        VKQ_Exit3DFinalize()
                    }
                }
            }
    }
}

@main
struct VKQVisionApp: App {
    @ObservedObject private var model = VKQAppModel.shared
    init() {
        VKQ_BeaconMark("beacon: VKQVisionApp.init (Swift main running)")
    }
    var body: some Scene {
        WindowGroup {
            VKQRootView()
        }
        ImmersiveSpace(id: "VKQ3D") {
            CompositorLayer(configuration: VKQCompositorConfiguration()) { layerRenderer in
                // This closure runs on the MAIN thread; the frame loop must NOT
                // (it would block the engine's display link -> whole-app freeze).
                NSLog("[vkquake] Swift: CompositorLayer ready — spawning render thread")
                let renderThread = Thread { VKQ_Immersive_Run(layerRenderer) }
                renderThread.name = "VKQ-Immersive"
                renderThread.stackSize = 2 << 20
                renderThread.start()
            }
        }
        // Mixed = panel floats in the real room (passthrough). NOTE: merely
        // ALLOWING .progressive here changes the drawable contract (portal
        // rendering) and cp_drawable_encode_present aborts __BUG_IN_CLIENT__ —
        // Crown-dimming needs real portal support in the render loop first.
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
