#include "hle.h"
#include "input.h"
#include "vibration.h"
#include "motion_fusion.h"
#include <pthread.h>
#include <string.h>
#include <math.h>

_Static_assert(sizeof(ZeldaPadState) == 0x28, "SDK Npad state ABI");
_Static_assert(sizeof(ZeldaSixAxisState) == 0x60, "SDK six-axis state ABI");
static pthread_mutex_t input_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t sampling, latched_buttons;
// The hardware controller and the iOS touch overlay are separate sources, so one never releases the other's input.
typedef struct { uint64_t buttons, latched; int32_t axes[4]; } source_t;
static source_t controller, touch;
static unsigned char keys[128];
static uint32_t styles = 1, player_enabled = 1;
static const struct { unsigned key; uint64_t button; } mapping[] = {
    {7, 1u << 0}, {6, 1u << 1}, {15, 1u << 2}, {3, 1u << 3}, // X/Z/R/F: A/B/X/Y
    {12, 1u << 6}, {14, 1u << 7}, {56, 1u << 8}, {49, 1u << 9},
    {36, 1u << 10}, {48, 1u << 11}, {123, 1u << 12}, {126, 1u << 13},
    {124, 1u << 14}, {125, 1u << 15}, {8, 1u << 4}, {9, 1u << 5},
};
void input_key(unsigned code, int pressed) {
    if (code >= sizeof keys) return;
    pthread_mutex_lock(&input_lock);
    if (pressed && !keys[code]) for (unsigned i = 0; i < sizeof mapping / sizeof *mapping; i++)
        if (mapping[i].key == code) latched_buttons |= mapping[i].button;
    keys[code] = !!pressed;
    pthread_mutex_unlock(&input_lock);
}
void input_clear(void) {
    pthread_mutex_lock(&input_lock); memset(keys, 0, sizeof keys); latched_buttons = 0;
    controller = touch = (source_t){0};
    pthread_mutex_unlock(&input_lock);
}
void input_controller_clear(void) {
    pthread_mutex_lock(&input_lock); controller = (source_t){0}; pthread_mutex_unlock(&input_lock);
}
static void source_set(source_t *source, float dead_zone, uint64_t buttons, float lx, float ly, float rx, float ry) {
    float axes[4] = {lx, ly, rx, ry};
    pthread_mutex_lock(&input_lock);
    buttons &= 0xffff;
    source->latched |= buttons & ~source->buttons; source->buttons = buttons;
    for (unsigned s = 0; s < 2; s++) {
        float x = axes[s * 2], y = axes[s * 2 + 1];
        if (!isfinite(x) || !isfinite(y) || hypotf(x, y) < dead_zone) x = y = 0;
        source->axes[s * 2] = (int32_t)lroundf(fmaxf(-1, fminf(1, x)) * 32767);
        source->axes[s * 2 + 1] = (int32_t)lroundf(fmaxf(-1, fminf(1, y)) * 32767);
    }
    pthread_mutex_unlock(&input_lock);
}
void input_controller(uint64_t buttons, float lx, float ly, float rx, float ry) { source_set(&controller, .12f, buttons, lx, ly, rx, ry); }
// The overlay applies its own dead zone; small camera drags must still reach the game.
void input_touch(uint64_t buttons, float lx, float ly, float rx, float ry) { source_set(&touch, 0, buttons, lx, ly, rx, ry); }
static void source_axes(const source_t *source, ZeldaPadState *out) {
    if (source->axes[0] || source->axes[1]) { out->lx = source->axes[0]; out->ly = source->axes[1]; }
    if (source->axes[2] || source->axes[3]) { out->rx = source->axes[2]; out->ry = source->axes[3]; }
}
// Six-axis sensor. Each source keeps its own orientation; a controller's fresh samples win over the phone's, as a Switch Pro Controller's
// sensor is the one that moves when it is held apart from the console. A source is fresh while its samples keep arriving (MOTION_STALE_NS
// on the host clock); when none is, or motion is switched off, the sensor lies flat and still.
#define MOTION_STALE_NS 300000000ull
#define MOTION_GAIN 0.5f
#define SIX_AXIS_PERIOD_NS 5000000ull   // the console sensor's 200 Hz
static pthread_mutex_t motion_lock = PTHREAD_MUTEX_INITIALIZER;
static struct { motion_state state; uint64_t last_ns; } motion_sources[INPUT_MOTION_SOURCES];
static bool motion_enabled = true;
void input_motion_enable(bool on) {
    pthread_mutex_lock(&motion_lock);
    motion_enabled = on;
    for (unsigned i = 0; i < INPUT_MOTION_SOURCES; i++) motion_sources[i].last_ns = 0;
    pthread_mutex_unlock(&motion_lock);
}
void input_motion(unsigned source, const float acc[3], const float rot[3]) {
    if (source >= INPUT_MOTION_SOURCES) return;
    uint64_t now = now_ns();
    pthread_mutex_lock(&motion_lock);
    if (motion_enabled) {
        motion_state *state = &motion_sources[source].state; uint64_t last = motion_sources[source].last_ns;
        if (!last || now - last > MOTION_STALE_NS) { motion_reset(state); last = 0; }
        motion_update(state, acc, rot, last && now > last ? (float)((double)(now - last) / 1e9) : 0, MOTION_GAIN);
        if (state->primed) motion_sources[source].last_ns = now;
    }
    pthread_mutex_unlock(&motion_lock);
}
void input_motion_clear(unsigned source) {
    if (source >= INPUT_MOTION_SOURCES) return;
    pthread_mutex_lock(&motion_lock); motion_sources[source].last_ns = 0; pthread_mutex_unlock(&motion_lock);
}
int input_six_axis_states(ZeldaSixAxisState *out, int count, uint32_t handle) {
    if (!out || count <= 0) return 0;
    pthread_mutex_lock(&input_lock);
    // Only player 1's FullKey controller is connected (input_states); other handles read as not connected.
    bool connected = (handle & 0xff) == 0 && (handle >> 8 & 0xff) == 0 && player_enabled && (styles & 1);
    pthread_mutex_unlock(&input_lock);
    memset(out, 0, sizeof *out * (size_t)count);
    if (!connected) return 0;
    motion_state state; motion_reset(&state);
    uint64_t now = now_ns();
    pthread_mutex_lock(&motion_lock);
    for (unsigned i = 0; i < INPUT_MOTION_SOURCES; i++)
        if (motion_enabled && motion_sources[i].last_ns && now - motion_sources[i].last_ns <= MOTION_STALE_NS) { state = motion_sources[i].state; break; }
    pthread_mutex_unlock(&motion_lock);
    // Every history entry is the newest sample, numbered by time 5 ms apart, so a game that integrates the samples it has not seen yet
    // covers the time that passed.
    int64_t sampling = (int64_t)(now / SIX_AXIS_PERIOD_NS);
    for (int i = 0; i < count; i++) {
        out[i].delta_ns = SIX_AXIS_PERIOD_NS; out[i].sampling = sampling - i; out[i].attributes = 1;   // IsConnected
        motion_fill(&state, out[i].acc, out[i].gyro, out[i].angle, out[i].dir);
    }
    return count;
}
int input_states(ZeldaPadState *out, int count, uint32_t id, uint32_t style) {
    if (!out || count <= 0) return 0;
    pthread_mutex_lock(&input_lock);
    *out = (ZeldaPadState){.sampling = ++sampling};
    if (id == 0 && player_enabled && (styles & style & 1)) {
        out->buttons = latched_buttons | controller.buttons | controller.latched | touch.buttons | touch.latched;
        latched_buttons = controller.latched = touch.latched = 0;
        for (unsigned i = 0; i < sizeof mapping / sizeof *mapping; i++) if (keys[mapping[i].key]) out->buttons |= mapping[i].button;
        // WASD move; IJKL control the camera, leaving face buttons separate. A deflected stick wins over held keys for
        // its side, so keys held by an input script (or by someone else at the keyboard) never take it from the player;
        // a hardware stick also wins over the touch overlay.
        out->lx = (keys[2] - keys[0]) * 32767; out->ly = (keys[13] - keys[1]) * 32767;
        out->rx = (keys[37] - keys[38]) * 32767; out->ry = (keys[34] - keys[40]) * 32767;
        source_axes(&touch, out); source_axes(&controller, out);
        out->attributes = 3; // Connected and wired.
    }
    pthread_mutex_unlock(&input_lock);
    return 1;
}

// The cheat engine's key mask (cheats.c, Atmosphère's opcodes 8 / C4): the buttons held on every source (bits 0..15) and the
// sticks' directions past half deflection (16..23: left stick left, up, right, down, then the right stick), as the game would
// read them now. Latched taps are left for the game's own read.
uint64_t input_cheat_keys(void) {
    pthread_mutex_lock(&input_lock);
    uint64_t held = controller.buttons | touch.buttons;
    for (unsigned i = 0; i < sizeof mapping / sizeof *mapping; i++) if (keys[mapping[i].key]) held |= mapping[i].button;
    ZeldaPadState axes = {.lx = (keys[2] - keys[0]) * 32767, .ly = (keys[13] - keys[1]) * 32767,
                          .rx = (keys[37] - keys[38]) * 32767, .ry = (keys[34] - keys[40]) * 32767};
    source_axes(&touch, &axes); source_axes(&controller, &axes);
    pthread_mutex_unlock(&input_lock);
    const int32_t half = 16384, a[4] = {axes.lx, axes.ly, axes.rx, axes.ry};
    for (unsigned s = 0; s < 2; s++) {
        if (a[2 * s] < -half) held |= 1ull << (16 + 4 * s);
        if (a[2 * s + 1] > half) held |= 1ull << (17 + 4 * s);
        if (a[2 * s] > half) held |= 1ull << (18 + 4 * s);
        if (a[2 * s + 1] < -half) held |= 1ull << (19 + 4 * s);
    }
    return held & 0xffffff;
}

#define WHY "Host keyboard and GameController supply one FullKey controller"
HLE_FORCE("_ZN2nn3hid14InitializeNpadEv", WHY, void, h_pad_init, void) { input_clear(); }
HLE_FORCE("_ZN2nn3hid22SetSupportedNpadIdTypeEPKjm", WHY, void, h_pad_ids, const uint32_t *ids, uint64_t n) {
    if (n > 10 || (!ids && n)) die("invalid supported controller IDs");
    pthread_mutex_lock(&input_lock); player_enabled = 0;
    for (uint64_t i = 0; i < n; i++) if (ids[i] == 0) player_enabled = 1;
    pthread_mutex_unlock(&input_lock);
}
HLE_FORCE("_ZN2nn3hid24SetSupportedNpadStyleSetENS_4util10BitFlagSetILi32ENS0_12NpadStyleTagEEE", WHY, void, h_pad_styles, uint32_t value) {
    pthread_mutex_lock(&input_lock); styles = value; pthread_mutex_unlock(&input_lock);
}
HLE_FORCE("_ZN2nn3hid15GetNpadStyleSetERKj", WHY, uint32_t, h_pad_style, const uint32_t *id) {
    pthread_mutex_lock(&input_lock); uint32_t result = *id == 0 && player_enabled ? styles & 1 : 0; pthread_mutex_unlock(&input_lock); return result;
}
#define STATES(symbol, name, style) HLE_FORCE(symbol, WHY, int, name, ZeldaPadState *out, int n, const uint32_t *id) { return input_states(out, n, *id, style); }
STATES("_ZN2nn3hid13GetNpadStatesEPNS0_16NpadFullKeyStateEiRKj", h_pad_full, 1)
STATES("_ZN2nn3hid13GetNpadStatesEPNS0_17NpadHandheldStateEiRKj", h_pad_handheld, 2)
STATES("_ZN2nn3hid13GetNpadStatesEPNS0_16NpadJoyDualStateEiRKj", h_pad_dual, 4)
STATES("_ZN2nn3hid13GetNpadStatesEPNS0_16NpadJoyLeftStateEiRKj", h_pad_left, 8)
STATES("_ZN2nn3hid13GetNpadStatesEPNS0_17NpadJoyRightStateEiRKj", h_pad_right, 16)
HLE_FORCE("_ZN2nn3hid18SetNpadJoyHoldTypeENS0_15NpadJoyHoldTypeE", WHY, void, h_pad_hold, int type) { (void)type; }
HLE_FORCE("_ZN2nn3hid14DisconnectNpadERKj", WHY, void, h_pad_disconnect, const uint32_t *id) {
    pthread_mutex_lock(&input_lock); if (*id == 0) player_enabled = 0; pthread_mutex_unlock(&input_lock);
}
HLE_FORCE("_ZN2nn3hid23GetSixAxisSensorHandlesEPNS0_19SixAxisSensorHandleEiRKjNS_4util10BitFlagSetILi32ENS0_12NpadStyleTagEEE", WHY,
          int, h_pad_sensors, uint32_t *out, int n, const uint32_t *id, uint32_t style) {
    if (!out || n <= 0 || !id) return 0;
    // Byte 0 the style's bit number, byte 1 the npad id, byte 2 the device; the styles made of two Joy-Cons have one sensor in each.
    int count = style & 6 ? 2 : 1; if (count > n) count = n;
    for (int i = 0; i < count; i++) out[i] = (uint32_t)(style ? __builtin_ctz(style) : 0) | (*id & 0xff) << 8 | (uint32_t)i << 16;
    LOG("MOTION six-axis handles for controller %u style %#x: %d", *id, style, count);
    return count;
}
HLE_FORCE("_ZN2nn3hid18StartSixAxisSensorERKNS0_19SixAxisSensorHandleE", WHY, void, h_pad_sensor_start, const uint32_t *handle) {
    LOG("MOTION six-axis sensor %#x started", handle ? *handle : 0);
}
HLE_FORCE("_ZN2nn3hid22GetSixAxisSensorStatesEPNS0_18SixAxisSensorStateEiRKNS0_19SixAxisSensorHandleE", WHY,
          int, h_pad_sensor_states, ZeldaSixAxisState *out, int n, const uint32_t *handle) { return input_six_axis_states(out, n, handle ? *handle : ~0u); }
HLE_FORCE("_ZN2nn3hid25GetVibrationDeviceHandlesEPNS0_21VibrationDeviceHandleEiRKjNS_4util10BitFlagSetILi32ENS0_12NpadStyleTagEEE", WHY,
          int, h_pad_vibration, uint32_t *out, int n, const uint32_t *id, uint32_t style) {
    pthread_mutex_lock(&input_lock);
    int count = id && player_enabled ? vibration_handles(out, n, *id, styles & style) : 0;
    pthread_mutex_unlock(&input_lock); return count;
}
// These are separate console HID devices; the host keyboard is already mapped to the controller.
HLE_FORCE("_ZN2nn3hid15InitializeMouseEv", WHY, void, h_mouse_init, void) {}
HLE_FORCE("_ZN2nn3hid18InitializeKeyboardEv", WHY, void, h_keyboard_init, void) {}
HLE_FORCE("_ZN2nn3hid14GetMouseStatesEPNS0_10MouseStateEi", WHY, int, h_mouse_states, void *out, int n) {
    if (n <= 0) return 0; memset(out, 0, 0x28); return 1;
}
HLE_FORCE("_ZN2nn3hid16GetKeyboardStateEPNS0_13KeyboardStateE", WHY, void, h_keyboard_state, void *out) { memset(out, 0, 0x30); }
