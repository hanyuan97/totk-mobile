#import <Foundation/Foundation.h>
#include "cloud_save.h"
#include "filesystem.h"
#include <assert.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;
static NSString *const H1 = @"1111111111111111111111111111111111111111111111111111111111111111",
                *const H2 = @"2222222222222222222222222222222222222222222222222222222222222222",
                *const H3 = @"3333333333333333333333333333333333333333333333333333333333333333",
                *const H4 = @"4444444444444444444444444444444444444444444444444444444444444444";

static NSDictionary *remote(NSString *hash, NSArray *history, double time) {
    return @{@"id": NSUUID.UUID.UUIDString, @"hash": hash, @"history": history, @"device": @"Other", @"time": @(time)};
}

static void write_text(NSString *path, NSString *text) {
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    assert([text writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil]);
}
static NSString *read_text(NSString *path) { return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil]; }

static void check_decisions(void) {
    NSArray *heads = nil;
    assert(cloud_save_decide(H1, true, @"", @[], @[], &heads) == CLOUD_SAVE_KEEP && !heads.count);
    assert(cloud_save_decide(H1, false, @"", @[], @[], NULL) == CLOUD_SAVE_PUSH);
    assert(cloud_save_decide(H1, false, H1, @[H1], @[], NULL) == CLOUD_SAVE_KEEP);
    assert(cloud_save_decide(H2, false, H1, @[H1], @[remote(H1, @[H1], 1)], NULL) == CLOUD_SAVE_PUSH);   // Stale remote.
    assert(cloud_save_decide(H1, false, H1, @[H1], @[remote(H2, @[H1, H2], 1)], &heads) == CLOUD_SAVE_PULL);
    assert([heads[0][@"hash"] isEqual:H2]);
    assert(cloud_save_decide(H3, false, H1, @[H1, H3], @[remote(H2, @[H1, H2], 1)], NULL) == CLOUD_SAVE_ASK);
    assert(cloud_save_decide(H1, false, H1, @[H1], @[remote(H2, @[H2], 1)], NULL) == CLOUD_SAVE_ASK);   // Unrelated fork.
    assert(cloud_save_decide(H4, true, @"", @[], @[remote(H2, @[H2], 1)], NULL) == CLOUD_SAVE_PULL);
    // A remote that another remote already absorbed is not a separate head.
    assert(cloud_save_decide(H1, false, H1, @[H1], @[remote(H2, @[H1, H2], 1), remote(H3, @[H1, H2, H3], 2)], &heads) == CLOUD_SAVE_PULL);
    assert(heads.count == 1 && [heads[0][@"hash"] isEqual:H3]);
    assert(cloud_save_decide(H1, false, H1, @[H1], @[remote(H2, @[H1, H2], 1), remote(H3, @[H1, H3], 2)], &heads) == CLOUD_SAVE_ASK);
    assert(heads.count == 2 && [heads[0][@"hash"] isEqual:H3]);   // Newest first.
}

static void check_archive(NSString *root) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *save = [root stringByAppendingPathComponent:@"save"], *copy = [root stringByAppendingPathComponent:@"copy"];
    NSString *archive = [root stringByAppendingPathComponent:@"save.zmsave"];
    assert([cloud_save_archive([root stringByAppendingPathComponent:@"missing"], nil, NULL, NULL)
        isEqual:@"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"]);
    write_text([save stringByAppendingPathComponent:@"slot_00/progress.sav"], @"progress");
    write_text([save stringByAppendingPathComponent:@"option.sav"], @"options");
    [fm createDirectoryAtPath:[save stringByAppendingPathComponent:@"album"] withIntermediateDirectories:YES attributes:nil error:nil];
    uint64_t bytes = 0;
    NSString *hash = cloud_save_archive(save, archive, &bytes, NULL);
    assert(hash && bytes);
    write_text([save stringByAppendingPathComponent:@".DS_Store"], @"finder");
    assert([cloud_save_archive(save, nil, NULL, NULL) isEqual:hash]);
    assert(cloud_save_extract(archive, copy, hash));
    assert([read_text([copy stringByAppendingPathComponent:@"slot_00/progress.sav"]) isEqual:@"progress"]);
    assert([cloud_save_archive(copy, nil, NULL, NULL) isEqual:hash]);
    assert(!cloud_save_extract(archive, copy, H1) && ![fm fileExistsAtPath:copy]);   // Wrong or incomplete archive.
    // Entries may not climb out of the destination.
    NSMutableData *evil = [NSMutableData dataWithBytes:"ZMSAVE1\nF\x07\x00../evil" length:18];
    [evil appendBytes:"\x01\0\0\0\0\0\0\0x" length:9];
    assert([evil writeToFile:archive atomically:NO]);
    assert(!cloud_save_extract(archive, copy, hash) && ![fm fileExistsAtPath:[root stringByAppendingPathComponent:@"evil"]]);
    NSMutableData *orphan = [NSMutableData dataWithBytes:"ZMSAVE1\nF\x03\x00a/b" length:14];
    [orphan appendBytes:"\0\0\0\0\0\0\0\0" length:8];
    assert([orphan writeToFile:archive atomically:NO] && !cloud_save_extract(archive, copy, hash));
}

// One launch of one device: sync, then optionally play (change the save and commit) before quitting.
static int device_main(const char *directory, const char *cloud, const char *name, int choice, const char *play) {
    if (chdir(directory)) return 10;
    mkdir("work", 0700);
    __block bool asked = false;
    cloud_save_begin([NSURL fileURLWithPath:@(cloud) isDirectory:YES], @(name), ^(NSArray<NSString *> *titles, void (^done)(NSUInteger)) {
        asked = true;
        if (choice < 0 || (NSUInteger)choice >= titles.count) _exit(11);
        done((NSUInteger)choice);
    }, nil);
    cloud_save_wait();
    if (choice >= 0 && !asked) return 12;
    if (play) {
        write_text(@"work/save/slot_00/progress.sav", @(play));
        filesystem_committed(0);
        cloud_save_flush();
    }
    return 0;
}

static void launch(NSString *self_path, NSString *device, NSString *cloud, int choice, NSString *play) {
    const char *argv[] = {self_path.fileSystemRepresentation, "device", device.fileSystemRepresentation, cloud.fileSystemRepresentation,
        device.lastPathComponent.UTF8String, [NSString stringWithFormat:@"%d", choice].UTF8String, play.UTF8String, NULL};
    pid_t pid; int status;
    assert(!posix_spawn(&pid, argv[0], NULL, NULL, (char *const *)argv, environ));
    assert(waitpid(pid, &status, 0) == pid);
    if (!WIFEXITED(status) || WEXITSTATUS(status)) { fprintf(stderr, "device %s failed status=%d\n", argv[4], status); abort(); }
}

static NSString *progress(NSString *device) { return read_text([device stringByAppendingPathComponent:@"work/save/slot_00/progress.sav"]); }
static NSUInteger backups(NSString *device) {
    return [NSFileManager.defaultManager contentsOfDirectoryAtPath:[device stringByAppendingPathComponent:@"work/save-backups"] error:nil].count;
}

static void check_devices(NSString *self_path, NSString *root) {
    NSString *mac = [root stringByAppendingPathComponent:@"mac"], *phone = [root stringByAppendingPathComponent:@"phone"];
    NSString *cloud = [root stringByAppendingPathComponent:@"cloud"];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:phone withIntermediateDirectories:YES attributes:nil error:nil];
    write_text([mac stringByAppendingPathComponent:@"work/save/slot_00/progress.sav"], @"mac 1");
    launch(self_path, mac, cloud, -1, nil);                                 // First upload.
    launch(self_path, phone, cloud, -1, nil);                               // Empty device adopts it.
    assert([progress(phone) isEqual:@"mac 1"]);
    launch(self_path, phone, cloud, -1, @"phone 1");
    launch(self_path, mac, cloud, -1, nil);                                 // Fast-forward, keeping a backup.
    assert([progress(mac) isEqual:@"phone 1"] && backups(mac) == 1);
    // Both play offline: the phone's change never reached the cloud before the Mac published its own.
    write_text([phone stringByAppendingPathComponent:@"work/save/slot_00/progress.sav"], @"phone 2");
    launch(self_path, mac, cloud, -1, @"mac 2");
    launch(self_path, phone, cloud, 0, nil);                                // Keep the phone's save.
    assert([progress(phone) isEqual:@"phone 2"]);
    launch(self_path, mac, cloud, -1, nil);                                 // The Mac follows the choice silently.
    assert([progress(mac) isEqual:@"phone 2"]);
    write_text([mac stringByAppendingPathComponent:@"work/save/slot_00/progress.sav"], @"mac 3");
    launch(self_path, phone, cloud, -1, @"phone 3");
    launch(self_path, mac, cloud, 1, nil);                                  // Take the phone's save this time.
    assert([progress(mac) isEqual:@"phone 3"]);
    launch(self_path, phone, cloud, -1, nil);
    assert([progress(phone) isEqual:@"phone 3"]);
    NSArray *published = [fm contentsOfDirectoryAtPath:cloud error:nil];
    assert(published.count == 4);   // One archive and one manifest per device, nothing else.
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if ((argc == 6 || argc == 7) && !strcmp(argv[1], "device"))
            return device_main(argv[2], argv[3], argv[4], atoi(argv[5]), argc == 7 ? argv[6] : NULL);
        char temp[] = "work/tmp/cloud-save.XXXXXX";
        assert(mkdtemp(temp));
        NSString *root = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:@(temp)];
        NSString *self_path = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:@(argv[0])];
        check_decisions();
        check_archive([root stringByAppendingPathComponent:@"archive"]);
        check_devices(self_path, [root stringByAppendingPathComponent:@"devices"]);
        [NSFileManager.defaultManager removeItemAtPath:root error:nil];
        puts("cloud save archive, decision and two-device sync checks passed");
    }
}
