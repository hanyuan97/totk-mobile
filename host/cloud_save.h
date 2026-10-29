#pragma once
#include <stdbool.h>

// Keeps work/save in step with a shared folder (iCloud Drive) without touching the live transaction: each device
// publishes its own <device>.zmsave archive and <device>.json manifest, and only ever reads the others'.
#ifdef __OBJC__
#import <Foundation/Foundation.h>
// Offers diverged saves; the front end calls `done` once with the chosen index, from any thread.
typedef void (^cloud_save_chooser)(NSArray<NSString *> *titles, void (^done)(NSUInteger index));
typedef void (^cloud_save_status)(NSString *text);
// Starts the startup sync in the background. A nil directory leaves sync off.
void cloud_save_begin(NSURL *directory, NSString *device_name, cloud_save_chooser choose, cloud_save_status status);
NSURL *cloud_save_default_directory(void);   // macOS: iCloud Drive/Zelda-Mobile, or ZELDA_CLOUD_SAVE (a path or "off").

// Exposed for tests.
enum { CLOUD_SAVE_KEEP, CLOUD_SAVE_PUSH, CLOUD_SAVE_PULL, CLOUD_SAVE_ASK };
int cloud_save_decide(NSString *local, bool empty, NSString *synced, NSArray<NSString *> *lineage,
                      NSArray<NSDictionary *> *remotes, NSArray<NSDictionary *> **heads);
NSString *cloud_save_archive(NSString *directory, NSString *output, uint64_t *bytes, double *newest);
bool cloud_save_extract(NSString *archive, NSString *directory, NSString *hash);
#endif
void cloud_save_wait(void);    // Call before the game mounts its save; returns once the startup sync is settled.
void cloud_save_flush(void);   // Publishes a pending save now (quit, background).
