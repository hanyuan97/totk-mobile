// What Launcher.swift reaches in C: the settings file (host/settings.h) and main.m's cloud-save folder and Play entry points.
#pragma once
#import <Foundation/Foundation.h>
#include "settings.h"

// The chosen iCloud Drive folder's name, nil when cloud saves are off (main.m keeps the folder as a security-scoped bookmark).
NSString *zelda_cloud_folder_name(void);
bool zelda_cloud_store(NSURL *folder);   // remembers the folder; false when it cannot be bookmarked
void zelda_cloud_clear(void);            // cloud saves off
// Play: the launcher has written the settings; starts the game (or shows why it cannot start yet).
void zelda_launcher_play(void);
