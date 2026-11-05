#pragma once
int kernel_graphics_fault(void *address, int is_write, void *context);
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

uint32_t kernel_init(size_t image_bytes);
void kernel_destroy(void);
bool kernel_svc(unsigned number, uint64_t *regs);
bool kernel_event_create(uint32_t *write_handle, uint32_t *read_handle);
uint32_t kernel_event_copy(uint32_t read_handle);
bool kernel_access(uint64_t address, size_t size, unsigned permissions);
uint32_t kernel_readonly_page(const void *data);
uint32_t kernel_readonly_memory(const void *data, size_t size);
bool kernel_transfer_memory(uint32_t handle, uint64_t *address, uint64_t *size);
// Guest memory by Atmosphère's cheat regions (cheats.c): the heap's opened span (0 / 0 before the first SetHeapSize),
// copies into it under the memory lock (0 = every byte inside the span), the reserved guest block and its alias region.
void kernel_heap_range(uint64_t *base, size_t *size);
int kernel_heap_read(uint64_t address, void *out, size_t size);
int kernel_heap_write(uint64_t address, const void *data, size_t size);
bool kernel_guest_contains(uint64_t address);
void kernel_guest_range(uint8_t **base, size_t *size);
void kernel_alias_range(uint8_t **base, size_t *size);
