// VKQSenseController.h — PSVR2 Sense controllers: buttons, and where the hands
// are (docs/VR-CHARTER.md A10, docs/VR-R2-NOTES.md).
//
// This file owns HARDWARE and nothing else: GameController discovery, the
// element inventory, ARKit accessory tracking, per-hand haptics. It reports each
// hand as a raw ARKit pose in TRACKING SPACE, in metres, and never converts
// anything into Quake's world — that conversion belongs to VKQVR.m, which
// already owns the alignment and the world scale the eyes go through. One
// chain, one recenter, one place to be wrong (R2's foundation rule: R3's
// holsters and grip gestures are built on top of this, so it must not sprout a
// second derivation).
#import <simd/simd.h>
#import <stdbool.h>

// Button bits. These MUST match VKQ_VRB_* in patches/0019-visionos-vr-hands.patch
// (gl_vidsdl.c) — the engine lives under vendor/ and cannot include this header,
// so the two lists are kept in step by hand and by the comment on both sides.
#define VKQ_SENSE_TRIGGER (1u << 0)
#define VKQ_SENSE_GRIP	  (1u << 1)
#define VKQ_SENSE_A		  (1u << 2)
#define VKQ_SENSE_B		  (1u << 3)
#define VKQ_SENSE_STICK	  (1u << 4)
#define VKQ_SENSE_MENU	  (1u << 5)

#define VKQ_SENSE_LEFT	0
#define VKQ_SENSE_RIGHT 1

// One hand, as the hardware sees it. Everything in this struct is sampled in the
// same compositor frame, so a consumer never mixes a pose from one instant with
// a button from another.
typedef struct
{
	int			  posed;		 // a tracked pose arrived this frame
	int			  held;			 // ARKit says it is in a hand (not on a table)
	int			  present;		 // a controller is assigned to this hand at all
	simd_float4x4 originFromHand; // tracking space, metres
	simd_float3	  velocity;		 // tracking space, metres/sec (from the anchor)
	unsigned	  buttons;
	float		  trigger, grip;
	float		  stickX, stickY;
} VKQSenseHand;

// Idempotent. Installs the GameController observers and (on the first controller
// of any kind) requests accessory-tracking authorization. Safe to call from
// anywhere, any number of times.
void VKQ_Sense_Start (void);

// Once per compositor frame, from the VR loop, immediately after the head anchor
// is queried — that is what makes hands and head coherent.
void VKQ_Sense_Poll (VKQSenseHand out[2]);

// Buttons and sticks only, no ARKit — the UI/menu/modal path (VR R5 item 1).
// btn[2] receives VKQ_SENSE_* masks; stick[4] is (leftX, leftY, rightX, rightY).
// Returns how many hands answered. Safe from any thread, at host-frame rate.
int VKQ_Sense_UISample (unsigned *btn, float *stick);

// Short burst on one hand. Ignored if that hand has no haptics engine.
// R6 part B2: `why` names the pulse in the diagnostics file, so a device round
// can tell "never fired" from "fired and was too weak to feel".
void VKQ_Sense_Haptic (int hand, float strength, float duration, const char *why);

// The SDL3 filter's predicate (charter A10). Non-zero when `name` — SDL's own
// name for a joystick, which is GCController.vendorName — belongs to a
// spatial-category controller and to no ordinary one. Ordinary gamepads always
// answer 0, which is the whole safety property.
int VKQ_Sense_ShouldIgnoreSDLGamepad (const char *name);

// Settings status rows / diagnostics (charter's no-console-only rule).
const char *VKQ_Sense_StatusControllers (void); // what enumerated, and as what
const char *VKQ_Sense_StatusTracking (void);	// auth, loads, anchors, L/R
// The full element inventory, as logged on connect. Empty until one connects.
const char *VKQ_Sense_InventoryText (void);

// --- simulator coverage -------------------------------------------------------
// The Vision Pro simulator has no controllers at all, so every consumer of a
// hand pose — aim, the weapon, the laser, movement rotation, snap turn — would
// be untestable without injection. Injected hands enter at the SAME boundary a
// real anchor does (VKQ_Sense_Poll's output), in the same tracking space, so the
// sim exercises the real transform chain and the real input code, not a parallel
// one.
void VKQ_Sense_SetSynthHand (int hand, int on, float yaw, float pitch, float roll, float x, float y, float z);
void VKQ_Sense_SetSynthButtons (int hand, unsigned buttons);
void VKQ_Sense_SetSynthStick (int hand, float x, float y);
int	 VKQ_Sense_SynthActive (void);
