#import <GameController/GameController.h>
#include "touch_controls.h"
#include "dm_input.h"
#include "input.h"
#include <math.h>

static NSString *const opacity_key = @"ZeldaTouchOpacity", *const size_key = @"ZeldaTouchSize",
    *const look_key = @"ZeldaTouchLook", *const invert_key = @"ZeldaTouchInvertY", *const xbox_key = @"ZeldaTouchXboxFace",
    *const hold_key = @"ZeldaTouchLookHold";

static float bounded(float value, float low, float high, float fallback) {
    return isfinite(value) && value >= low && value <= high ? value : fallback;
}
ZeldaTouchPreferences zelda_touch_preferences(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults registerDefaults:@{opacity_key: @.5, size_key: @1, look_key: @1, invert_key: @NO, xbox_key: @NO, hold_key: @YES}];
    return (ZeldaTouchPreferences){bounded([defaults floatForKey:opacity_key], .15f, 1, .5f),
        bounded([defaults floatForKey:size_key], .75f, 1.35f, 1), bounded([defaults floatForKey:look_key], .3f, 3, 1),
        [defaults boolForKey:invert_key], [defaults boolForKey:hold_key], [defaults boolForKey:xbox_key]};
}
void zelda_touch_store(ZeldaTouchPreferences preferences) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setFloat:preferences.opacity forKey:opacity_key]; [defaults setFloat:preferences.size forKey:size_key];
    [defaults setFloat:preferences.look forKey:look_key]; [defaults setBool:preferences.invert_y forKey:invert_key];
    [defaults setBool:preferences.xbox_face forKey:xbox_key]; [defaults setBool:preferences.look_hold forKey:hold_key];
}

// One drawn key. The overlay does its own hit testing, so several fingers can hold and slide between keys at once.
@interface ZeldaTouchKey : UIView
@property (nonatomic) uint64_t bit;   // 0 for the settings key
@property (nonatomic) BOOL face, round, pressed;
@end
@implementation ZeldaTouchKey {
    UILabel *label;
    UIImageView *symbol;
}
- (instancetype)initWithTitle:(NSString *)title bit:(uint64_t)bit {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    _bit = bit; _round = YES; self.userInteractionEnabled = NO;
    self.layer.borderWidth = 1.5; self.layer.borderColor = [UIColor colorWithWhite:1 alpha:.85].CGColor;
    if (bit) {
        label = [UILabel new]; label.text = title; label.textColor = UIColor.whiteColor;
        label.textAlignment = NSTextAlignmentCenter; label.adjustsFontSizeToFitWidth = YES; [self addSubview:label];
    } else {
        symbol = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:title]];
        symbol.tintColor = UIColor.whiteColor; symbol.contentMode = UIViewContentModeScaleAspectFit; [self addSubview:symbol];
    }
    self.pressed = NO;
    return self;
}
- (void)setPressed:(BOOL)pressed {
    _pressed = pressed;
    self.backgroundColor = pressed ? [UIColor colorWithWhite:1 alpha:.5] : [UIColor colorWithWhite:0 alpha:.35];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat side = self.bounds.size.width;
    self.layer.cornerRadius = self.round ? side / 2 : side * .22;
    label.frame = CGRectInset(self.bounds, side * .12, 0);
    label.font = [UIFont systemFontOfSize:side * .4 weight:UIFontWeightBold];
    symbol.frame = CGRectInset(self.bounds, side * .24, side * .24);
}
@end

typedef enum { TRACK_KEY, TRACK_DPAD, TRACK_MOVE, TRACK_LOOK } ZeldaTrackRole;
@interface ZeldaTouchTrack : NSObject
@property (nonatomic) ZeldaTrackRole role;
@property (nonatomic, weak) ZeldaTouchKey *key;
@property (nonatomic) CGPoint origin, last;
@end
@implementation ZeldaTouchTrack
@end

@implementation ZeldaTouchControls {
    void (^menu)(void);
    ZeldaTouchPreferences preferences;
    ZeldaTouchKey *face[4], *left[4], *right[4], *menu_key;   // face: A, B, X, Y; sides: top to bottom
    NSArray<ZeldaTouchKey *> *keys, *arms;   // arms: the D-pad's up, down, left, right
    CGPoint dpad_center, stick_home;
    CGFloat dpad_arm, stick_radius, look_dead, look_reach;
    CGFloat move_reach;
    UIView *stick_base, *stick_knob;
    NSMapTable<UITouch *, ZeldaTouchTrack *> *tracks;
    CADisplayLink *link;
    CGPoint look_delta, look_velocity, look;
    BOOL controller;
}

- (instancetype)initWithMenu:(void (^)(void))handler {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    menu = handler; self.multipleTouchEnabled = YES; self.hidden = YES;
    tracks = [NSMapTable strongToStrongObjectsMapTable];
    NSMutableArray *all = [NSMutableArray array];
    ZeldaTouchKey *(^key)(NSString *, uint64_t) = ^(NSString *title, uint64_t bit) {
        ZeldaTouchKey *made = [[ZeldaTouchKey alloc] initWithTitle:title bit:bit];
        [self addSubview:made]; [all addObject:made]; return made;
    };
    NSString *letters[] = {@"A", @"B", @"X", @"Y"};
    for (int i = 0; i < 4; i++) { face[i] = key(letters[i], DM_BTN_A << i); face[i].face = YES; }
    NSString *left_titles[] = {@"−", @"ZL", @"L", @"L3"}, *right_titles[] = {@"+", @"ZR", @"R", @"R3"};
    const uint64_t left_bits[] = {DM_BTN_MINUS, DM_BTN_ZL, DM_BTN_L, DM_BTN_LS}, right_bits[] = {DM_BTN_PLUS, DM_BTN_ZR, DM_BTN_R, DM_BTN_RS};
    for (int i = 0; i < 4; i++) { left[i] = key(left_titles[i], left_bits[i]); right[i] = key(right_titles[i], right_bits[i]); }
    menu_key = key(@"gearshape.fill", 0);
    keys = all;
    NSMutableArray *pad = [NSMutableArray array];
    const uint64_t directions[] = {DM_BTN_UP, DM_BTN_DOWN, DM_BTN_LEFT, DM_BTN_RIGHT};
    NSString *glyphs[] = {@"▲", @"▼", @"◀", @"▶"};
    for (int i = 0; i < 4; i++) {
        ZeldaTouchKey *arm = [[ZeldaTouchKey alloc] initWithTitle:glyphs[i] bit:directions[i]];
        arm.round = NO; [self addSubview:arm]; [pad addObject:arm];
    }
    arms = pad;
    stick_base = [UIView new]; stick_knob = [UIView new];
    for (UIView *view in @[stick_base, stick_knob]) {
        view.userInteractionEnabled = NO; view.layer.borderWidth = 1.5;
        view.layer.borderColor = [UIColor colorWithWhite:1 alpha:.85].CGColor; [self addSubview:view];
    }
    stick_base.backgroundColor = [UIColor colorWithWhite:0 alpha:.25];
    stick_knob.backgroundColor = [UIColor colorWithWhite:1 alpha:.35];
    link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    link.preferredFrameRateRange = CAFrameRateRangeMake(60, 60, 60); link.paused = YES;
    [link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    __weak ZeldaTouchControls *weak = self;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[GCControllerDidConnectNotification, GCControllerDidDisconnectNotification])
        [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(NSNotification *note) { (void)note; [weak controllersChanged]; }];
    [self reloadPreferences]; [self controllersChanged];
    return self;
}

- (void)reloadPreferences {
    preferences = zelda_touch_preferences();
    for (ZeldaTouchKey *key in [keys arrayByAddingObjectsFromArray:arms]) key.alpha = preferences.opacity;
    stick_base.alpha = stick_knob.alpha = preferences.opacity;
    [self setNeedsLayout];
}
- (void)setPlaying:(BOOL)playing {
    _playing = playing; self.hidden = !playing; link.paused = !playing;
    if (!playing) [self releaseAll];
}
- (void)controllersChanged {
    BOOL connected = NO;
    for (GCController *found in GCController.controllers) if (found.extendedGamepad) connected = YES;
    if (connected == controller) return;
    controller = connected;
    for (UIView *view in [keys arrayByAddingObjectsFromArray:arms]) view.hidden = connected && view != menu_key;
    stick_base.hidden = stick_knob.hidden = connected;
    [self releaseAll];
}
- (void)releaseAll {
    [tracks removeAllObjects]; look_delta = look_velocity = look = CGPointZero; [self publish];
}

static void place(UIView *view, CGFloat x, CGFloat y, CGFloat side) {
    view.bounds = CGRectMake(0, 0, side, side); view.center = CGPointMake(x, y);
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize size = self.bounds.size;
    UIEdgeInsets safe = self.safeAreaInsets;
    CGFloat s = preferences.size, W = size.width, H = size.height;
    CGFloat bar = (W - MIN(W, H * 16 / 9)) / 2;
    BOOL bars = bar >= 44;
    CGFloat column = bars ? bar / 2 : MAX(safe.left, 12) + 30 * s, side = bars ? MIN(52 * s, bar - 6) : 48 * s;
    CGFloat edge = bars ? bar : column + side / 2 + 8;   // inner edge of the side columns
    // Two keys above and two below the middle on each side, which keeps them off the Dynamic Island or notch.
    const CGFloat rows[] = {.105, .26, .74, .895}, scale[] = {.8, 1, 1, .8};
    for (int i = 0; i < 4; i++) {
        place(left[i], column, H * rows[i], side * scale[i]); place(right[i], W - column, H * rows[i], side * scale[i]);
    }
    // The settings key takes the middle of the side away from the cutout (the top of the device).
    BOOL cutout_left = self.window.windowScene.interfaceOrientation == UIInterfaceOrientationLandscapeRight;
    place(menu_key, cutout_left ? W - column : column, H / 2, side * .8);

    CGFloat button = 56 * s, gap = button * 1.05, bottom = H - MAX(safe.bottom, 8);
    CGPoint centre = CGPointMake(W - edge - gap - button / 2 - 12, bottom - gap - button / 2 - 8);
    // Top, right, bottom, left of the diamond: X A B Y as on a Switch, or Y B A X in Xbox positions.
    const int order[2][4] = {{2, 0, 1, 3}, {3, 1, 0, 2}};
    const CGPoint offsets[] = {{0, -gap}, {gap, 0}, {0, gap}, {-gap, 0}};
    for (int i = 0; i < 4; i++)
        place(face[order[preferences.xbox_face][i]], centre.x + offsets[i].x, centre.y + offsets[i].y, button);

    dpad_arm = 42 * s;
    dpad_center = CGPointMake(edge + dpad_arm * 1.5 + 16, H * .38);
    const CGPoint arm_offsets[] = {{0, -1}, {0, 1}, {-1, 0}, {1, 0}};
    for (int i = 0; i < 4; i++)
        place(arms[i], dpad_center.x + arm_offsets[i].x * dpad_arm, dpad_center.y + arm_offsets[i].y * dpad_arm, dpad_arm * .95);

    // The movement stick starts anywhere within `move_reach` of its resting place and its centre stays in that circle.
    stick_radius = 56 * s; move_reach = stick_radius * 2;
    stick_home = CGPointMake(edge + stick_radius + 28, bottom - stick_radius - 16);
    look_dead = 36 * s; look_reach = 110 * s;
    place(stick_base, stick_home.x, stick_home.y, stick_radius * 2);
    place(stick_knob, stick_home.x, stick_home.y, stick_radius * .9);
    stick_base.layer.cornerRadius = stick_radius; stick_knob.layer.cornerRadius = stick_radius * .45;
    [self publish];
}

- (ZeldaTouchKey *)keyAt:(CGPoint)point faceOnly:(BOOL)face_only {
    ZeldaTouchKey *best = nil; CGFloat nearest = INFINITY;
    for (ZeldaTouchKey *key in keys) {
        if (key.hidden || (face_only && !key.face)) continue;
        CGFloat distance = hypot(point.x - key.center.x, point.y - key.center.y);
        if (distance <= key.bounds.size.width / 2 + 8 && distance < nearest) { best = key; nearest = distance; }
    }
    return best;
}
- (uint64_t)dpadBits:(CGPoint)point {
    CGFloat x = point.x - dpad_center.x, y = point.y - dpad_center.y, dead = dpad_arm * .45;
    return (x < -dead ? DM_BTN_LEFT : 0) | (x > dead ? DM_BTN_RIGHT : 0) | (y < -dead ? DM_BTN_UP : 0) | (y > dead ? DM_BTN_DOWN : 0);
}
- (CGPoint)stickCentre:(CGPoint)point {
    CGFloat x = point.x - stick_home.x, y = point.y - stick_home.y, distance = hypot(x, y);
    if (distance <= move_reach) return point;
    return CGPointMake(stick_home.x + x * move_reach / distance, stick_home.y + y * move_reach / distance);
}
// Past `reach` the anchor is dragged along, so turning back slows the camera at once instead of after unwinding.
static CGPoint follow(CGPoint origin, CGPoint point, CGFloat reach) {
    CGFloat x = point.x - origin.x, y = point.y - origin.y, distance = hypot(x, y);
    if (distance <= reach) return origin;
    CGFloat pull = (distance - reach) / distance;
    return CGPointMake(origin.x + x * pull, origin.y + y * pull);
}
- (ZeldaTouchTrack *)trackWithRole:(ZeldaTrackRole)role {
    for (ZeldaTouchTrack *track in tracks.objectEnumerator) if (track.role == role) return track;
    return nil;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    for (UITouch *touch in touches) {
        CGPoint point = [touch locationInView:self];
        ZeldaTouchTrack *track = [ZeldaTouchTrack new]; track.origin = track.last = point;
        ZeldaTouchKey *key = [self keyAt:point faceOnly:NO];
        CGFloat reach = dpad_arm * 1.5 + 6;
        if (key) { track.role = TRACK_KEY; track.key = key; }
        else if (controller) continue;
        else if (fabs(point.x - dpad_center.x) <= reach && fabs(point.y - dpad_center.y) <= reach) track.role = TRACK_DPAD;
        else if (point.x < self.bounds.size.width / 2) {
            if (hypot(point.x - stick_home.x, point.y - stick_home.y) > move_reach || [self trackWithRole:TRACK_MOVE]) continue;
            track.role = TRACK_MOVE;
        } else {
            if ([self trackWithRole:TRACK_LOOK]) continue;
            track.role = TRACK_LOOK;
        }
        [tracks setObject:track forKey:touch];
    }
    [self publish];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    (void)event;
    for (UITouch *touch in touches) {
        ZeldaTouchTrack *track = [tracks objectForKey:touch];
        CGPoint point = [touch locationInView:self];
        if (!track) continue;
        if (track.role == TRACK_KEY && track.key.face) {   // a thumb can roll from one face button to the next
            ZeldaTouchKey *key = [self keyAt:point faceOnly:YES];
            if (key) track.key = key;
        } else if (track.role == TRACK_MOVE) {   // past the rim the stick follows the thumb, within its circle
            track.origin = [self stickCentre:follow(track.origin, point, stick_radius)];
        } else if (track.role == TRACK_LOOK) {
            look_delta.x += point.x - track.last.x; look_delta.y += point.y - track.last.y;
            track.origin = follow(track.origin, point, look_reach);
        }
        track.last = point;
    }
    [self publish];
}
- (void)finish:(NSSet<UITouch *> *)touches cancelled:(BOOL)cancelled {
    BOOL open = NO;
    for (UITouch *touch in touches) {
        ZeldaTouchTrack *track = [tracks objectForKey:touch];
        if (!cancelled && track.role == TRACK_KEY && track.key == menu_key && [self keyAt:[touch locationInView:self] faceOnly:NO] == menu_key)
            open = YES;
        [tracks removeObjectForKey:touch];
    }
    [self publish];
    if (open) menu();
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { (void)event; [self finish:touches cancelled:NO]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { (void)event; [self finish:touches cancelled:YES]; }

// The camera stick follows the drag speed, smoothed over two frames; the square root lifts slow drags past the game's
// own stick dead zone so small corrections still turn the camera. A thumb held away from where the drag began adds a
// steady turn that grows with the distance, so a long turn needs no repeated swipes.
- (void)tick:(CADisplayLink *)sender {
    (void)sender;
    ZeldaTouchTrack *looking = [self trackWithRole:TRACK_LOOK];
    look_velocity = looking ? CGPointMake((look_velocity.x + look_delta.x) / 2, (look_velocity.y + look_delta.y) / 2) : CGPointZero;
    look_delta = CGPointZero;
    CGFloat flip = preferences.invert_y ? -1 : 1;
    CGFloat gain = preferences.look / 10, x = look_velocity.x * gain, y = -look_velocity.y * gain * flip;
    CGFloat magnitude = hypot(x, y);
    if (magnitude > 0) { CGFloat lift = MIN(1, sqrt(magnitude)) / magnitude; x *= lift; y *= lift; }
    if (looking && preferences.look_hold) {
        CGFloat hx = looking.last.x - looking.origin.x, hy = looking.last.y - looking.origin.y, distance = hypot(hx, hy);
        if (distance > look_dead) {
            CGFloat hold = MIN(1, .2 + .8 * (distance - look_dead) / (look_reach - look_dead)) * MIN(1, preferences.look) / distance;
            x += hx * hold; y -= hy * hold * flip;
            magnitude = hypot(x, y);
            if (magnitude > 1) { x /= magnitude; y /= magnitude; }
        }
    }
    if (x == look.x && y == look.y) return;
    look = CGPointMake(x, y); [self publish];
}

- (void)publish {
    uint64_t buttons = 0;
    float lx = 0, ly = 0;
    CGPoint stick = stick_home, knob = stick_home;
    for (ZeldaTouchKey *key in [keys arrayByAddingObjectsFromArray:arms]) key.pressed = NO;
    for (ZeldaTouchTrack *track in tracks.objectEnumerator) switch (track.role) {
    case TRACK_KEY: buttons |= track.key.bit; track.key.pressed = YES; break;
    case TRACK_DPAD: {
        uint64_t bits = [self dpadBits:track.last];
        buttons |= bits;
        for (ZeldaTouchKey *arm in arms) if (bits & arm.bit) arm.pressed = YES;
        break;
    }
    case TRACK_MOVE: {
        CGFloat x = (track.last.x - track.origin.x) / stick_radius, y = (track.last.y - track.origin.y) / stick_radius;
        CGFloat length = hypot(x, y);
        if (length > 1) { x /= length; y /= length; }
        if (length >= .1) { lx = x; ly = -y; }
        stick = track.origin; knob = CGPointMake(track.origin.x + x * stick_radius, track.origin.y + y * stick_radius);
        break;
    }
    case TRACK_LOOK: break;
    }
    stick_base.center = stick; stick_knob.center = knob;
    input_touch(buttons, lx, ly, look.x, look.y);
}
@end
