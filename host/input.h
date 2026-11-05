#pragma once
#include <stdbool.h>
#include <stdint.h>
typedef struct {
    int64_t sampling;
    uint64_t buttons;
    int32_t lx, ly, rx, ry;
    uint32_t attributes, reserved;
} ZeldaPadState;
void input_key(unsigned code, int pressed);
void input_clear(void);
void input_controller(uint64_t buttons, float lx, float ly, float rx, float ry);
void input_controller_clear(void);
// iOS touch overlay: buttons and sticks (-1..1) as a source separate from the hardware controller.
void input_touch(uint64_t buttons, float lx, float ly, float rx, float ry);
int input_states(ZeldaPadState *out, int count, uint32_t id, uint32_t style);
// nn::hid::SixAxisSensorState: acceleration in G, angular velocity in revolutions/s, angle in revolutions, direction = the controller's
// axes in the world (rows); attributes bit 0 = connected.
typedef struct {
    int64_t delta_ns, sampling;
    float acc[3], gyro[3], angle[3], dir[9];
    uint32_t attributes, reserved;
} ZeldaSixAxisState;
// Motion sources in priority order: a hardware controller's sensors, then the iPhone's own.
enum { INPUT_MOTION_CONTROLLER, INPUT_MOTION_PHONE, INPUT_MOTION_SOURCES };
// A sample in the Switch frame (motion_fusion.h): acceleration in G with gravity's direction (flat face up = 0, 0, -1), rotation in rad/s.
void input_motion(unsigned source, const float acc[3], const float rot[3]);
void input_motion_clear(unsigned source);   // the source stopped; the next sample starts a new orientation
void input_motion_enable(bool on);          // off: the sensor lies flat and still whatever the sources send (setting "motion_controls")
int input_six_axis_states(ZeldaSixAxisState *out, int count, uint32_t handle);
uint64_t input_cheat_keys(void);   // held buttons (0..15) and stick directions (16..23) for the cheat engine
