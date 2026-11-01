#pragma once
#import <UIKit/UIKit.h>

// The in-game settings menu: touch control layout and feel, frame rate, render resolution, background shader
// compilation, sound and the performance panel. Each change applies at once and is saved; `changed` runs after every change so the caller can refresh.
UIViewController *zelda_settings_sheet(void (^changed)(void));
