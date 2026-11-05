// Cheat names for the Mac menu and the iOS settings sheet (from nxnative's front_mac.m, MIT, THIRD_PARTY_NOTICES.md).
#pragma once
#import <Foundation/Foundation.h>
#include "cheats.h"

// Cheat files come from many sites: UTF-8 (a name cut mid-character at the engine's length limit loses its last bytes),
// else GB18030 (Chinese sites), Shift JIS or Windows-1252. Never nil.
static inline NSString *cheat_text(const char *s) {
    if (!s) return @"";
    size_t n = strlen(s);
    for (size_t cut = 0; cut <= 3 && cut <= n; cut++) {
        NSString *u = [[NSString alloc] initWithBytes:s length:n - cut encoding:NSUTF8StringEncoding];
        if (u) return u;
    }
    NSStringEncoding gb = CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000);
    return [[NSString alloc] initWithBytes:s length:n encoding:gb] ?: [[NSString alloc] initWithBytes:s length:n encoding:NSShiftJISStringEncoding]
        ?: [[NSString alloc] initWithBytes:s length:n encoding:NSWindowsCP1252StringEncoding] ?: @"";
}
// Entry i has a row of its own: not the off half of an on / off pair (its on half is the switch) nor a section marker.
static inline BOOL cheat_has_row(int i) {
    return !(dm_cheat_flags_at(i) & (DM_CHEAT_PAIR_OFF | DM_CHEAT_SECTION_START | DM_CHEAT_SECTION_END));
}
// The row's name: the on half of a pair loses its " - on"; a master is always on; the engine's reason why it cannot run follows.
static inline NSString *cheat_row_title(int i) {
    NSString *name = cheat_text(dm_cheat_name_at(i));
    if (dm_cheat_flags_at(i) & DM_CHEAT_PAIR_ON) {
        static NSRegularExpression *on;
        if (!on) on = [NSRegularExpression regularExpressionWithPattern:@"(\\s*[-:_]\\s*|\\s+|\\s*[(\\[]\\s*)on\\s*[)\\]]?\\s*$"
                                                                options:NSRegularExpressionCaseInsensitive error:nil];
        NSString *base = [on stringByReplacingMatchesInString:name options:0 range:NSMakeRange(0, name.length) withTemplate:@""];
        if (base.length) name = base;
    }
    if (dm_cheat_kind_at(i) == 1) name = [name stringByAppendingString:@" (always on)"];
    if (dm_cheat_flags_at(i) & DM_CHEAT_ONCE) name = [name stringByAppendingString:@" (apply once)"];
    return [name stringByAppendingString:cheat_text(dm_cheat_why_at(i))];
}
// The game's line: "1.4.3 (build 277178B7DBA1B6D4)".
static inline NSString *cheat_game_title(void) {
    const char *version = dm_cheats_version();
    return *version ? [NSString stringWithFormat:@"%s (build %s)", version, dm_cheats_build()] : [NSString stringWithFormat:@"build %s", dm_cheats_build()];
}
