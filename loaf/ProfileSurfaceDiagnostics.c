#if DEBUG
#include <IOSurface/IOSurface.h>
#include <execinfo.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdio.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>


static int loaf_surface_log = -1;
static _Thread_local int loaf_trace_busy;
static uint64_t loaf_profile_limit;
static _Atomic unsigned loaf_vm_requests[256];
static struct timespec loaf_surface_started;
__attribute__((constructor)) static void loaf_surface_trace_start(void) {
    clock_gettime(CLOCK_MONOTONIC, &loaf_surface_started);
    const char *value = getenv("LOAF_PROFILE_SURFACE_FD");
    if (value) {
        int descriptor = atoi(value);
        if (descriptor > 2) loaf_surface_log = descriptor;
    }
    const char *limit = getenv("LOAF_PROFILE_LIMIT_BYTES");
    if (limit && loaf_surface_log >= 0) loaf_profile_limit = strtoull(limit, NULL, 10);
}
static size_t loaf_surface_property(CFDictionaryRef properties, CFStringRef key) {
    CFTypeRef value = CFDictionaryGetValue(properties, key);
    int64_t number = 0;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) {
        CFNumberGetValue(value, kCFNumberSInt64Type, &number);
    }
    return number > 0 ? (size_t)number : 0;
}
static void loaf_trace_surface(const char *operation, IOSurfaceRef surface) {
    if (loaf_surface_log < 0 || !surface || loaf_trace_busy) return;
    loaf_trace_busy = 1;
    size_t bytes = IOSurfaceGetAllocSize(surface);
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    double elapsed = now.tv_sec - loaf_surface_started.tv_sec
        + (now.tv_nsec - loaf_surface_started.tv_nsec) / 1000000000.0;
    char row[256];
    int length = snprintf(row, sizeof(row), "%.3f %s pid=%d id=%u width=%zu height=%zu bytes=%zu\n",
                          elapsed, operation, getpid(), IOSurfaceGetID(surface),
                          IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface), bytes);
    if (length > 0 && length < sizeof(row)) write(loaf_surface_log, row, (size_t)length);
    if (bytes >= 16 * 1024 * 1024) {
        void *frames[40];
        int count = backtrace(frames, 40);
        backtrace_symbols_fd(frames, count, loaf_surface_log);
    }
    loaf_trace_busy = 0;
}
static IOSurfaceRef loaf_surface_create(CFDictionaryRef properties) {
    if (loaf_surface_log >= 0 && properties && !loaf_trace_busy) {
        size_t bytes = loaf_surface_property(properties, kIOSurfaceAllocSize);
        size_t width = loaf_surface_property(properties, kIOSurfaceWidth);
        size_t height = loaf_surface_property(properties, kIOSurfaceHeight);

        if (bytes >= 16 * 1024 * 1024 || width > 8192 || height > 8192) {
            loaf_trace_busy = 1;
            char row[256];
            int length = snprintf(row, sizeof(row), "request pid=%d width=%zu height=%zu bytes=%zu\n",
                                  getpid(), width, height, bytes);
            if (length > 0 && length < sizeof(row)) write(loaf_surface_log, row, (size_t)length);
            void *frames[40];
            backtrace_symbols_fd(frames, backtrace(frames, 40), loaf_surface_log);
            loaf_trace_busy = 0;
        }
    }
    IOSurfaceRef surface = IOSurfaceCreate(properties);
    loaf_trace_surface("create", surface);
    return surface;
}
static IOSurfaceRef loaf_surface_lookup(IOSurfaceID identifier) {
    IOSurfaceRef surface = IOSurfaceLookup(identifier);
    loaf_trace_surface("lookup", surface);
    return surface;
}
static IOSurfaceRef loaf_surface_import(mach_port_t port) {
    IOSurfaceRef surface = IOSurfaceLookupFromMachPort(port);
    loaf_trace_surface("import", surface);
    return surface;
}
static void loaf_trace_vm(const char *operation, uint64_t size, int flags, int purgeable) {
    if (loaf_surface_log < 0 || (size < 16 * 1024 * 1024 && !purgeable) || loaf_trace_busy) return;
    loaf_trace_busy = 1;
    unsigned tag = ((unsigned)flags >> 24) & 255;
    unsigned request = atomic_fetch_add_explicit(&loaf_vm_requests[tag], 1, memory_order_relaxed);
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    double elapsed = now.tv_sec - loaf_surface_started.tv_sec
        + (now.tv_nsec - loaf_surface_started.tv_nsec) / 1000000000.0;
    char row[256];
    int length = snprintf(row, sizeof(row), "%.3f %s pid=%d bytes=%llu flags=0x%x tag=%u purgeable=%d request=%u\n",
                          elapsed, operation, getpid(), (unsigned long long)size,
                          flags, tag, purgeable, request);
    if (length > 0 && length < sizeof(row)) write(loaf_surface_log, row, (size_t)length);
    if (size >= 16 * 1024 * 1024 || request < 4 || request % 32 == 0) {
        void *frames[40];
        backtrace_symbols_fd(frames, backtrace(frames, 40), loaf_surface_log);
    }
    if (loaf_profile_limit && purgeable) {
        task_vm_info_data_t memory = {0};
        mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
        if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&memory, &count) == KERN_SUCCESS
            && count >= TASK_VM_INFO_REV1_COUNT
            && (memory.phys_footprint >= loaf_profile_limit || size > loaf_profile_limit - memory.phys_footprint)) {
            length = snprintf(row, sizeof(row), "PREVENTED pid=%d bytes=%llu footprint=%llu limit=%llu\n",
                              getpid(), (unsigned long long)size,
                              (unsigned long long)memory.phys_footprint, (unsigned long long)loaf_profile_limit);
            if (length > 0 && length < sizeof(row)) write(loaf_surface_log, row, (size_t)length);


            _exit(86);
        }
    }
    loaf_trace_busy = 0;
}
static kern_return_t loaf_vm_allocate(vm_map_t task, vm_address_t *address, vm_size_t size, int flags) {
    if (task == mach_task_self()) loaf_trace_vm("vm_allocate", size, flags, (flags & VM_FLAGS_PURGABLE) != 0);
    return vm_allocate(task, address, size, flags);
}
static kern_return_t loaf_mach_vm_allocate(vm_map_t task, mach_vm_address_t *address, mach_vm_size_t size, int flags) {
    if (task == mach_task_self()) loaf_trace_vm("mach_vm_allocate", size, flags, (flags & VM_FLAGS_PURGABLE) != 0);
    return mach_vm_allocate(task, address, size, flags);
}
static kern_return_t loaf_vm_map(vm_map_t task, vm_address_t *address, vm_size_t size, vm_address_t mask,
                                int flags, mem_entry_name_port_t object, vm_offset_t offset, boolean_t copy,
                                vm_prot_t protection, vm_prot_t maximum, vm_inherit_t inheritance) {
    if (task == mach_task_self()) loaf_trace_vm("vm_map", size, flags, (flags & VM_FLAGS_PURGABLE) != 0);
    return vm_map(task, address, size, mask, flags, object, offset, copy, protection, maximum, inheritance);
}
static kern_return_t loaf_mach_vm_map(vm_map_t task, mach_vm_address_t *address, mach_vm_size_t size,
                                     mach_vm_offset_t mask, int flags, mem_entry_name_port_t object,
                                     memory_object_offset_t offset, boolean_t copy, vm_prot_t protection,
                                     vm_prot_t maximum, vm_inherit_t inheritance) {
    if (task == mach_task_self()) loaf_trace_vm("mach_vm_map", size, flags, (flags & VM_FLAGS_PURGABLE) != 0);
    return mach_vm_map(task, address, size, mask, flags, object, offset, copy, protection, maximum, inheritance);
}
static kern_return_t loaf_memory_entry(vm_map_t task, memory_object_size_t *size, memory_object_offset_t offset,
                                       vm_prot_t permission, mach_port_t *handle, mem_entry_name_port_t parent) {
    if (size && (task == mach_task_self() || task == MACH_PORT_NULL)) {
        loaf_trace_vm("memory_entry", *size, permission, (permission & MAP_MEM_PURGABLE) != 0);
    }
    return mach_make_memory_entry_64(task, size, offset, permission, handle, parent);
}
static kern_return_t loaf_purgable_control(vm_map_t task, vm_address_t address, vm_purgable_t control, int *state) {
    if (task == mach_task_self() && state && control == VM_PURGABLE_SET_STATE
        && (*state & VM_PURGABLE_STATE_MASK) == VM_PURGABLE_NONVOLATILE) {
        loaf_trace_vm("nonvolatile", 0, *state, 1);
    }
    return vm_purgable_control(task, address, control, state);
}
static kern_return_t loaf_mach_purgable_control(vm_map_t task, mach_vm_address_t address, vm_purgable_t control, int *state) {
    if (task == mach_task_self() && state && control == VM_PURGABLE_SET_STATE
        && (*state & VM_PURGABLE_STATE_MASK) == VM_PURGABLE_NONVOLATILE) {
        loaf_trace_vm("mach_nonvolatile", 0, *state, 1);
    }
    return mach_vm_purgable_control(task, address, control, state);
}
#define LOAF_INTERPOSE(replacement, original) \
    __attribute__((used, section("__DATA,__interpose"))) \
    static const struct { const void *replacement; const void *original; } \
    loaf_interpose_##original = { (const void *)&replacement, (const void *)&original };
LOAF_INTERPOSE(loaf_surface_create, IOSurfaceCreate)
LOAF_INTERPOSE(loaf_surface_lookup, IOSurfaceLookup)
LOAF_INTERPOSE(loaf_surface_import, IOSurfaceLookupFromMachPort)
LOAF_INTERPOSE(loaf_vm_allocate, vm_allocate)
LOAF_INTERPOSE(loaf_mach_vm_allocate, mach_vm_allocate)
LOAF_INTERPOSE(loaf_vm_map, vm_map)
LOAF_INTERPOSE(loaf_mach_vm_map, mach_vm_map)
LOAF_INTERPOSE(loaf_memory_entry, mach_make_memory_entry_64)
LOAF_INTERPOSE(loaf_purgable_control, vm_purgable_control)
LOAF_INTERPOSE(loaf_mach_purgable_control, mach_vm_purgable_control)
#endif
