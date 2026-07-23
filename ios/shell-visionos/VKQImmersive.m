// VKQImmersive.m — visionOS stereoscopic "3D screen" mode (CompositorServices).
//
// visionOS can't show real-time stereo in a normal 2D window; stereo rendering
// goes through CompositorServices, which vends per-eye Metal drawable textures
// and the ARKit head pose each frame. This file owns that render loop.
//
// Architecture (ported from the PROVEN quake3e-ios implementation — D-019 there,
// D-026 here; adapted for vkQuake's render path):
//   1. The engine renders alternating parallax-offset eyes (overlay patch 0010:
//      view/projection eye offset) into an offscreen "present image" that holds
//      the FULL composite — gamma-corrected scene + HUD + menus. Under MoltenVK
//      that VkImage IS a MTLTexture (VKQ_Get3DPresentMTLTexture, zero copy).
//   2. This loop copies each finished frame into the matching persistent per-eye
//      texture (on THIS Metal queue, so copy + sample are coherent), then draws
//      a world-locked screen quad per eye slice: left eye samples the left
//      render, right eye the right → true stereoscopic depth on a comfortable,
//      head-stable panel. The head pose only places the screen, never the aim.
//
// Hard-won loop shape (do not "simplify"): a frame presented WITHOUT frame
// pacing (cp_frame_predict_timing + cp_time_wait_until) AND a per-frame ARKit
// device anchor set on the drawable is silently never displayed. The drawable's
// depth texture must be cleared/written too — the compositor reprojects on depth
// and rejects frames it can't reproject (q2repro-ios learned that one).

#import "VKQImmersive.h"
#import <Metal/Metal.h>
#import <ARKit/ARKit.h>
#import <simd/simd.h>

// Engine bridge (overlay patch 0010, gl_vidsdl.c).
extern void *VKQ_Get3DPresentMTLTextureForEye (int eye); // 1=left, 2=right
extern int	 VKQ_Get3DEyeDone (void); // eye most recently completed (diagnostics)
extern int	 VKQ_Get3DFrames (void);  // offscreen frames rendered (liveness)
extern int	 VKQ_Get3DMode (void);

// Shell reconcile on Crown/system dismissal (VKQHostViewController.m).
extern void VKQ_Immersive_Ended (void);

volatile int vkq_immStop = 0;
volatile int vkq_immRunning = 0;
int			 vkq_immFrameCount = 0;

// --- world-lock math ---------------------------------------------------------
static simd_float4x4 vkq_translate (float x, float y, float z)
{
	simd_float4x4 m = matrix_identity_float4x4;
	m.columns[3] = simd_make_float4 (x, y, z, 1.0f);
	return m;
}
static simd_float4x4 vkq_scale (float x, float y, float z)
{
	simd_float4x4 m = matrix_identity_float4x4;
	m.columns[0].x = x;
	m.columns[1].y = y;
	m.columns[2].z = z;
	return m;
}

// Screen placement: captured from the head pose once tracking converges, then
// world-locked; recomputed from the frozen head each frame so live tuning of
// distance/size actually moves the panel. Height raises the panel and tilts it
// back toward the viewer (watchable lying down at large heights).
static float vkq_screenDist = 3.6f;	   // metres from the captured head position
static float vkq_screenHalfW = 2.75f;  // half-width, metres
static float vkq_screenHalfH = 1.55f;  // half-height, metres (free panel shape —
									   // the render target re-syncs to this aspect)
static float vkq_screenHeight = 0.0f;  // POSITION: metres above eye level

void VKQ_Set3DPanel (float dist, float halfW, float halfH)
{
	if (dist >= 1.0f && dist <= 8.0f)
		vkq_screenDist = dist;
	if (halfW >= 0.6f && halfW <= 4.0f)
		vkq_screenHalfW = halfW;
	if (halfH >= 0.4f && halfH <= 3.0f) // <=0 (or out of range) = leave unchanged
		vkq_screenHalfH = halfH;
}
void VKQ_Set3DHeight (float h)
{
	if (h >= -1.5f && h <= 10.0f)
		vkq_screenHeight = h;
}

// Re-anchor the panel to the CURRENT head pose (settings "Recenter Screen").
void VKQ_Recenter3D (void);

static bool			 vkq_haveScreenAnchor = false;
static simd_float4x4 vkq_frozenHead;

void VKQ_Recenter3D (void)
{
	vkq_haveScreenAnchor = false; // next tracked frame re-captures the head pose
}

// Surroundings dimming: a per-eye fullscreen black layer with this alpha drawn
// under the panel. 0 = full passthrough (mixed immersion as-is), 1 = pitch
// black "void". Continuous in-app replacement for the Crown immersion dial
// (which requires progressive-style portal rendering — parked, see D-029).
static float vkq_dimLevel = 0.0f;
void VKQ_Set3DDim (float dim)
{
	dim = (dim < 0.0f) ? 0.0f : (dim > 1.0f) ? 1.0f : dim;
	// Response curve (on-device: linear "doesn't really get dark until 80%"):
	// keep the 0-100% control scale but map through 1-(1-d)^2.2 so darkness
	// arrives early — ~78% dark at half slider, ~97% at the 80% default.
	vkq_dimLevel = 1.0f - powf (1.0f - dim, 2.2f);
}

// --- foveation kill switch ---------------------------------------------------
// Persisted via the shared settings store (ios_settings.m) so a bad-config
// recovery survives relaunch; default ON — foveation is the 3D-panel de-blur.
extern float vkq_setting_f (const char *key, float def);
extern void	 vkq_setting_set_f (const char *key, float val);

int VKQ_Get3DFoveationWanted (void)
{
	return vkq_setting_f ("vp3dFoveation", 1.0f) > 0.5f ? 1 : 0;
}
void VKQ_Set3DFoveation (int on)
{
	vkq_setting_set_f ("vp3dFoveation", on ? 1.0f : 0.0f);
}

static simd_float4x4 vkq_make_screen_anchor (simd_float4x4 originFromDevice)
{
	simd_float3 headPos = originFromDevice.columns[3].xyz;
	simd_float3 fwd = -originFromDevice.columns[2].xyz; // gaze forward
	fwd.y = 0.0f;										// level (no pitch/roll)
	float len = simd_length (fwd);
	fwd = (len < 1e-4f) ? simd_make_float3 (0, 0, -1) : fwd / len;

	simd_float3 pos = headPos + fwd * vkq_screenDist;
	pos.y += vkq_screenHeight;
	// Face the head; 'right' stays horizontal (no roll) and never degenerates.
	simd_float3 normal = simd_normalize (headPos - pos);
	simd_float3 up = simd_make_float3 (0, 1, 0);
	simd_float3 right = simd_normalize (simd_cross (up, normal));
	up = simd_cross (normal, right);

	simd_float4x4 m;
	m.columns[0] = simd_make_float4 (right, 0.0f);
	m.columns[1] = simd_make_float4 (up, 0.0f);
	m.columns[2] = simd_make_float4 (normal, 0.0f);
	m.columns[3] = simd_make_float4 (pos, 1.0f);
	return m;
}

// Persistent per-eye copies of the engine's present image (which alternates eyes).
static id<MTLTexture> vkq_eyeCopy[2];

// One-shot fidelity report (on-device: "be exact on maximizing Vision Pro fidelity").
// Measures the ACTUAL supersample ratio instead of estimating it: per-eye drawable
// render pixels (compositor viewport) + FOV (view tangents) give the panel's real
// screen-space footprint; game-texture ÷ footprint = supersample. Written to
// Documents/vp3d-fidelity.log so it's readable over OTA (Files → On My Vision Pro).
static bool vkq_fidelityLogged = false;
static void vkq_log_fidelity (cp_drawable_t drawable, id<MTLTexture> gameTex)
{
	if (vkq_fidelityLogged || gameTex == nil)
		return;
	cp_view_t	view = cp_drawable_get_view (drawable, 0);
	MTLViewport vp = cp_view_texture_map_get_viewport (cp_view_get_view_texture_map (view));
	// FOV from the projection matrix (cp_view_get_tangents is deprecated AND traps
	// on visionOS 2.0). m00 = 2/(l+r), m11 = 2/(t+b), so 1/m00 = mean horizontal
	// tangent — 2*atan of it gives the FOV (exact for a symmetric frustum, <1%
	// off for the Vision Pro's slight cant, which is plenty for a supersample check).
	simd_float4x4 proj = matrix_identity_float4x4;
	if (__builtin_available (visionOS 2.0, *))
		proj = cp_drawable_compute_projection (drawable, cp_axis_direction_convention_right_up_back, 0);
	double m00 = fabs (proj.columns[0].x), m11 = fabs (proj.columns[1].y);
	double fovH = (m00 > 1e-6) ? 2.0 * atan (1.0 / m00) : 0.0; // radians
	double fovV = (m11 > 1e-6) ? 2.0 * atan (1.0 / m11) : 0.0;
	if (vp.width < 1 || vp.height < 1 || fovH < 1e-4 || fovV < 1e-4)
		return;
	double pxPerRadH = vp.width / fovH, pxPerRadV = vp.height / fovV;
	// Panel angular size from its metric size + distance (world-locked plane).
	double panAngH = 2.0 * atan (vkq_screenHalfW / vkq_screenDist);
	double panAngV = 2.0 * atan (vkq_screenHalfH / vkq_screenDist);
	double footH = panAngH * pxPerRadH, footV = panAngV * pxPerRadV;
	double ssH = footH > 1 ? gameTex.width / footH : 0.0;
	double ssV = footV > 1 ? gameTex.height / footV : 0.0;

	NSString *docs = [NSSearchPathForDirectoriesInDomains (NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
	NSString *report = [NSString stringWithFormat:
		@"vkQuake Vision Pro fidelity report\n"
		 "==================================\n"
		 "Compositor drawable (per eye): %.0f x %.0f px  (%.1f MP)\n"
		 "Per-eye FOV: %.1f deg H x %.1f deg V   (%.1f px/deg H)\n"
		 "\n"
		 "Game render target (per eye): %lu x %lu px  (%.1f MP)\n"
		 "Panel angular size: %.1f deg H x %.1f deg V\n"
		 "Panel footprint in drawable: %.0f x %.0f px\n"
		 "\n"
		 "SUPERSAMPLE RATIO: %.2fx H, %.2fx V   (%s)\n"
		 "  >1.0 = supersampling (rendering MORE pixels than the panel shows, then\n"
		 "         downfiltering — crisp). <1.0 = upscaling (soft).\n"
		 "\n"
		 "Note: the drawable above is the system-vended render target, NOT the\n"
		 "physical ~3660x3200/eye micro-OLED panel — the compositor lens-warps the\n"
		 "drawable onto the panel for every app. Rendering the game past ~2x the\n"
		 "footprint yields no visible benefit (past the resolvable limit).\n",
		(double)vp.width, (double)vp.height, vp.width * vp.height / 1e6,
		fovH * 180.0 / M_PI, fovV * 180.0 / M_PI, pxPerRadH * M_PI / 180.0,
		(unsigned long)gameTex.width, (unsigned long)gameTex.height, gameTex.width * gameTex.height / 1e6,
		panAngH * 180.0 / M_PI, panAngV * 180.0 / M_PI, footH, footV,
		ssH, ssV, (ssH >= 1.0 && ssV >= 1.0) ? "supersampling" : "UNDERSAMPLING"];
	[report writeToFile:[docs stringByAppendingPathComponent:@"vp3d-fidelity.log"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
	NSLog (@"[vkquake] fidelity: drawable %.0fx%.0f/eye, game %lux%lu, supersample %.2fx/%.2fx",
		   (double)vp.width, (double)vp.height, (unsigned long)gameTex.width, (unsigned long)gameTex.height, ssH, ssV);
	vkq_fidelityLogged = true;
}

// The screen quad + dim layer: compiled at runtime from the drawable's formats.
static id<MTLRenderPipelineState> vkq_pipeline;
static id<MTLRenderPipelineState> vkq_dimPipeline;
static id<MTLDepthStencilState>	  vkq_depthState;
static id<MTLDepthStencilState>	  vkq_dimDepthState;

// srgbDecode: the engine image is UNORM holding display-ready (sRGB-encoded)
// values; if the drawable expects linear input (an _srgb or float format), the
// shader linearizes so the compositor doesn't double-encode (washed-out panel).
static NSString *const kVKQQuadShader =
	@"#include <metal_stdlib>\n"
	 "using namespace metal;\n"
	 "struct VOut { float4 pos [[position]]; float2 uv; };\n"
	 "vertex VOut vkq_vs(uint vid [[vertex_id]], constant float4x4& mvp [[buffer(0)]]) {\n"
	 "  const float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };\n"
	 "  VOut o; o.pos = mvp * float4(p[vid], 0.0, 1.0);\n"
	 "  o.uv = float2((p[vid].x+1.0)*0.5, 1.0-(p[vid].y+1.0)*0.5);\n"
	 "  return o;\n"
	 "}\n"
	 "fragment float4 vkq_fs(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],\n"
	 "                       constant float& srgbDecode [[buffer(0)]]) {\n"
	 // trilinear + 16x anisotropic: the game texture is downsampled onto the
	 // panel's footprint, so mip_filter::linear kills far-surface minification
	 // shimmer (the real crispness lever above 1:1) and anisotropy sharpens
	 // grazing views. Requires mipmaps on the sampled texture (generated below).
	 "  constexpr sampler s(filter::linear, mip_filter::linear, max_anisotropy(16));\n"
	 "  float4 c = tex.sample(s, in.uv);\n"
	 "  if (srgbDecode > 0.5) c.rgb = pow(c.rgb, float3(2.2));\n"
	 "  return float4(c.rgb, 1.0);\n"
	 "}\n"
	 // surroundings dimming: a clip-space fullscreen layer, black at the given
	 // alpha, drawn under the panel (blended over passthrough)
	 "vertex float4 vkq_dim_vs(uint vid [[vertex_id]]) {\n"
	 "  const float2 p[3] = { float2(-1,-3), float2(3,1), float2(-1,1) };\n"
	 "  return float4(p[vid], 0.9999, 1.0);\n"
	 "}\n"
	 "fragment float4 vkq_dim_fs(constant float& dim [[buffer(0)]]) {\n"
	 "  return float4(0.0, 0.0, 0.0, dim);\n"
	 "}\n";

static void vkq_build_pipeline (id<MTLDevice> dev, MTLPixelFormat colorFmt, MTLPixelFormat depthFmt)
{
	NSError		  *err = nil;
	id<MTLLibrary> lib = [dev newLibraryWithSource:kVKQQuadShader options:nil error:&err];
	if (!lib)
	{
		NSLog (@"[vkquake] imm: shader compile FAILED: %@", err.localizedDescription);
		return;
	}
	MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
	pd.vertexFunction = [lib newFunctionWithName:@"vkq_vs"];
	pd.fragmentFunction = [lib newFunctionWithName:@"vkq_fs"];
	pd.colorAttachments[0].pixelFormat = colorFmt;
	pd.depthAttachmentPixelFormat = depthFmt;
	vkq_pipeline = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
	if (!vkq_pipeline)
	{
		NSLog (@"[vkquake] imm: pipeline FAILED: %@", err.localizedDescription);
		return;
	}
	MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
	dd.depthCompareFunction = MTLCompareFunctionAlways; // only the quad is drawn
	dd.depthWriteEnabled = YES; // real depth so the compositor reprojects the panel
	vkq_depthState = [dev newDepthStencilStateWithDescriptor:dd];

	// dim layer: alpha-blended fullscreen triangle, far depth, no depth write
	MTLRenderPipelineDescriptor *dp = [MTLRenderPipelineDescriptor new];
	dp.vertexFunction = [lib newFunctionWithName:@"vkq_dim_vs"];
	dp.fragmentFunction = [lib newFunctionWithName:@"vkq_dim_fs"];
	dp.colorAttachments[0].pixelFormat = colorFmt;
	dp.colorAttachments[0].blendingEnabled = YES;
	dp.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
	dp.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
	dp.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
	dp.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
	dp.depthAttachmentPixelFormat = depthFmt;
	vkq_dimPipeline = [dev newRenderPipelineStateWithDescriptor:dp error:&err];
	if (!vkq_dimPipeline)
		NSLog (@"[vkquake] imm: dim pipeline FAILED: %@", err.localizedDescription);
	MTLDepthStencilDescriptor *dd2 = [MTLDepthStencilDescriptor new];
	dd2.depthCompareFunction = MTLCompareFunctionAlways;
	dd2.depthWriteEnabled = YES; // deep depth so the compositor reprojects it far away
	vkq_dimDepthState = [dev newDepthStencilStateWithDescriptor:dd2];

	NSLog (@"[vkquake] imm: quad pipeline built (colorFmt=%lu depthFmt=%lu)", (unsigned long)colorFmt, (unsigned long)depthFmt);
}

void VKQ_Immersive_Run (cp_layer_renderer_t layer_renderer)
{
	vkq_immStop = 0;
	vkq_immRunning = 1;
	int notifyEnded = 0; // only a system/Crown dismissal reconciles via Ended

	id<MTLCommandQueue> queue = nil;
	vkq_immFrameCount = 0;
	vkq_haveScreenAnchor = false; // re-center the screen each time 3D is entered
	vkq_eyeCopy[0] = vkq_eyeCopy[1] = nil;

	// ARKit world tracking for the head pose: the compositor reprojects each
	// frame with the device anchor — a frame without one may never display.
	ar_world_tracking_configuration_t wtc = ar_world_tracking_configuration_create ();
	ar_world_tracking_provider_t	  wtp = ar_world_tracking_provider_create (wtc);
	ar_session_t					  arSession = ar_session_create ();
	ar_data_providers_t				  providers = ar_data_providers_create_with_data_providers (wtp, NULL);
	ar_session_run (arSession, providers);

	NSLog (@"[vkquake] imm: render loop started (ARKit world tracking running)");

	int running = 1;
	while (running)
	{
		if (vkq_immStop)
		{
			NSLog (@"[vkquake] imm: stop requested, exiting cleanly (frames=%d)", vkq_immFrameCount);
			running = 0;
			continue;
		}
		switch (cp_layer_renderer_get_state (layer_renderer))
		{
		case cp_layer_renderer_state_paused:
			cp_layer_renderer_wait_until_running (layer_renderer);
			continue;
		case cp_layer_renderer_state_invalidated:
			NSLog (@"[vkquake] imm: layer invalidated, exiting loop (frames=%d)", vkq_immFrameCount);
			notifyEnded = 1; // Crown dismiss: reconcile shell + SwiftUI state
			running = 0;
			continue;
		case cp_layer_renderer_state_running:
		default:
			break;
		}

		// This render thread has no runloop pool; drain per-frame ObjC allocations.
		@autoreleasepool
		{
			cp_frame_t frame = cp_layer_renderer_query_next_frame (layer_renderer);
			if (frame == NULL)
				continue;

			cp_frame_timing_t timing = cp_frame_predict_timing (frame);
			cp_frame_start_update (frame);
			cp_frame_end_update (frame);
			// Pace to the compositor cadence — without this the loop free-runs and
			// presented frames are not displayed.
			cp_time_wait_until (cp_frame_timing_get_optimal_input_time (timing));

			cp_frame_start_submission (frame);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
			// singular query_drawable: available since 1.0 (plural is 26.0-only)
			cp_drawable_t drawable = cp_frame_query_drawable (frame);
#pragma clang diagnostic pop
			if (drawable == NULL)
			{
				cp_frame_end_submission (frame);
				continue;
			}

			if (queue == nil)
			{
				// The queue MUST come from the drawable's own device (compositor
				// device) — MTLCreateSystemDefaultDevice mismatch aborts.
				id<MTLTexture> t0 = cp_drawable_get_color_texture (drawable, 0);
				queue = [t0.device newCommandQueue];
				vkq_build_pipeline (t0.device, t0.pixelFormat, cp_drawable_get_depth_texture (drawable, 0).pixelFormat);
				NSLog (@"[vkquake] imm: drawable %lux%lu views=%zu colorFmt=%lu", (unsigned long)t0.width, (unsigned long)t0.height,
					   cp_drawable_get_view_count (drawable), (unsigned long)t0.pixelFormat);
			}

			// Head pose at this frame's presentation time -> compositor reprojection.
			CFTimeInterval presTime =
				cp_time_to_cf_time_interval (cp_frame_timing_get_presentation_time (cp_drawable_get_frame_timing (drawable)));
			ar_device_anchor_t			  anchor = ar_device_anchor_create ();
			ar_device_anchor_query_status_t anchorStatus = ar_world_tracking_provider_query_device_anchor_at_timestamp (wtp, presTime, anchor);
			cp_drawable_set_device_anchor (drawable, anchor);

			// Anchor the screen once tracking has CONVERGED — the first frames
			// return a near-identity pose (panel on the floor otherwise).
			if (!vkq_haveScreenAnchor && anchorStatus == ar_device_anchor_query_status_success && vkq_immFrameCount > 30)
			{
				vkq_frozenHead = ar_device_anchor_get_origin_from_anchor_transform (anchor);
				vkq_haveScreenAnchor = true;
				NSLog (@"[vkquake] imm: screen anchored at head (%.2f,%.2f,%.2f)", vkq_frozenHead.columns[3].x, vkq_frozenHead.columns[3].y,
					   vkq_frozenHead.columns[3].z);
			}

			id<MTLCommandBuffer> command_buffer = [queue commandBuffer];

			// Copy BOTH per-eye present images into this loop's sampling copies.
			// The copies run on THIS queue so the later sample is coherent. In
			// both-eyes mode each image refreshes every host frame (full rate,
			// zero inter-eye lag); the alternating fallback refreshes them on
			// alternate frames.
			id<MTLTexture> monoTex = nil; // any live source (aspect + fallback)
			for (int e = 0; e < 2; e++)
			{
				id<MTLTexture> src = (__bridge id<MTLTexture>)VKQ_Get3DPresentMTLTextureForEye (e + 1);
				if (!src)
					continue;
				monoTex = src;
				if (vkq_eyeCopy[e] == nil || vkq_eyeCopy[e].width != src.width || vkq_eyeCopy[e].height != src.height ||
					vkq_eyeCopy[e].pixelFormat != src.pixelFormat)
				{
					// MIPMAPPED copy: the panel downsamples this onto its footprint,
					// so a mip chain (regenerated each frame) removes minification
					// aliasing. renderTarget usage is required by generateMipmaps.
					MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat
																								   width:src.width
																								  height:src.height
																							   mipmapped:YES];
					td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
					td.storageMode = MTLStorageModePrivate;
					vkq_eyeCopy[e] = [src.device newTextureWithDescriptor:td];
				}
				id<MTLBlitCommandEncoder> blit = [command_buffer blitCommandEncoder];
				[blit copyFromTexture:src toTexture:vkq_eyeCopy[e]]; // fills mip 0
				if (vkq_eyeCopy[e].mipmapLevelCount > 1)
					[blit generateMipmapsForTexture:vkq_eyeCopy[e]]; // fills mips 1..N
				[blit endEncoding];
			}
			int eyeDone = VKQ_Get3DEyeDone ();

			id<MTLTexture> color = cp_drawable_get_color_texture (drawable, 0); // format probe only
			size_t		   views = cp_drawable_get_view_count (drawable);

			simd_float4x4 placement =
				vkq_haveScreenAnchor ? vkq_make_screen_anchor (vkq_frozenHead) : vkq_translate (0.0f, 0.0f, -vkq_screenDist);
			// The panel's shape is the user's (width × height); the render
			// target re-syncs to the same aspect on slider release, so the
			// image stretches only transiently while dragging.
			simd_float4x4 model = simd_mul (placement, vkq_scale (vkq_screenHalfW, vkq_screenHalfH, 1.0f));
			simd_float4x4 originFromDevice = ar_device_anchor_get_origin_from_anchor_transform (anchor);

			// Measure the real supersample ratio once, after the panel is placed.
			if (vkq_haveScreenAnchor && vkq_immFrameCount > 60)
				vkq_log_fidelity (drawable, monoTex);

			// Engine image is UNORM w/ sRGB-encoded values; linearize when the
			// drawable wants linear input.
			float srgbDecode = 0.0f;
			if (monoTex)
			{
				MTLPixelFormat sf = monoTex.pixelFormat, df = color.pixelFormat;
				BOOL srcEncoded = (sf == MTLPixelFormatBGRA8Unorm || sf == MTLPixelFormatRGBA8Unorm);
				BOOL dstLinear = (df == MTLPixelFormatBGRA8Unorm_sRGB || df == MTLPixelFormatRGBA8Unorm_sRGB ||
								  df == MTLPixelFormatRGBA16Float);
				srgbDecode = (srcEncoded && dstLinear) ? 1.0f : 0.0f;
			}

			for (size_t v = 0; v < views; v++)
			{
				// Layout-agnostic per-view targeting via the view's texture map
				// (dedicated layout: a texture per view, slice 0; layered:
				// texture 0, slice per view). With foveation each DEDICATED view
				// carries its OWN rasterization rate map, indexed by the view's
				// texture index — attaching the wrong eye's map is the "right eye
				// fisheye that warps with head motion" trap. Never hardcode
				// texture 0 / slice v.
				cp_view_t			  view = cp_drawable_get_view (drawable, v);
				cp_view_texture_map_t tmap = cp_view_get_view_texture_map (view);
				size_t				  texIdx = cp_view_texture_map_get_texture_index (tmap);
				size_t				  slice = cp_view_texture_map_get_slice_index (tmap);
				MTLViewport			  vp = cp_view_texture_map_get_viewport (tmap);

				MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
				pass.colorAttachments[0].texture = cp_drawable_get_color_texture (drawable, texIdx);
				pass.colorAttachments[0].slice = slice;
				pass.colorAttachments[0].loadAction = MTLLoadActionClear;
				pass.colorAttachments[0].storeAction = MTLStoreActionStore;
				pass.colorAttachments[0].clearColor = MTLClearColorMake (0.0, 0.0, 0.0, 0.0);
				// Foveation: attach this view's rasterization rate map. Count is 0
				// when foveation is off (e.g. the simulator), so this is nil-safe.
				size_t rmCount = cp_drawable_get_rasterization_rate_map_count (drawable);
				if (rmCount > 0)
					pass.rasterizationRateMap =
						cp_drawable_get_rasterization_rate_map (drawable, texIdx < rmCount ? texIdx : 0);
				id<MTLTexture> depthTex = cp_drawable_get_depth_texture (drawable, texIdx);
				if (depthTex)
				{
					pass.depthAttachment.texture = depthTex;
					pass.depthAttachment.slice = slice;
					pass.depthAttachment.loadAction = MTLLoadActionClear;
					pass.depthAttachment.storeAction = MTLStoreActionStore;
					pass.depthAttachment.clearDepth = 1.0;
				}
				// This eye's texture: its own stereo image if ready, else the live frame.
				id<MTLTexture> tex = (v < 2 && vkq_eyeCopy[v]) ? vkq_eyeCopy[v] : monoTex;

				id<MTLRenderCommandEncoder> enc = [command_buffer renderCommandEncoderWithDescriptor:pass];
				// Foveation contract: rasterize in the view's LOGICAL viewport
				// (from the texture map); the rate map compresses it to physical.
				[enc setViewport:vp];
				// Surroundings dimming under the panel (0 = passthrough, 1 = void).
				float dimNow = vkq_dimLevel;
				if (dimNow > 0.003f && vkq_dimPipeline)
				{
					[enc setRenderPipelineState:vkq_dimPipeline];
					[enc setDepthStencilState:vkq_dimDepthState];
					[enc setFragmentBytes:&dimNow length:sizeof (dimNow) atIndex:0];
					[enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
				}
				if (tex && vkq_pipeline)
				{
					simd_float4x4 deviceFromEye = cp_view_get_transform (view);
					simd_float4x4 eyeFromOrigin = simd_inverse (simd_mul (originFromDevice, deviceFromEye));
					simd_float4x4 proj = matrix_identity_float4x4;
					if (__builtin_available (visionOS 2.0, *))
						proj = cp_drawable_compute_projection (drawable, cp_axis_direction_convention_right_up_back, v);
					simd_float4x4 mvp = simd_mul (proj, simd_mul (eyeFromOrigin, model));

					[enc setRenderPipelineState:vkq_pipeline];
					[enc setDepthStencilState:vkq_depthState];
					[enc setVertexBytes:&mvp length:sizeof (mvp) atIndex:0];
					[enc setFragmentBytes:&srgbDecode length:sizeof (srgbDecode) atIndex:0];
					[enc setFragmentTexture:tex atIndex:0];
					[enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
				}
				[enc endEncoding];
			}

			cp_drawable_encode_present (drawable, command_buffer);
			[command_buffer commit];

			vkq_immFrameCount++;
			if (vkq_immFrameCount == 3 || (vkq_immFrameCount % 600) == 0)
				NSLog (@"[vkquake] imm: frame %d — engine %lux%lu eyeDone=%d rendFrames=%d eyeL=%d eyeR=%d srgbDecode=%.0f",
					   vkq_immFrameCount, (unsigned long)(monoTex ? monoTex.width : 0), (unsigned long)(monoTex ? monoTex.height : 0),
					   eyeDone, VKQ_Get3DFrames (), (int)(vkq_eyeCopy[0] != nil), (int)(vkq_eyeCopy[1] != nil), srgbDecode);

			cp_frame_end_submission (frame);
		} // @autoreleasepool
	}

	vkq_eyeCopy[0] = vkq_eyeCopy[1] = nil;
	if (notifyEnded)
		VKQ_Immersive_Ended (); // Crown/system dismissal path only
	vkq_immRunning = 0;			// signal the shell LAST, after cleanup
}
