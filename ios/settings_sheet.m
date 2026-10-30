#include "settings_sheet.h"
#include "touch_controls.h"
#include "settings.h"
#include "game_timing.h"
#include "audio.h"

static void store_settings(void (^change)(zelda_settings_t *settings)) {
    zelda_settings_t settings = zelda_settings();
    change(&settings);
    if (!zelda_settings_store(settings)) fprintf(stderr, "SETTINGS could not be saved from the iOS menu\n");
}
static void store_touch(void (^change)(ZeldaTouchPreferences *preferences)) {
    ZeldaTouchPreferences preferences = zelda_touch_preferences();
    change(&preferences);
    zelda_touch_store(preferences);
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

    ZeldaTouchPreferences touch = zelda_touch_preferences();
    zelda_settings_t settings = zelda_settings();
    [self heading:@"Touch controls"];
    [self slider:@"Opacity" value:touch.opacity low:.15 high:1 change:^(float value) { store_touch(^(ZeldaTouchPreferences *p) { p->opacity = value; }); }];
    [self slider:@"Size" value:touch.size low:.75 high:1.35 change:^(float value) { store_touch(^(ZeldaTouchPreferences *p) { p->size = value; }); }];
    [self slider:@"Camera speed" value:touch.look low:.3 high:3 change:^(float value) { store_touch(^(ZeldaTouchPreferences *p) { p->look = value; }); }];
    [self toggle:@"Invert camera up/down" on:touch.invert_y change:^(BOOL on) { store_touch(^(ZeldaTouchPreferences *p) { p->invert_y = on; }); }];
    [self choice:@"Face buttons" items:@[@"Switch", @"Xbox"] selected:touch.xbox_face change:^(NSInteger index) {
        store_touch(^(ZeldaTouchPreferences *p) { p->xbox_face = index == 1; });
    }];
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
    [self toggle:@"Sound" on:!settings.muted change:^(BOOL on) {
        audio_mute(!on); store_settings(^(zelda_settings_t *s) { s->muted = !on; });
    }];
    [self toggle:@"Performance panel" on:!settings.hide_performance change:^(BOOL on) {
        store_settings(^(zelda_settings_t *s) { s->hide_performance = !on; });
    }];
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
- (void)slider:(NSString *)title value:(float)value low:(float)low high:(float)high change:(void (^)(float))change {
    UISlider *slider = [UISlider new]; slider.minimumValue = low; slider.maximumValue = high; slider.value = value;
    __weak UISlider *weak_slider = slider;
    void (^changed)(void) = self.changed;
    [slider addAction:[UIAction actionWithHandler:^(UIAction *action) {
        (void)action; change(weak_slider.value); changed();
    }] forControlEvents:UIControlEventValueChanged];
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
