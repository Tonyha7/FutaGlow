const std = @import("std");
const windows = std.os.windows;

fn toUpper(c: u16) u16 {
    if (c >= 'a' and c <= 'z') return c - 'a' + 'A';
    return c;
}

pub fn fnv1a_16_ci(str: []const u16) u32 {
    var h: u32 = 2166136261;
    for (str) |c| {
        h = (h ^ toUpper(c)) *% 16777619;
    }
    return h;
}

pub fn fnv1a_8(str: []const u8) u32 {
    var h: u32 = 2166136261;
    for (str) |c| {
        h = (h ^ c) *% 16777619;
    }
    return h;
}

pub fn getModuleBase(hash: u32) usize {
    const peb = windows.peb();
    const ldr: *windows.PEB_LDR_DATA = peb.Ldr;
    var current = ldr.InMemoryOrderModuleList.Flink;
    const end = &ldr.InMemoryOrderModuleList;

    while (current != end) : (current = current.Flink) {
        const ptr = @intFromPtr(current) - 0x10;
        const entry_base = @as(*usize, @ptrFromInt(ptr + 0x30)).*;
        const unicode_sz = @as(*u16, @ptrFromInt(ptr + 0x58)).*;
        const unicode_buf = @as(*[*]u16, @ptrFromInt(ptr + 0x60)).*;

        const len = unicode_sz / 2;
        const sl = unicode_buf[0..len];

        const h = fnv1a_16_ci(sl);
        if (h == hash) {
            return entry_base;
        }
    }
    return 0;
}

pub fn getProcAddress(module: usize, hash: u32) usize {
    if (module == 0) return 0;

    const e_lfanew = @as(*u32, @ptrFromInt(module + 0x3C)).*;
    const nth = module + e_lfanew;

    // 24 (FileHeader) + 112 (DataDirectory offset in OptionalHeader x64) = 136
    const root_export_dir_va = @as(*u32, @ptrFromInt(nth + 136)).*;
    if (root_export_dir_va == 0) return 0;

    const exp_dir = module + root_export_dir_va;

    const num_names = @as(*u32, @ptrFromInt(exp_dir + 0x18)).*;
    const addrof_funcs = @as(*u32, @ptrFromInt(exp_dir + 0x1C)).*;
    const addrof_names = @as(*u32, @ptrFromInt(exp_dir + 0x20)).*;
    const addrof_ords = @as(*u32, @ptrFromInt(exp_dir + 0x24)).*;

    for (0..num_names) |i| {
        const name_rva = @as(*u32, @ptrFromInt(module + addrof_names + i * 4)).*;
        const name_ptr = @as([*:0]const u8, @ptrCast(@as(*anyopaque, @ptrFromInt(module + name_rva))));

        var h: u32 = 2166136261;
        var j: usize = 0;
        while (name_ptr[j] != 0) : (j += 1) {
            h = (h ^ name_ptr[j]) *% 16777619;
        }

        if (h == hash) {
            const ord = @as(*u16, @ptrFromInt(module + addrof_ords + i * 2)).*;
            const func_rva = @as(*u32, @ptrFromInt(module + addrof_funcs + ord * 4)).*;
            return module + func_rva;
        }
    }

    return 0;
}
