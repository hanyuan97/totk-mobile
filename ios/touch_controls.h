#pragma once
#import <UIKit/UIKit.h>
#include <stdbool.h>

// Touch preferences, kept in the app's user defaults (they belong to this device, not to the shared settings file).
typedef struct {
    float opacity;     // controls' opacity, 0.15..1
    float size;        // controls' scale, 0.75..1.35
    float look;        // camera drag speed, 0.3..3
    bool invert_y;     // dragging up tilts the camera stick down
    bool xbox_face;    // A at the bottom (Xbox positions) instead of A on the right (Switch positions)
} ZeldaTouchPreferences;
ZeldaTouchPreferences zelda_touch_preferences(void);
void zelda_touch_store(ZeldaTouchPreferences preferences);

// Switch-style touch controls over the game view. The shoulder, stick-press, + and − keys sit in the black bars beside
// the 16:9 image, clear of the camera cutout; the left half of the screen is a floating movement stick and the right
// half a camera drag area. While a hardware controller is connected only the settings key remains.
@interface ZeldaTouchControls : UIView
- (instancetype)initWithMenu:(void (^)(void))menu;
@property (nonatomic) BOOL playing;   // shown once the game runs
- (void)reloadPreferences;
@end
