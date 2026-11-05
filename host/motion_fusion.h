// Motion fusion for the guest's six-axis sensor (input.c), adapted from nxnative's dm/host/motion_fusion.h (MIT, THIRD_PARTY_NOTICES.md).
// Pure C with no host state, so tests check it on any machine.
// Input: acceleration in G with gravity's direction (CoreMotion and GameController: (0, 0, -1) lying face up) and rotation rate in rad/s,
// already in the Switch frame: x right, y forward (away from the player; the top of the picture for a phone held like a console), z up out
// of the face (toward the player). GameController reports a controller's motion in that frame; the phone's is turned by motion_phone_to_switch.
// Output: the SixAxisSensorState fields: acceleration in G, angular velocity in revolutions/s, angle in revolutions, direction = the
// controller's three axes in the world (rows).
// Orientation: the gyro is integrated (R = R exp(w dt)), and tilt drift is pulled back toward the measured gravity (Mahony, gain k) while
// |acc| is near 1 G; yaw is free to drift, as on the console without a recenter.
#pragma once
#include <math.h>
#include <string.h>

typedef struct {
    float R[3][3];         // controller -> world (columns = the controller's axes in the world)
    float angle[3];        // integrated revolutions per axis
    float acc[3], gyro[3]; // latest sample: G, revolutions / s
    int primed;
} motion_state;

static inline void motion_reset(motion_state *s) {
    memset(s, 0, sizeof *s);
    for (int i = 0; i < 3; i++) s->R[i][i] = 1;
    s->acc[2] = -1;
}
static inline void motion_m3_mul(float o[3][3], const float a[3][3], const float b[3][3]) {
    float t[3][3];
    for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) t[i][j] = a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j];
    memcpy(o, t, sizeof t);
}
static inline void motion_m3_orthonormalize(float R[3][3]) {   // Gram-Schmidt on the columns
    float c[3][3];
    for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) c[j][i] = R[i][j];
    for (int k = 0; k < 3; k++) {
        for (int p = 0; p < k; p++) {
            float d = c[k][0] * c[p][0] + c[k][1] * c[p][1] + c[k][2] * c[p][2];
            for (int i = 0; i < 3; i++) c[k][i] -= d * c[p][i];
        }
        float n = sqrtf(c[k][0] * c[k][0] + c[k][1] * c[k][1] + c[k][2] * c[k][2]);
        if (n < 1e-6f) n = 1;
        for (int i = 0; i < 3; i++) c[k][i] /= n;
    }
    for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) R[i][j] = c[j][i];
}
// One sample: acceleration (G) and rotation rate (rad/s) in the Switch frame; dt in seconds since the previous sample (0 for the first).
// k = tilt correction gain (rad/s per unit error). A non-finite sample is dropped before it can prime or poison the state.
static inline void motion_update(motion_state *s, const float a_in[3], const float w_in[3], float dt, float k) {
    for (int i = 0; i < 3; i++) if (!isfinite(a_in[i]) || !isfinite(w_in[i])) return;
    if (!isfinite(dt) || dt < 0) dt = 0;
    if (!isfinite(k) || k < 0) k = 0;
    float a[3] = {a_in[0], a_in[1], a_in[2]}, w[3] = {w_in[0], w_in[1], w_in[2]};
    if (!s->primed || dt <= 0 || dt > 0.25f) {         // first sample or a gap: no integration step
        if (!s->primed) {                              // start level with the measured gravity, facing forward
            float n = sqrtf(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]);
            if (n > 0.5f && n < 1.5f) {
                // world down (0, 0, -1) = R g_body, so R's third row = -g_body / |g|
                float z[3] = {-a[0] / n, -a[1] / n, -a[2] / n}, y0[3] = {0, 1, 0};
                // Held upright (a phone in the hand), gravity lies along y: take another heading reference before projecting onto the level plane.
                if (fabsf(z[1]) > 0.99f) { y0[0] = 1; y0[1] = 0; }
                float d = y0[0] * z[0] + y0[1] * z[1] + y0[2] * z[2];
                float y[3] = {y0[0] - d * z[0], y0[1] - d * z[1], y0[2] - d * z[2]};
                float yn = sqrtf(y[0] * y[0] + y[1] * y[1] + y[2] * y[2]);
                if (yn > 1e-3f) {
                    for (int i = 0; i < 3; i++) y[i] /= yn;
                    float x[3] = {y[1] * z[2] - y[2] * z[1], y[2] * z[0] - y[0] * z[2], y[0] * z[1] - y[1] * z[0]};
                    for (int j = 0; j < 3; j++) { s->R[0][j] = x[j]; s->R[1][j] = y[j]; s->R[2][j] = z[j]; }
                }
            }
            s->primed = 1;
        }
    } else {
        // tilt correction: predicted gravity in the body = R^T (0, 0, -1) = -(third row of R)
        float n = sqrtf(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]);
        if (k > 0 && n > 0.8f && n < 1.2f) {
            float gm[3] = {a[0] / n, a[1] / n, a[2] / n}, gp[3] = {-s->R[2][0], -s->R[2][1], -s->R[2][2]};
            float e[3] = {gm[1] * gp[2] - gm[2] * gp[1], gm[2] * gp[0] - gm[0] * gp[2], gm[0] * gp[1] - gm[1] * gp[0]};
            for (int i = 0; i < 3; i++) w[i] += k * e[i];
        }
        float th = sqrtf(w[0] * w[0] + w[1] * w[1] + w[2] * w[2]) * dt;
        if (isfinite(th) && th > 1e-9f) {
            float u[3] = {w[0] * dt / th, w[1] * dt / th, w[2] * dt / th}, c = cosf(th), sn = sinf(th), v = 1 - c;
            float E[3][3] = {
                {c + u[0] * u[0] * v,         u[0] * u[1] * v - u[2] * sn, u[0] * u[2] * v + u[1] * sn},
                {u[1] * u[0] * v + u[2] * sn, c + u[1] * u[1] * v,         u[1] * u[2] * v - u[0] * sn},
                {u[2] * u[0] * v - u[1] * sn, u[2] * u[1] * v + u[0] * sn, c + u[2] * u[2] * v}};
            motion_m3_mul(s->R, s->R, E);
            motion_m3_orthonormalize(s->R);
        }
    }
    // The reported angular velocity is the gyro itself (revolutions / s), without the tilt correction term.
    for (int i = 0; i < 3; i++) {
        s->gyro[i] = w_in[i] / (2 * (float)M_PI); s->acc[i] = a[i];
        if (dt > 0 && dt <= 0.25f) { float angle = s->angle[i] + s->gyro[i] * dt; if (isfinite(angle)) s->angle[i] = angle; }
    }
}
// The SixAxisSensorState fields: acc[3], gyro[3], angle[3], dir[9] (rows = the controller's x, y, z axes in the world).
static inline void motion_fill(const motion_state *s, float acc[3], float gyro[3], float angle[3], float dir[9]) {
    for (int i = 0; i < 3; i++) { acc[i] = s->acc[i]; gyro[i] = s->gyro[i]; angle[i] = s->angle[i]; }
    for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) dir[3 * i + j] = s->R[j][i];
}
// The phone's own sensors (CoreMotion: x to the right of the screen in portrait, y to its top, z out of the screen) in the Switch frame for
// how the screen is turned, so a phone held like a Switch in handheld is the console: x to the right of the picture, y to its top, z toward
// the player. orient = UIInterfaceOrientation: 1 portrait, 2 upside down, 3 landscape right (the phone's top to the left), 4 landscape left
// (the phone's top to the right). Proper rotations only, so the same map serves acceleration and rotation rate.
static inline void motion_phone_to_switch(int orient, const float in[3], float out[3]) {
    switch (orient) {
    case 3: out[0] = -in[1]; out[1] = in[0]; out[2] = in[2]; break;
    case 4: out[0] = in[1]; out[1] = -in[0]; out[2] = in[2]; break;
    case 2: out[0] = -in[0]; out[1] = -in[1]; out[2] = in[2]; break;
    default: out[0] = in[0]; out[1] = in[1]; out[2] = in[2]; break;
    }
}
