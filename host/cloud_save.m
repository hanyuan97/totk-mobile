#import <Foundation/Foundation.h>
#include "cloud_save.h"
#include "filesystem.h"
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// Archive: "ZMSAVE1\n", then entries sorted by byte path: type ('D' or 'F'), u16 path length, UTF-8 path and, for
// files, u64 size and contents (little endian). The SHA-256 of the entries names a save on every device.
enum { HISTORY_LIMIT = 256, BACKUP_LIMIT = 10, PATH_LIMIT = 768, WAIT_SECONDS = 30, PUSH_DELAY = 20, RETRY_DELAY = 60 };
static const char magic[8] = {'Z', 'M', 'S', 'A', 'V', 'E', '1', '\n'};
static const uint64_t FILE_LIMIT = 1ull << 30, TOTAL_LIMIT = 4ull << 30;
static NSString *const state_path = @"work/cloud-save.json", *const upload_path = @"work/tmp/cloud-upload.zmsave";

static dispatch_queue_t queue;   // Owns everything below except the startup handshake.
static dispatch_group_t startup;
static dispatch_source_t timer;
static NSURL *cloud;
static NSString *device_label;
static NSMutableDictionary *state;   // work/cloud-save.json: device id, synced/pushed hashes, lineage.
static cloud_save_status report;
static bool dirty;
static atomic_bool asking;
static pthread_mutex_t settle = PTHREAD_MUTEX_INITIALIZER;
static bool abandoned;   // The game went ahead with the local save; a late download must not replace it.

typedef struct { FILE *out; CC_SHA256_CTX sha; uint64_t bytes; double newest; } writer;

static bool emit(writer *w, const void *data, size_t size) {
    CC_SHA256_Update(&w->sha, data, (CC_LONG)size); w->bytes += size;
    return !w->out || fwrite(data, 1, size, w->out) == size;
}

static bool emit_header(writer *w, char type, NSString *path) {
    const char *bytes = path.UTF8String; size_t length = strlen(bytes);
    uint8_t header[3] = {(uint8_t)type, (uint8_t)length, (uint8_t)(length >> 8)};
    return length && length <= PATH_LIMIT && emit(w, header, 3) && emit(w, bytes, length);
}

static bool walk(writer *w, NSString *root, NSString *relative) {
    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:
        relative.length ? [root stringByAppendingPathComponent:relative] : root error:nil];
    if (!names) return false;
    names = [names sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        int order = strcmp(a.UTF8String, b.UTF8String);
        return order < 0 ? NSOrderedAscending : order > 0 ? NSOrderedDescending : NSOrderedSame;
    }];
    for (NSString *name in names) {
        if ([name isEqualToString:@".DS_Store"]) continue;   // Finder litter is not save data.
        NSString *path = relative.length ? [relative stringByAppendingPathComponent:name] : name;
        NSString *full = [root stringByAppendingPathComponent:path];
        struct stat st;
        if (lstat(full.fileSystemRepresentation, &st)) return false;
        if (S_ISDIR(st.st_mode)) {
            if (!emit_header(w, 'D', path) || !walk(w, root, path)) return false;
            continue;
        }
        if (!S_ISREG(st.st_mode)) return false;
        double modified = st.st_mtimespec.tv_sec + st.st_mtimespec.tv_nsec / 1e9;
        if (modified > w->newest) w->newest = modified;
        uint64_t size = (uint64_t)st.st_size; uint8_t little[8];
        for (int i = 0; i < 8; i++) little[i] = (uint8_t)(size >> (8 * i));
        if (!emit_header(w, 'F', path) || !emit(w, little, 8)) return false;
        FILE *file = fopen(full.fileSystemRepresentation, "rb");
        if (!file) return false;
        uint8_t buffer[1 << 16]; uint64_t done = 0; bool ok = true;
        while (ok && done < size) {
            size_t count = fread(buffer, 1, (size_t)MIN((uint64_t)sizeof buffer, size - done), file);
            ok = count && emit(w, buffer, count); done += count;
        }
        ok = ok && fgetc(file) == EOF;   // A file that grew under us is not a snapshot.
        fclose(file);
        if (!ok) return false;
    }
    return true;
}

static NSString *hex(const uint8_t digest[CC_SHA256_DIGEST_LENGTH]) {
    NSMutableString *text = [NSMutableString stringWithCapacity:2 * CC_SHA256_DIGEST_LENGTH];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [text appendFormat:@"%02x", digest[i]];
    return text;
}

static bool valid_hash(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] != 2 * CC_SHA256_DIGEST_LENGTH) return false;
    return [value rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location == NSNotFound;
}

NSString *cloud_save_archive(NSString *directory, NSString *output, uint64_t *bytes, double *newest) {
    writer w = {0}; CC_SHA256_Init(&w.sha);
    if (output && !(w.out = fopen(output.fileSystemRepresentation, "wb"))) return nil;
    bool ok = !w.out || fwrite(magic, 1, sizeof magic, w.out) == sizeof magic;
    BOOL is_directory = NO;
    // A missing save directory is the empty save.
    if (ok && [NSFileManager.defaultManager fileExistsAtPath:directory isDirectory:&is_directory])
        ok = is_directory && walk(&w, directory, @"");
    if (w.out && fclose(w.out)) ok = false;
    if (!ok) { if (output) unlink(output.fileSystemRepresentation); return nil; }
    uint8_t digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest, &w.sha);
    if (bytes) *bytes = w.bytes;
    if (newest) *newest = w.newest;
    return hex(digest);
}

static bool safe_path(const char *path, size_t length) {
    if (strlen(path) != length || path[0] == '/' || path[length - 1] == '/') return false;
    for (const char *part = path; part; ) {
        const char *end = strchr(part, '/'); size_t size = end ? (size_t)(end - part) : strlen(part);
        if (!size || (size == 1 && part[0] == '.') || (size == 2 && part[0] == '.' && part[1] == '.')) return false;
        part = end ? end + 1 : NULL;
    }
    return true;
}

bool cloud_save_extract(NSString *archive, NSString *directory, NSString *hash) {
    FILE *in = fopen(archive.fileSystemRepresentation, "rb");
    if (!in) return false;
    [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
    if (mkdir(directory.fileSystemRepresentation, 0700)) { fclose(in); return false; }
    CC_SHA256_CTX sha; CC_SHA256_Init(&sha);
    char head[sizeof magic]; uint8_t buffer[1 << 16]; uint64_t total = 0;
    bool ok = fread(head, 1, sizeof head, in) == sizeof head && !memcmp(head, magic, sizeof magic);
    while (ok) {
        uint8_t header[3]; size_t got = fread(header, 1, 3, in);
        if (!got && feof(in)) break;
        size_t length = header[1] | (size_t)header[2] << 8; char path[PATH_LIMIT + 1];
        if (got != 3 || (header[0] != 'D' && header[0] != 'F') || !length || length > PATH_LIMIT ||
            fread(path, 1, length, in) != length) { ok = false; break; }
        path[length] = 0;
        NSString *name = [[NSString alloc] initWithBytes:path length:length encoding:NSUTF8StringEncoding];
        if (!name || !safe_path(path, length)) { ok = false; break; }
        CC_SHA256_Update(&sha, header, 3); CC_SHA256_Update(&sha, path, (CC_LONG)length);
        // Entries arrive parents first, so creating without intermediates also rejects out-of-order archives.
        const char *target = [directory stringByAppendingPathComponent:name].fileSystemRepresentation;
        if (header[0] == 'D') { ok = !mkdir(target, 0700); continue; }
        uint8_t little[8]; uint64_t size = 0;
        if (fread(little, 1, 8, in) != 8) { ok = false; break; }
        for (int i = 0; i < 8; i++) size |= (uint64_t)little[i] << (8 * i);
        CC_SHA256_Update(&sha, little, 8);
        if (size > FILE_LIMIT || size > TOTAL_LIMIT - total) { ok = false; break; }
        total += size;
        int fd = open(target, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (fd < 0) { ok = false; break; }
        for (uint64_t done = 0; ok && done < size; ) {
            size_t count = fread(buffer, 1, (size_t)MIN((uint64_t)sizeof buffer, size - done), in);
            ok = count && write(fd, buffer, count) == (ssize_t)count;
            CC_SHA256_Update(&sha, buffer, (CC_LONG)count); done += count;
        }
        if (close(fd)) ok = false;
    }
    fclose(in);
    uint8_t digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest, &sha);
    ok = ok && [hex(digest) isEqualToString:hash];
    if (!ok) [NSFileManager.defaultManager removeItemAtPath:directory error:nil];
    return ok;
}

// A remote save is a head when this device has never held it and no other remote save already supersedes it.
// Pull only fast-forwards an unchanged local save; anything that would drop progress asks.
int cloud_save_decide(NSString *local, bool empty, NSString *synced, NSArray<NSString *> *lineage,
                      NSArray<NSDictionary *> *remotes, NSArray<NSDictionary *> **heads) {
    NSMutableSet *known = [NSMutableSet setWithArray:lineage]; [known addObject:local];
    NSMutableArray<NSDictionary *> *found = [NSMutableArray array];
    for (NSDictionary *remote in remotes) {
        NSString *hash = remote[@"hash"];
        if ([known containsObject:hash] || [[found valueForKey:@"hash"] containsObject:hash]) continue;
        BOOL superseded = NO;
        for (NSDictionary *other in remotes)
            if (![other[@"hash"] isEqual:hash] && [other[@"history"] containsObject:hash]) superseded = YES;
        if (!superseded) [found addObject:remote];
    }
    [found sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"time"] compare:a[@"time"]]; }];
    if (heads) *heads = found;
    BOOL changed = synced.length ? ![local isEqualToString:synced] : !empty;
    if (!found.count) return changed && !empty ? CLOUD_SAVE_PUSH : CLOUD_SAVE_KEEP;
    if (found.count == 1 && (empty || (!changed && synced.length && [found[0][@"history"] containsObject:synced])))
        return CLOUD_SAVE_PULL;
    return CLOUD_SAVE_ASK;
}

static void save_state(void) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    if (![data writeToFile:state_path atomically:YES]) fprintf(stderr, "CLOUD_SAVE state write failed\n");
}

static void load_state(void) {
    NSData *data = [NSData dataWithContentsOfFile:state_path];
    id object = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] : nil;
    state = [object isKindOfClass:NSMutableDictionary.class] ? object : [NSMutableDictionary dictionary];
    id device = state[@"device"];
    if (![device isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:device]) state[@"device"] = NSUUID.UUID.UUIDString;
    for (NSString *key in @[@"synced", @"pushed"]) if (!valid_hash(state[key])) [state removeObjectForKey:key];
    NSMutableArray *lineage = [NSMutableArray array];
    if ([state[@"lineage"] isKindOfClass:NSArray.class]) for (id hash in state[@"lineage"]) if (valid_hash(hash)) [lineage addObject:hash];
    state[@"lineage"] = lineage;
    save_state();
}

static void remember(NSArray<NSString *> *hashes) {
    NSMutableArray *lineage = state[@"lineage"];
    for (NSString *hash in hashes) { [lineage removeObject:hash]; [lineage addObject:hash]; }
    if (lineage.count > HISTORY_LIMIT) [lineage removeObjectsInRange:NSMakeRange(0, lineage.count - HISTORY_LIMIT)];
}

static NSString *local_archive(NSString *output, uint64_t *bytes, double *newest) {
    NSString *copy = @"work/save.upload";
    if (filesystem_snapshot(0, copy.fileSystemRepresentation) && errno != ENOENT) {
        fprintf(stderr, "CLOUD_SAVE snapshot failed errno=%d\n", errno); return nil;
    }
    NSString *hash = cloud_save_archive(copy, output, bytes, newest);
    [NSFileManager.defaultManager removeItemAtPath:copy error:nil];
    if (!hash) fprintf(stderr, "CLOUD_SAVE local archive failed\n");
    return hash;
}

static BOOL coordinate(NSURL *url, BOOL writing, BOOL (^access)(NSURL *actual)) {
    __block BOOL ok = NO; NSError *error = nil;
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    // Coordinated reads also download items iCloud has not materialized yet.
    if (writing) [coordinator coordinateWritingItemAtURL:url options:NSFileCoordinatorWritingForReplacing error:&error
        byAccessor:^(NSURL *actual) { ok = access(actual); }];
    else [coordinator coordinateReadingItemAtURL:url options:NSFileCoordinatorReadingWithoutChanges error:&error
        byAccessor:^(NSURL *actual) { ok = access(actual); }];
    if (error) fprintf(stderr, "CLOUD_SAVE coordination failed name=%s code=%ld\n", url.lastPathComponent.UTF8String, (long)error.code);
    return ok;
}

static NSDictionary *manifest_from(NSData *data, NSString *device) {
    id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![object isKindOfClass:NSDictionary.class] || ![object[@"format"] isEqual:@1] || !valid_hash(object[@"hash"]) ||
        ![object[@"history"] isKindOfClass:NSArray.class] || ![object[@"device"] isKindOfClass:NSString.class] ||
        ![object[@"time"] isKindOfClass:NSNumber.class]) return nil;
    NSMutableArray *history = [NSMutableArray array];
    for (id hash in object[@"history"]) if (valid_hash(hash)) [history addObject:hash];
    return @{@"id": device, @"hash": object[@"hash"], @"history": history, @"device": object[@"device"], @"time": object[@"time"]};
}

static NSArray<NSDictionary *> *remote_manifests(void) {
    __block NSArray<NSString *> *names = nil;
    coordinate(cloud, NO, ^BOOL(NSURL *actual) { return (names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:actual.path error:nil]) != nil; });
    NSMutableArray *remotes = [NSMutableArray array];
    for (NSString *listed in names) {
        NSString *name = listed;
        // Older iCloud Drive clients list items that are not downloaded yet as ".<name>.icloud".
        if (name.length > 8 && [name hasPrefix:@"."] && [name hasSuffix:@".icloud"]) name = [name substringWithRange:NSMakeRange(1, name.length - 8)];
        NSString *device = name.stringByDeletingPathExtension;
        if (![name.pathExtension isEqualToString:@"json"] || ![[NSUUID alloc] initWithUUIDString:device] ||
            [device isEqualToString:state[@"device"]]) continue;
        __block NSData *data = nil;
        coordinate([cloud URLByAppendingPathComponent:name], NO, ^BOOL(NSURL *actual) { return (data = [NSData dataWithContentsOfURL:actual]) != nil; });
        NSDictionary *manifest = manifest_from(data, device);
        if (manifest) [remotes addObject:manifest];
        else fprintf(stderr, "CLOUD_SAVE ignored manifest %s\n", name.UTF8String);
    }
    return remotes;
}

static bool abandon_check(void) {
    pthread_mutex_lock(&settle); bool value = abandoned; pthread_mutex_unlock(&settle);
    return value;
}

static void prune_backups(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray *names = [[[fm contentsOfDirectoryAtPath:@"work/save-backups" error:nil]
        filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF ENDSWITH '-before-icloud'"]] sortedArrayUsingSelector:@selector(compare:)];
    for (NSUInteger i = 0; i + BACKUP_LIMIT < names.count; i++)
        [fm removeItemAtPath:[@"work/save-backups" stringByAppendingPathComponent:names[i]] error:nil];
}

static bool pull(NSDictionary *head) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *download = @"work/tmp/cloud-download.zmsave", *staged = @"work/save.cloud";
    NSURL *source = [cloud URLByAppendingPathComponent:[head[@"id"] stringByAppendingPathExtension:@"zmsave"]];
    bool ok = false;
    // A manifest can arrive before its archive; a hash mismatch means the matching archive is still on its way.
    for (unsigned attempt = 0; !ok && attempt < 10 && !abandon_check(); attempt++) {
        if (attempt) sleep(3);
        __block NSData *data = nil;
        ok = coordinate(source, NO, ^BOOL(NSURL *actual) { return (data = [NSData dataWithContentsOfURL:actual]) != nil; }) &&
            [data writeToFile:download atomically:NO] && cloud_save_extract(download, staged, head[@"hash"]);
        [fm removeItemAtPath:download error:nil];
    }
    if (!ok) { fprintf(stderr, "CLOUD_SAVE pull unavailable device=%s\n", [head[@"device"] UTF8String]); return false; }
    NSDateFormatter *format = [NSDateFormatter new]; format.dateFormat = @"yyyyMMdd-HHmmss";
    format.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    NSString *stamp = [format stringFromDate:NSDate.date], *backup = nil;
    for (unsigned copy = 1; !backup || [fm fileExistsAtPath:backup]; copy++)
        backup = [NSString stringWithFormat:copy == 1 ? @"work/save-backups/%@-before-icloud" : @"work/save-backups/%@-%u-before-icloud", stamp, copy];
    [fm createDirectoryAtPath:@"work/save-backups" withIntermediateDirectories:YES attributes:nil error:nil];
    pthread_mutex_lock(&settle);
    int status = abandoned ? -1 : filesystem_replace(0, staged.fileSystemRepresentation, backup.fileSystemRepresentation);
    pthread_mutex_unlock(&settle);
    if (status) {
        fprintf(stderr, "CLOUD_SAVE pull not applied errno=%d\n", errno);
        [fm removeItemAtPath:staged error:nil]; return false;
    }
    prune_backups();
    state[@"synced"] = head[@"hash"]; save_state();
    fprintf(stderr, "CLOUD_SAVE pulled device=%s hash=%.12s backup=%s\n", [head[@"device"] UTF8String], [head[@"hash"] UTF8String], backup.UTF8String);
    return true;
}

static bool upload(NSString *hash, uint64_t bytes) {
    NSString *device = state[@"device"];
    NSMutableArray *history = [state[@"lineage"] mutableCopy]; [history removeObject:hash]; [history addObject:hash];
    NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"format": @1, @"hash": hash, @"history": history, @"device": device_label,
        @"time": @(NSDate.date.timeIntervalSince1970), @"bytes": @(bytes)} options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
    NSURL *archive = [NSURL fileURLWithPath:upload_path];
    // The archive goes first so a manifest never names data that was not published.
    return coordinate([cloud URLByAppendingPathComponent:[device stringByAppendingPathExtension:@"zmsave"]], YES, ^BOOL(NSURL *actual) {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *partial = [actual URLByAppendingPathExtension:@"partial"];
        [fm removeItemAtURL:partial error:nil];
        if (![fm copyItemAtURL:archive toURL:partial error:nil]) return NO;
        BOOL placed = [fm fileExistsAtPath:actual.path] ?
            [fm replaceItemAtURL:actual withItemAtURL:partial backupItemName:nil options:0 resultingItemURL:nil error:nil] :
            [fm moveItemAtURL:partial toURL:actual error:nil];
        if (!placed) [fm removeItemAtURL:partial error:nil];
        return placed;
    }) && coordinate([cloud URLByAppendingPathComponent:[device stringByAppendingPathExtension:@"json"]], YES, ^BOOL(NSURL *actual) {
        return [json writeToURL:actual options:NSDataWritingAtomic error:nil];
    });
}

static void arm(unsigned seconds) {
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)seconds * NSEC_PER_SEC), DISPATCH_TIME_FOREVER, NSEC_PER_SEC);
}

static void push(void) {
    dirty = false;
    uint64_t bytes = 0;
    NSString *hash = local_archive(upload_path, &bytes, NULL);
    if (hash && bytes && ![hash isEqualToString:state[@"pushed"]]) {
        remember(@[hash]);
        if (upload(hash, bytes)) {
            state[@"pushed"] = hash; state[@"synced"] = hash; save_state();
            fprintf(stderr, "CLOUD_SAVE pushed hash=%.12s bytes=%llu\n", hash.UTF8String, bytes);
        } else { dirty = true; arm(RETRY_DELAY); fprintf(stderr, "CLOUD_SAVE push failed; retrying\n"); }
    }
    [NSFileManager.defaultManager removeItemAtPath:upload_path error:nil];
}

static NSString *title(NSDictionary *option, bool local) {
    NSString *when = [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:[option[@"time"] doubleValue]]
        dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle];
    return [NSString stringWithFormat:local ? @"%@ (this device) · %@" : @"%@ · %@", option[@"device"], when];
}

static void sync_at_startup(cloud_save_chooser choose) {
    uint64_t bytes = 0; double newest = 0;
    NSString *local = local_archive(nil, &bytes, &newest);
    if (!local) return;
    NSArray<NSDictionary *> *heads = nil;
    int action = cloud_save_decide(local, !bytes, state[@"synced"] ?: @"", state[@"lineage"], remote_manifests(), &heads);
    fprintf(stderr, "CLOUD_SAVE startup action=%d local=%.12s heads=%lu\n", action, local.UTF8String, (unsigned long)heads.count);
    if (action == CLOUD_SAVE_PUSH) push();
    else if (action == CLOUD_SAVE_PULL) {
        if (pull(heads[0])) { remember(@[local]); remember(heads[0][@"history"]); remember(@[heads[0][@"hash"]]); save_state(); }
    } else if (action == CLOUD_SAVE_ASK) {
        if (abandon_check()) return;
        NSMutableArray<NSDictionary *> *options = [NSMutableArray array];
        if (bytes) [options addObject:@{@"hash": local, @"device": device_label, @"time": @(newest), @"local": @YES}];
        [options addObjectsFromArray:[heads subarrayWithRange:NSMakeRange(0, MIN(heads.count, 3u))]];
        NSMutableArray<NSString *> *titles = [NSMutableArray array];
        for (NSDictionary *option in options) [titles addObject:title(option, option[@"local"] != nil)];
        dispatch_semaphore_t answered = dispatch_semaphore_create(0); __block NSUInteger index = 0;
        atomic_store(&asking, true);
        choose(titles, ^(NSUInteger value) { index = value; dispatch_semaphore_signal(answered); });
        dispatch_semaphore_wait(answered, DISPATCH_TIME_FOREVER);
        atomic_store(&asking, false);
        NSDictionary *chosen = options[MIN(index, options.count - 1)];
        fprintf(stderr, "CLOUD_SAVE chose device=%s hash=%.12s\n", [chosen[@"device"] UTF8String], [chosen[@"hash"] UTF8String]);
        if (!chosen[@"local"] && !pull(chosen)) return;   // Offer the same choice again next launch.
        // Saves set aside join the lineage; republishing it tells the other devices they were superseded.
        remember(@[local]);
        for (NSDictionary *head in heads) { remember(head[@"history"]); remember(@[head[@"hash"]]); }
        remember(@[chosen[@"hash"]]);
        state[@"synced"] = chosen[@"hash"]; [state removeObjectForKey:@"pushed"]; save_state();
        push();
    }
}

static void committed(unsigned volume) {
    if (volume) return;
    dispatch_async(queue, ^{ dirty = true; arm(PUSH_DELAY); });
}

NSURL *cloud_save_default_directory(void) {
    const char *setting = getenv("ZELDA_CLOUD_SAVE");
    if (setting && !strcmp(setting, "off")) return nil;
    if (setting && *setting) return [NSURL fileURLWithPath:@(setting) isDirectory:YES];
#if TARGET_OS_OSX
    NSURL *drive = [NSFileManager.defaultManager.homeDirectoryForCurrentUser URLByAppendingPathComponent:@"Library/Mobile Documents/com~apple~CloudDocs" isDirectory:YES];
    BOOL directory = NO;
    if ([NSFileManager.defaultManager fileExistsAtPath:drive.path isDirectory:&directory] && directory)
        return [drive URLByAppendingPathComponent:@"Zelda-Mobile" isDirectory:YES];
    fprintf(stderr, "CLOUD_SAVE off: iCloud Drive is not enabled\n");
#endif
    return nil;
}

void cloud_save_begin(NSURL *directory, NSString *device_name, cloud_save_chooser choose, cloud_save_status status) {
    if (!directory || queue) return;
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error] ||
        ![NSFileManager.defaultManager createDirectoryAtPath:@"work/tmp" withIntermediateDirectories:YES attributes:nil error:&error]) {
        fprintf(stderr, "CLOUD_SAVE off: folder unavailable code=%ld\n", (long)error.code); return;
    }
    cloud = directory; device_label = device_name.length ? device_name : @"Unknown device"; report = status;
    queue = dispatch_queue_create("zelda.cloud-save", DISPATCH_QUEUE_SERIAL);
    startup = dispatch_group_create();
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(timer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{ @autoreleasepool { if (dirty) push(); } });
    dispatch_resume(timer);
    filesystem_committed = committed;
    fprintf(stderr, "CLOUD_SAVE on folder=%s\n", directory.path.UTF8String);
    dispatch_group_async(startup, queue, ^{ @autoreleasepool { load_state(); sync_at_startup(choose); } });
    if (atexit(cloud_save_flush)) fprintf(stderr, "CLOUD_SAVE exit flush unavailable\n");
}

void cloud_save_wait(void) {
    if (!startup) return;
    for (unsigned waited = 0; dispatch_group_wait(startup, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)); ) {
        if (atomic_load(&asking)) continue;   // The player is choosing a save; no deadline.
        if (!waited++ && report) report(@"Syncing save with iCloud…");
        if (waited >= WAIT_SECONDS) {
            pthread_mutex_lock(&settle); abandoned = true; pthread_mutex_unlock(&settle);
            fprintf(stderr, "CLOUD_SAVE startup sync timed out; using the local save\n");
            return;
        }
    }
}

void cloud_save_flush(void) {
    // Before the startup sync settles there is nothing of this session to publish.
    if (!queue || dispatch_group_wait(startup, DISPATCH_TIME_NOW)) return;
    dispatch_sync(queue, ^{ @autoreleasepool { if (dirty) push(); } });
}
