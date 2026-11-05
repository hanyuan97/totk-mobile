#include "settings_sheet.h"
#include "settings.h"
#include "game_timing.h"
#include "audio.h"
#include "shader_async.h"
#include "gamepad.h"
#include "cheats_names.h"

static void store_settings(void (^change)(zelda_settings_t *settings)) {
    zelda_settings_t settings = zelda_settings();
    change(&settings);
    if (!zelda_settings_store(settings)) fprintf(stderr, "SETTINGS could not be saved from the iOS menu\n");
}

@interface ZeldaSettingsSheet : UIViewController
@property (nonatomic, copy) void (^changed)(void);
@end
@implementation ZeldaSettingsSheet {
    UIStackView *rows;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Settings";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    __weak ZeldaSettingsSheet *weak = self;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
        primaryAction:[UIAction actionWithHandler:^(UIAction *action) { (void)action; [weak dismissViewControllerAnimated:YES completion:nil]; }]];
    UIScrollView *scroll = [UIScrollView new]; scroll.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:scroll];
    rows = [UIStackView new]; rows.axis = UILayoutConstraintAxisVertical; rows.spacing = 14;
    rows.translatesAutoresizingMaskIntoConstraints = NO; [scroll addSubview:rows];
    UILayoutGuide *readable = self.view.readableContentGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [rows.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:16],
        [rows.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [rows.leadingAnchor constraintEqualToAnchor:readable.leadingAnchor],
        [rows.trailingAnchor constraintEqualToAnchor:readable.trailingAnchor]]];
    [self addRows];
}
- (void)addRows {
    zelda_settings_t settings = zelda_settings();
    [self heading:@"Game"];
    [self choice:@"Frame rate" items:@[@"30", @"60"] selected:settings.target_fps == 30 ? 0 : settings.target_fps == 60 ? 1 : -1
        change:^(NSInteger index) {
            unsigned fps = index ? 60 : 30;
            if (zelda_set_target_fps(fps)) store_settings(^(zelda_settings_t *s) { s->target_fps = fps; });
        }];
    [self choice:@"Render resolution" items:@[@"Original", @"1080p", @"720p", @"640p"] selected:settings.render
        change:^(NSInteger index) {
            if (zelda_set_render_scale(zelda_render_scale_factor((int)index))) store_settings(^(zelda_settings_t *s) { s->render = (int)index; });
        }];
    [self toggle:@"Compile new shaders in background" on:!settings.shader_wait change:^(BOOL on) {
        zelda_set_shader_wait(!on); store_settings(^(zelda_settings_t *s) { s->shader_wait = !on; });
    }];
    [self toggle:@"Sound" on:!settings.muted change:^(BOOL on) {
        audio_mute(!on); store_settings(^(zelda_settings_t *s) { s->muted = !on; });
    }];
    // The volume follows the drag; the settings file is written once the finger lifts.
    [self slider:@"Volume" value:settings.volume low:0 high:100
        change:^(float value) { audio_output_volume((unsigned)lroundf(value)); }
        done:^(float value) { unsigned percent = (unsigned)lroundf(value); store_settings(^(zelda_settings_t *s) { s->volume = percent; }); }];
    // The phone's gyro, or a connected controller's; the game's own Motion Controls option still applies.
    [self toggle:@"Gyro aiming" on:!settings.motion_off change:^(BOOL on) {
        gamepad_motion(on); store_settings(^(zelda_settings_t *s) { s->motion_off = !on; });
    }];
    [self toggle:@"Performance panel" on:!settings.hide_performance change:^(BOOL on) {
        store_settings(^(zelda_settings_t *s) { s->hide_performance = !on; });
    }];
    [self cheats];
}

// Atmosphère-format cheats (host/cheats.c): the file named after the build ID in Documents/work/cheats, which the Files app
// shows under this app. The iPhone's code pages are signed, so cheats that patch code stay off with their reason.
- (void)cheats {
    [self heading:@"Cheats"];
    if (!dm_cheats_found()) {
        [self note:[NSString stringWithFormat:@"No cheats for %@. Put %s.txt in Files › On My iPhone › %@ › work › cheats, then tap Reload.",
            cheat_game_title(), dm_cheats_build(), NSBundle.mainBundle.infoDictionary[@"CFBundleDisplayName"] ?: @"ZeldaMobile"]];
    } else {
        [self toggle:@"Cheats on" on:dm_cheats_master() change:^(BOOL on) { dm_cheats_master_set(on); }];
        if (dm_cheats_safe()) [self button:@"Restore saved cheats" action:^{ dm_cheats_safe_restore(); }];
        const char *section = "";
        for (int i = 0, n = dm_cheats_ncheats(); i < n; i++) {
            if (!cheat_has_row(i)) continue;
            const char *s = dm_cheat_section_at(i);
            if (strcmp(s, section)) { section = s; if (*s) [self note:cheat_text(s)]; }
            if (dm_cheat_kind_at(i) == 0) [self toggle:cheat_row_title(i) on:dm_cheat_on_at(i) change:^(BOOL on) { if (on != dm_cheat_on_at(i)) dm_cheat_toggle(i); }];
            else [self note:cheat_row_title(i)];
        }
    }
    __weak ZeldaSettingsSheet *weak = self;
    [self button:@"Reload cheats" action:^{ dm_cheats_reload(); [weak rebuild]; }];
}
- (void)rebuild {
    for (UIView *view in rows.arrangedSubviews) [view removeFromSuperview];
    [self addRows];
}
- (void)note:(NSString *)text {
    UILabel *label = [UILabel new]; label.text = text; label.numberOfLines = 0;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]; label.textColor = UIColor.secondaryLabelColor;
    [rows addArrangedSubview:label];
}
- (void)button:(NSString *)title action:(void (^)(void))action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
    [button addAction:[UIAction actionWithHandler:^(UIAction *a) { (void)a; action(); }] forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [rows addArrangedSubview:button];
}

- (void)heading:(NSString *)title {
    UILabel *label = [UILabel new]; label.text = title.uppercaseString;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]; label.textColor = UIColor.secondaryLabelColor;
    [rows addArrangedSubview:label];
}
- (void)row:(NSString *)title control:(UIView *)control {
    UILabel *label = [UILabel new]; label.text = title; label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    [label setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[label, control]];
    row.spacing = 16; row.alignment = UIStackViewAlignmentCenter;
    [row.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [rows addArrangedSubview:row];
}
- (void)slider:(NSString *)title value:(float)value low:(float)low high:(float)high change:(void (^)(float))change done:(void (^)(float))done {
    UISlider *slider = [UISlider new]; slider.minimumValue = low; slider.maximumValue = high; slider.value = value;
    __weak UISlider *weak_slider = slider;
    void (^changed)(void) = self.changed;
    [slider addAction:[UIAction actionWithHandler:^(UIAction *action) {
        (void)action; change(weak_slider.value); changed();
    }] forControlEvents:UIControlEventValueChanged];
    [slider addAction:[UIAction actionWithHandler:^(UIAction *action) { (void)action; done(weak_slider.value); }]
     forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [self row:title control:slider];
}
- (void)toggle:(NSString *)title on:(BOOL)on change:(void (^)(BOOL))change {
    UISwitch *control = [UISwitch new]; control.on = on;
    UIView *spacer = [UIView new];
    __weak UISwitch *weak_control = control;
    void (^changed)(void) = self.changed;
    [control addAction:[UIAction actionWithHandler:^(UIAction *action) {
        (void)action; change(weak_control.on); changed();
    }] forControlEvents:UIControlEventValueChanged];
    UIStackView *trailing = [[UIStackView alloc] initWithArrangedSubviews:@[spacer, control]];
    [self row:title control:trailing];
}
- (void)choice:(NSString *)title items:(NSArray<NSString *> *)items selected:(NSInteger)selected change:(void (^)(NSInteger))change {
    UISegmentedControl *control = [[UISegmentedControl alloc] initWithItems:items];
    control.selectedSegmentIndex = selected >= 0 && selected < (NSInteger)items.count ? selected : UISegmentedControlNoSegment;
    __weak UISegmentedControl *weak_control = control;
    void (^changed)(void) = self.changed;
    [control addAction:[UIAction actionWithHandler:^(UIAction *action) {
        (void)action; change(weak_control.selectedSegmentIndex); changed();
    }] forControlEvents:UIControlEventValueChanged];
    [self row:title control:control];
}
@end

UIViewController *zelda_settings_sheet(void (^changed)(void)) {
    ZeldaSettingsSheet *sheet = [ZeldaSettingsSheet new];
    sheet.changed = changed;
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:sheet];
    navigation.modalPresentationStyle = UIModalPresentationFormSheet;
    return navigation;
}
