// The Mac's Cheats menu over host/cheats.c (Atmosphère-format cheat files in work/cheats, named after the build ID): the master
// switch, one checkmark row per cheat (an on / off pair is one row), the reason a cheat cannot run, and the folder actions. The
// rows are rebuilt each time the menu opens, so a cheat that turned itself off or a reloaded file shows at once. Clicking a menu
// item never takes keyboard focus from the game window. nxnative's full panel (values, dry runs, search) is not taken.
#include "cheats_names.h"

@interface ZeldaCheatsMenu : NSObject <NSMenuDelegate>
@end
@implementation ZeldaCheatsMenu
- (void)toggle:(NSMenuItem *)item { dm_cheat_toggle((int)item.tag); }
- (void)master:(NSMenuItem *)item { (void)item; dm_cheats_master_set(!dm_cheats_master()); }
- (void)restore:(NSMenuItem *)item { (void)item; dm_cheats_safe_restore(); }
- (void)reload:(NSMenuItem *)item { (void)item; dm_cheats_reload(); }
- (void)openFolder:(NSMenuItem *)item {
    (void)item;
    NSString *folder = @(dm_cheats_dir_path());
    if (!folder.length) return;
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:folder isDirectory:YES]];
}
static NSMenuItem *cheats_note(NSString *title) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    item.enabled = NO;
    return item;
}
- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    int count = dm_cheats_ncheats(), on = 0, rows = 0;
    for (int i = 0; i < count; i++) if (cheat_has_row(i) && dm_cheat_kind_at(i) == 0) { rows++; on += dm_cheat_on_at(i); }
    NSMenuItem *master = [[NSMenuItem alloc] initWithTitle:@"Cheats On" action:@selector(master:) keyEquivalent:@""];
    master.target = self; master.state = dm_cheats_master() ? NSControlStateValueOn : NSControlStateValueOff;
    master.enabled = dm_cheats_found();
    [menu addItem:master];
    if (dm_cheats_safe()) {
        NSMenuItem *restore = [[NSMenuItem alloc] initWithTitle:@"Restore Saved Cheats (the last run ended with cheats on)" action:@selector(restore:) keyEquivalent:@""];
        restore.target = self; [menu addItem:restore];
    }
    [menu addItem:[NSMenuItem separatorItem]];
    if (!dm_cheats_found()) {
        [menu addItem:cheats_note([NSString stringWithFormat:@"No cheats for %@", cheat_game_title()])];
        [menu addItem:cheats_note([NSString stringWithFormat:@"Put %s.txt in the cheats folder", dm_cheats_build()])];
        for (int i = 0; i < dm_cheats_nothers(); i++)
            [menu addItem:cheats_note([NSString stringWithFormat:@"%s.txt: another version of the game", dm_cheats_other(i)])];
    } else {
        [menu addItem:cheats_note([NSString stringWithFormat:@"%@: %d cheats, %d on", cheat_game_title(), rows, on])];
        const char *section = "";
        for (int i = 0; i < count; i++) {
            if (!cheat_has_row(i)) continue;
            const char *s = dm_cheat_section_at(i);
            if (strcmp(s, section)) { section = s; if (*s) [menu addItem:cheats_note([NSString stringWithFormat:@"— %@ —", cheat_text(s)])]; }
            int kind = dm_cheat_kind_at(i);
            NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:cheat_row_title(i) action:kind == 0 ? @selector(toggle:) : nil keyEquivalent:@""];
            item.target = self; item.tag = i; item.enabled = kind == 0;
            item.state = dm_cheat_on_at(i) || kind == 1 ? NSControlStateValueOn : NSControlStateValueOff;
            [menu addItem:item];
        }
    }
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *reload = [[NSMenuItem alloc] initWithTitle:@"Reload Cheats" action:@selector(reload:) keyEquivalent:@""];
    reload.target = self; [menu addItem:reload];
    NSMenuItem *folder = [[NSMenuItem alloc] initWithTitle:@"Open Cheats Folder" action:@selector(openFolder:) keyEquivalent:@""];
    folder.target = self; [menu addItem:folder];
}
@end

static ZeldaCheatsMenu *cheats_menu_target;
static NSMenuItem *cheats_menu_install(void) {
    cheats_menu_target = [ZeldaCheatsMenu new];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Cheats"];
    menu.delegate = cheats_menu_target; menu.autoenablesItems = NO;
    NSMenuItem *holder = [[NSMenuItem alloc] initWithTitle:@"Cheats" action:nil keyEquivalent:@""];
    holder.submenu = menu;
    return holder;
}
