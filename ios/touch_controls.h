#pragma once
#import <UIKit/UIKit.h>

// Virtual gamepad over the game view, in Nintendo button positions (touch_controls.m explains the two layouts). The layout choice
// (2D / 3D) is kept in the app's user defaults. While a hardware controller is connected only the gear key remains.
@interface ZeldaTouchControls : UIView
- (instancetype)initWithMenu:(void (^)(void))menu;
@property (nonatomic) BOOL playing;   // shown once the game runs
@end
