#pragma once
#include <stdbool.h>
void gamepad_start(void);
void gamepad_active(bool active);
void gamepad_stop(void);
void gamepad_vibration_mode(int mode);   // ZELDA_VIBRATION_*
bool gamepad_test_vibration(void);       // short pulse on every motor; false without a controller reporting haptics
void gamepad_describe(char *name, unsigned size, bool *haptics);   // empty name when no controller is connected
// Gyro aiming (setting "motion_controls"): a controller's gyro, or on the iPhone the phone's own while no controller sends motion, drives the
// game's six-axis sensor; off, the sensors stop and the game's sensor lies flat. gamepad_has_motion: the connected controller has a gyro.
void gamepad_motion(bool on);
bool gamepad_has_motion(void);
