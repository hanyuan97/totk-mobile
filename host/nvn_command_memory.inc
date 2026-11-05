#define HOSTSEG_SZ (1u << 20)
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#define HOSTSEG_LIMIT (256ull << 20)
#else
#define HOSTSEG_LIMIT (1024ull << 20)
#endif
// Host overflow memory stands in for guest command memory that the game sized for hardware commands (ours are
// larger). An extent should live as long as the guest bytes that were in use when it spilled: the game reuses
// command memory only after the commands in it are done, so recording new commands over those bytes should end the
// extent. Only bytes actually written count: a grant (AddCommandMemory) often runs to the end of its pool, past
// what the buffer will use, so it says nothing about lists elsewhere in it. Two exceptions:
// - An extent stays while its owner is still recording the list that spilled into it.
// - Spills with no guest memory behind them stay until exit.
// shortcut: freeing on that rule still let a list called three levels deep read garbage after 28 minutes (2026-11-05;
// cause not found). So a released extent is zeroed and quarantined for HOSTSEG_QUARANTINE frames before it is handed
// out again: a list that still reads it meanwhile meets an all-zero header, which the replay ends cleanly, and
// zelda_command_describe reports the release frame. New extents are zero-filled for the same reason. Loading a save
// in the Depths took about 14 MiB a minute, so freeing (or reusing) is required; the quarantine keeps about a minute.
#define HOSTSEG_QUARANTINE 3600
typedef struct { uint8_t *mem; size_t size; const uint8_t *guest, *guest_end; const cmd_t *owner; const uint8_t *begin; uint64_t taken, released; } hostseg_extent;
static hostseg_extent *g_hostseg, *g_hostseg_retired;   // unreleased / released, oldest release first from g_hostseg_retired_head
static size_t g_hostseg_n, g_hostseg_cap, g_hostseg_retired_head, g_hostseg_retired_n, g_hostseg_retired_cap, g_hostseg_live, g_hostseg_total, g_hostseg_peak;
static uint64_t g_hostseg_taken, g_hostseg_released;
static pthread_mutex_t g_hostseg_mu = PTHREAD_MUTEX_INITIALIZER;
static int hostseg_holds(const hostseg_extent *e, const uint8_t *p) { return p && p >= e->mem && p <= e->mem + e->size; }
static void hostseg_append(hostseg_extent **list, size_t *n, size_t *cap, hostseg_extent e) {
    if (*n == *cap) {
        *cap = *cap ? *cap * 2 : 64;
        *list = realloc(*list, *cap * sizeof **list);
        if (!*list) die("NVN overflow table allocation failed");
    }
    (*list)[(*n)++] = e;
}
static uint8_t *hostseg_take_for(size_t size, const cmd_t *owner) {
    if (!size || size > HOSTSEG_SZ || (size & 7)) die("NVN overflow allocation size");
    pthread_mutex_lock(&g_hostseg_mu);
    if (g_hostseg_total + size > HOSTSEG_LIMIT)
        die("NVN overflow storage exhausted (%zu MiB kept, %zu KiB unreleased in %zu extents, %llu taken, %llu released)",
            g_hostseg_total >> 20, g_hostseg_live / 1024, g_hostseg_n, (unsigned long long)g_hostseg_taken, (unsigned long long)g_hostseg_released);
    uint64_t frame = dm_nvn_frame_count();
    uint8_t *memory = NULL;
    // Reuse the oldest released extent past its quarantine (already zero); quarantined extents of another size are freed.
    while (g_hostseg_retired_head < g_hostseg_retired_n && !memory) {
        hostseg_extent *old = &g_hostseg_retired[g_hostseg_retired_head];
        if (old->released + HOSTSEG_QUARANTINE > frame) break;
        g_hostseg_retired_head++;
        if (old->size == size) memory = old->mem;
        else { free(old->mem); g_hostseg_total -= old->size; }
    }
    if (g_hostseg_retired_head > 1024 && g_hostseg_retired_head * 2 > g_hostseg_retired_n) {
        memmove(g_hostseg_retired, g_hostseg_retired + g_hostseg_retired_head, (g_hostseg_retired_n - g_hostseg_retired_head) * sizeof *g_hostseg_retired);
        g_hostseg_retired_n -= g_hostseg_retired_head; g_hostseg_retired_head = 0;
    }
    if (memory) g_hostseg_total -= size;   // counted again below
    else if (!(memory = calloc(1, size))) die("NVN overflow allocation failed");
    hostseg_extent e = {memory, size, NULL, NULL, owner, owner ? owner->begin : NULL, frame, 0};
    if (owner && owner->guest_memory && owner->guest_used) { e.guest = owner->guest_memory; e.guest_end = owner->guest_memory + owner->guest_used; }
    hostseg_append(&g_hostseg, &g_hostseg_n, &g_hostseg_cap, e);
    g_hostseg_live += size; g_hostseg_total += size; g_hostseg_taken++;
    size_t live = g_hostseg_live, total = g_hostseg_total; uint64_t taken = g_hostseg_taken;
    int report = (total >> 20) > (g_hostseg_peak >> 20); if (total > g_hostseg_peak) g_hostseg_peak = total;
    pthread_mutex_unlock(&g_hostseg_mu);
    if (taken == 1 || !(taken & (taken - 1)) || report)
        LOG("NVN overflow memory: %zu KiB unreleased, %zu KiB with quarantine, %llu extents taken (%zu bytes now, %s)", live / 1024, total / 1024,
            (unsigned long long)taken, size, e.guest ? "released with its guest memory" : "no guest memory behind it");
    return memory;
}
// New commands were written over guest bytes [p, p + n): extents standing in for commands that were there are done.
static void hostseg_release(const uint8_t *p, size_t n) {
    pthread_mutex_lock(&g_hostseg_mu);
    uint64_t frame = dm_nvn_frame_count();
    for (size_t i = 0; i < g_hostseg_n;) {
        hostseg_extent *e = &g_hostseg[i];
        const cmd_t *o = e->owner;
        int recording = o && o->recording && (o->begin == e->begin || hostseg_holds(e, o->begin) || hostseg_holds(e, o->cur));
        if (e->guest && e->guest < p + n && p < e->guest_end && !recording) {
            e->released = frame; g_hostseg_live -= e->size; g_hostseg_released++;
            memset(e->mem, 0, e->size);
            hostseg_append(&g_hostseg_retired, &g_hostseg_retired_n, &g_hostseg_retired_cap, *e);
            g_hostseg[i] = g_hostseg[--g_hostseg_n];
        } else i++;
    }
    pthread_mutex_unlock(&g_hostseg_mu);
}
// Diagnostics for an invalid command record: which overflow extent holds the address, if any.
void zelda_command_describe(const void *address, char *out, size_t capacity) {
    const uint8_t *p = address;
    pthread_mutex_lock(&g_hostseg_mu);
    const hostseg_extent *found = NULL;
    for (size_t i = 0; i < g_hostseg_n && !found; i++) if (p >= g_hostseg[i].mem && p < g_hostseg[i].mem + g_hostseg[i].size) found = &g_hostseg[i];
    for (size_t i = g_hostseg_retired_head; i < g_hostseg_retired_n && !found; i++)
        if (p >= g_hostseg_retired[i].mem && p < g_hostseg_retired[i].mem + g_hostseg_retired[i].size) found = &g_hostseg_retired[i];
    if (!found) snprintf(out, capacity, "not overflow memory (guest command memory or elsewhere)");
    else snprintf(out, capacity, "overflow extent %p+%#zx offset %#zx taken frame %llu owner %p guest %p..%p %s%llu (now frame %llu)",
                  (void *)found->mem, found->size, (size_t)(p - found->mem), (unsigned long long)found->taken, (const void *)found->owner,
                  (const void *)found->guest, (const void *)found->guest_end, found->released ? "released frame " : "unreleased ",
                  (unsigned long long)found->released, (unsigned long long)dm_nvn_frame_count());
    pthread_mutex_unlock(&g_hostseg_mu);
}
// Release what the commands written so far in the current guest segment replaced (the +16 is a pending jump).
static void cmd_guest_written(const cmd_t *o) {
    if (o->guest_active && o->memory_start && o->cur > o->memory_start)
        hostseg_release(o->memory_start, (size_t)(o->cur - o->memory_start) + (o->recording && o->begin ? 16 : 0));
}
static void cmd_host_segment(cmd_t *o, size_t size) {
    cmd_guest_written(o);
    // The game advances its arena by GetCommandMemoryUsed; host spill bytes must not replace that count.
    if (o->guest_active) o->guest_used = o->cur - o->guest_memory + (o->recording && o->begin ? 16 : 0);
    o->guest_active = 0;
    cmd_new_segment(o, hostseg_take_for(size, o), size);
}
