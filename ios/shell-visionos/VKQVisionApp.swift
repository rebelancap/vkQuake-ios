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
    // --- VR mode (docs/VR-CHARTER.md A1) ---
    // The model is TRI-STATE now: `immersive` owns the 3D panel space, `vr` owns
    // the VR space. They are separate ImmersiveSpaces because visionOS fixes a
    // space's immersion-style SET at compile time, and the two modes want
    // different ones: the panel is `.mixed`-only, VR is `.full`-only (R1.1).
    // VKQ3D's declaration is untouched: R0 proved declaring another space leaves
    // it regression-free.
    @Published var vr = false
    // Show the user's real hands through the full-immersion VR space. Default OFF
    // (the user, 2026-08-10): holding PSVR2 Sense controllers, ghost passthrough
    // hands read wrong. Kept as an option for gamepad players.
    @Published var vrHands = false
}

// C bridge for VR (VKQHostViewController.m).
@_cdecl("VKQ_SetVRSpace")
func VKQ_SetVRSpace(_ on: Int32) {
    DispatchQueue.main.async { VKQAppModel.shared.vr = (on != 0) }
}

// Show/hide the user's real hands inside the full-immersion VR space (the user,
// 2026-08-10). The passthrough/Full toggle it replaces is gone: VR is always
// full immersion now, so there is no surroundings choice left to make.
@_cdecl("VKQ_SetVRHandsSwift")
func VKQ_SetVRHandsSwift(_ show: Bool) {
    DispatchQueue.main.async {
        VKQAppModel.shared.vrHands = show
        NSLog("[vkquake] vr: hands -> \(show ? "visible" : "hidden")")
    }
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

// --- VR audio: HEAD-LOCKED, i.e. not spatialised by the OS at all (R5 item 7) --
//
// the user, in the headset: the sound comes from wherever the parked "Playing in
// VR" window is sitting. That is exactly what the system is supposed to do — an
// app's audio is spatialised at its scene, and in VR the app's only regular
// scene is a small card parked off to one side of the room.
//
// It is also exactly wrong for this app, because Quake ALREADY spatialises. The
// engine's mixer pans and attenuates every sound against the in-game listener,
// which in VR is the player's head (charter A3's eye point). Letting the OS
// re-spatialise that stereo mix against a window applies a second, unrelated
// rotation on top of the correct one — a shot from the player's right pans right
// in the mix and is then re-anchored to a card behind their left shoulder.
//
// `.bypassed` is the request for "deliver my channels to the ears untouched".
// The mix then reaches the ears head-locked, and the only directionality left is
// the engine's own, which is the true one. The 3D panel keeps `.front` (its
// listener really is a fixed screen in the room) and 2D keeps `.automatic`.
private func vkqSetAudioBypassed(_ on: Bool) {
    let session = AVAudioSession.sharedInstance()
    do {
        if on {
            try session.setIntendedSpatialExperience(.bypassed)
        } else {
            try session.setIntendedSpatialExperience(
                .headTracked(soundStageSize: .automatic, anchoringStrategy: .automatic))
        }
        NSLog("[vkquake] Swift: audio spatial experience -> \(on ? "BYPASSED (head-locked; the engine pans)" : "automatic")")
    } catch {
        NSLog("[vkquake] Swift: setIntendedSpatialExperience(bypassed=\(on)) failed: \(error)")
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
                    // Tri-state controls (charter §2): "3D" and "VR" in the flat
                    // window; inside either immersive mode its own button becomes
                    // "Exit". Pressing the OTHER one switches directly — the mode
                    // sequencer dismisses the open space first.
                    Button(model.immersive ? "Exit" : "3D") {
                        VKQ_EnterMode(model.immersive ? Int32(VKQ_MODE_2D) : Int32(VKQ_MODE_3D))
                    }
                    Button(model.vr ? "Exit" : "VR") {
                        VKQ_EnterMode(model.vr ? Int32(VKQ_MODE_2D) : Int32(VKQ_MODE_VR))
                    }
                    Button { model.showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                    }
                }
                .font(.title3) // larger, readable (matches q2repro's button size)
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
            // VR space open/dismiss. Same shape as the 3D panel's, with the VR
            // finalize (comfort-cvar restore + diagnostics flush) on the way out.
            .onChange(of: model.vr) { _, on in
                NSLog("[vkquake] Swift: vr onChange -> \(on)")
                Task {
                    if on {
                        let r = await openImmersiveSpace(id: "VKQVR")
                        NSLog("[vkquake] Swift: openImmersiveSpace(VKQVR) -> \(String(describing: r))")
                        if case .error = r {
                            // Never leave the engine in offscreen VR mode with the
                            // window still visible.
                            VKQ_EnterMode(Int32(VKQ_MODE_2D))
                        } else {
                            // R5 item 7: head-locked, NOT head-tracked. The engine
                            // already pans against the head; a second spatialisation
                            // anchored the whole mix to the parked window.
                            vkqSetAudioBypassed(true)
                        }
                    } else {
                        await dismissImmersiveSpace()
                        NSLog("[vkquake] Swift: dismissed VR space")
                        // Restore before the finalize, so a subsequent 3D entry
                        // starts from the same state a fresh launch would.
                        vkqSetAudioBypassed(false)
                        VKQ_ExitVRFinalize()
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

        // --- VR: the world surrounds the player (docs/VR-CHARTER.md R1) -------
        // Its OWN space with the SAME CompositorLayer configuration as VKQ3D
        // (charter A1: the foveation + .dedicated layout rules carry over
        // verbatim, and re-deriving them would be a way to get the right-eye
        // fisheye back).
        //
        // FULL IMMERSION ONLY (the user, 2026-08-10, overriding charter §2's
        // surroundings choice): VR means the world, not the world hovering in the
        // living room. The {.mixed, .full} set and its live switch are gone; R0
        // proved full-only opens and presents cleanly. .progressive stays banned.
        // VKQ3D is deliberately untouched — the 3D panel keeps mixed + dimming.
        ImmersiveSpace(id: "VKQVR") {
            CompositorLayer(configuration: VKQCompositorConfiguration()) { layerRenderer in
                NSLog("[vkquake] Swift: VR CompositorLayer ready — spawning render thread")
                let t = Thread { VKQ_VR_Run(layerRenderer) }
                t.name = "VKQ-VR"
                t.stackSize = 2 << 20
                t.start()
            }
        }
        .immersionStyle(selection: .constant(.full), in: .full)
        // Hands hidden by default: a player holding Sense controllers sees ghost
        // limbs where the weapon should be. "Show Hands" in settings flips it.
        .upperLimbVisibility(model.vrHands ? .visible : .hidden)
    }
}
