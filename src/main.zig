const std = @import("std");
const windows = std.os.windows;
const stealth = @import("stealth.zig");

// Win32 API pointers
var pGetModuleHandleW: *const fn (?[*:0]const u16) callconv(.c) ?windows.HMODULE = undefined;
var pCreateThread: *const fn (?*anyopaque, usize, *const fn (?*anyopaque) callconv(.c) windows.DWORD, ?*anyopaque, windows.DWORD, ?*windows.DWORD) callconv(.c) ?windows.HANDLE = undefined;
var pFreeLibraryAndExitThread: *const fn (windows.HINSTANCE, windows.DWORD) callconv(.c) noreturn = undefined;
var pSleep: *const fn (windows.DWORD) callconv(.c) void = undefined;
var pGetAsyncKeyState: *const fn (i32) callconv(.c) i16 = undefined;

const d_offsets = @import("offsets").cs2_dumper.offsets;
const d_schemas = @import("client_dll").cs2_dumper.schemas;

const offsets = d_offsets.client_dll;
const schemas = d_schemas.client_dll;

fn read(comptime T: type, address: usize) T {
    const ptr = @as(*T, @ptrFromInt(address));
    return ptr.*;
}

fn write(comptime T: type, address: usize, value: T) void {
    const ptr = @as(*T, @ptrFromInt(address));
    ptr.* = value;
}

var g_client_base: usize = 0;
var g_engine2_base: usize = 0;

fn init() bool {
    const client_handle = pGetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("client.dll"));
    const engine_handle = pGetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("engine2.dll"));

    if (client_handle != null and engine_handle != null) {
        g_client_base = @intFromPtr(client_handle.?);
        g_engine2_base = @intFromPtr(engine_handle.?);
        return true;
    }
    return false;
}

fn getEntityList() usize {
    return read(usize, g_client_base + offsets.dwEntityList);
}

fn getLocalController() usize {
    return read(usize, g_client_base + offsets.dwLocalPlayerController);
}

const ENTITY_IDENTITY_SIZE: usize = 0x70;

fn getEntityByHandle(handle: u32) usize {
    if (handle == 0 or handle == 0xFFFFFFFF) return 0;

    const entityList = getEntityList();
    if (entityList == 0) return 0;

    const entityIndex: u32 = handle & 0x7FFF;
    const chunkIndex: u32 = entityIndex >> 9;
    const entryIndex: u32 = entityIndex & 0x1FF;

    const chunkAddr = entityList + 0x8 * chunkIndex + 0x10;
    const listEntry = read(usize, chunkAddr);

    if (listEntry == 0) return 0;

    const entityAddr = listEntry + ENTITY_IDENTITY_SIZE * entryIndex;
    const entity = read(usize, entityAddr);

    return entity;
}

fn espThread(module: ?*anyopaque) callconv(.c) windows.DWORD {
    // Wait for the game to load
    while (!init()) {
        pSleep(100);
    }

    // Virtual key END to exit
    const VK_END: i32 = 0x23;

    var c4_entity_id: u32 = 0;
    var last_round_start_count: u8 = 0;
    var last_bomb_planted: bool = false;

    while (true) {
        if (pGetAsyncKeyState(VK_END) < 0) {
            break;
        }

        //pSleep(1);

        const network_client = read(usize, g_engine2_base + d_offsets.engine2_dll.dwNetworkGameClient);
        if (network_client == 0) continue;

        const sign_on_state = read(i32, network_client + d_offsets.engine2_dll.dwNetworkGameClient_signOnState);
        // 6 = in-game
        if (sign_on_state != 6) {
            pSleep(100);
            continue;
        }

        const localCtrl = getLocalController();
        if (localCtrl == 0) continue;

        const localHandle = read(u32, localCtrl + schemas.CCSPlayerController.m_hPlayerPawn);
        const localPawn = getEntityByHandle(localHandle);
        if (localPawn == 0) continue;

        const localTeam = read(u8, localPawn + schemas.C_BaseEntity.m_iTeamNum);

        const gameRulesPtr = read(usize, g_client_base + d_offsets.client_dll.dwGameRules);
        var current_round_start_count: u8 = 0;
        var current_bomb_planted: bool = false;
        if (gameRulesPtr > 0x10000) {
            current_round_start_count = read(u8, gameRulesPtr + schemas.C_CSGameRules.m_nRoundStartCount);
            current_bomb_planted = read(bool, gameRulesPtr + schemas.C_CSGameRules.m_bBombPlanted);
        }

        const entityList = getEntityList();
        if (entityList == 0) continue;

        if (current_round_start_count != last_round_start_count) {
            last_round_start_count = current_round_start_count;
            c4_entity_id = 0;
        }

        if (current_bomb_planted != last_bomb_planted) {
            last_bomb_planted = current_bomb_planted;
            c4_entity_id = 0;
        }

        // Loop max clients (64)
        var i: u32 = 1;
        while (i <= 64) : (i += 1) {
            const listEntry = read(usize, entityList + (8 * (i >> 9)) + 0x10);
            if (listEntry <= 0x10000) continue;

            const controller = read(usize, listEntry + ENTITY_IDENTITY_SIZE * (i & 0x1FF));
            if (controller <= 0x10000 or controller == localCtrl) continue;

            const isAlive = read(bool, controller + schemas.CCSPlayerController.m_bPawnIsAlive);
            if (!isAlive) continue;

            const pawnHandle = read(u32, controller + schemas.CCSPlayerController.m_hPlayerPawn);
            if (pawnHandle == 0 or pawnHandle == 0xFFFFFFFF) continue;

            const pawn = getEntityByHandle(pawnHandle);
            if (pawn <= 0x10000 or pawn == localPawn) continue;

            const health = read(i32, pawn + schemas.C_BaseEntity.m_iHealth);
            if (health <= 0) continue;

            const team = read(u8, pawn + schemas.C_BaseEntity.m_iTeamNum);

            if (team == localTeam) continue;

            const colorInt: u32 = 0xFF0000FF;

            const glowOffset = schemas.C_BaseModelEntity.m_Glow;

            write(bool, pawn + glowOffset + schemas.CGlowProperty.m_bGlowing, true);
            write(i32, pawn + glowOffset + schemas.CGlowProperty.m_iGlowType, 3);
            write(u32, pawn + glowOffset + schemas.CGlowProperty.m_glowColorOverride, colorInt);
        }

        if (c4_entity_id == 0) {
            // Find C4 once per round (65 to 8192)
            var j: u32 = 65;
            while (j <= 8192) {
                const listEntry = read(usize, entityList + (8 * (j >> 9)) + 0x10);
                if (listEntry == 0) {
                    j = (j | 0x1FF) + 1;
                    continue;
                }

                const entity = read(usize, listEntry + ENTITY_IDENTITY_SIZE * (j & 0x1FF));
                if (entity > 0x10000) {
                    const identity = read(usize, entity + schemas.CEntityInstance.m_pEntity);
                    if (identity > 0x10000) {
                        const designerNamePtr = read(usize, identity + schemas.CEntityIdentity.m_designerName);
                        if (designerNamePtr > 0x10000) {
                            const nameBytes = read(u64, designerNamePtr);
                            // 'w' 'e' 'a' 'p' 'o' 'n' '_' 'c'  = 0x635f6e6f70616577 (weapon_c4)
                            // 'p' 'l' 'a' 'n' 't' 'e' 'd' '_'  = 0x5f6465746e616c70 (planted_c4)
                            if (current_bomb_planted) {
                                if (nameBytes == 0x5f6465746e616c70) {
                                    c4_entity_id = j;
                                    break;
                                }
                            } else {
                                if (nameBytes == 0x635f6e6f70616577) {
                                    c4_entity_id = j;
                                    break;
                                }
                            }
                        }
                    }
                }
                j += 1;
            }
        }

        if (c4_entity_id != 0) {
            const listEntry = read(usize, entityList + (8 * (c4_entity_id >> 9)) + 0x10);
            if (listEntry > 0x10000) {
                const entity = read(usize, listEntry + ENTITY_IDENTITY_SIZE * (c4_entity_id & 0x1FF));
                if (entity > 0x10000) {
                    const glowOffset = schemas.C_BaseModelEntity.m_Glow;
                    write(bool, entity + glowOffset + schemas.CGlowProperty.m_bGlowing, true);
                    write(i32, entity + glowOffset + schemas.CGlowProperty.m_iGlowType, 3); // 3 = Outline
                    write(u32, entity + glowOffset + schemas.CGlowProperty.m_glowColorOverride, 0xFF00FF00); // Green Glow
                } else {
                    c4_entity_id = 0;
                }
            } else {
                c4_entity_id = 0;
            }
        }
    }

    if (module) |hMod| {
        pFreeLibraryAndExitThread(@ptrCast(hMod), 0);
    }
    return 0;
}

const DLL_PROCESS_DETACH = 0;
const DLL_PROCESS_ATTACH = 1;
const DLL_THREAD_ATTACH = 2;
const DLL_THREAD_DETACH = 3;

pub export fn DllMain(hInstance: windows.HINSTANCE, fdwReason: windows.DWORD, lpvReserved: windows.LPVOID) windows.BOOL {
    _ = lpvReserved;
    switch (fdwReason) {
        DLL_PROCESS_ATTACH => {
            const kernel32_hash: u32 = 0x29cdd463; // fnv1a_16_ci("kernel32.dll")
            const user32_hash: u32 = 0x1a58c439; // fnv1a_16_ci("user32.dll")

            const kernel32_base = stealth.getModuleBase(kernel32_hash);

            if (kernel32_base != 0) {
                pGetModuleHandleW = @ptrCast(@as(*anyopaque, @ptrFromInt(stealth.getProcAddress(kernel32_base, stealth.fnv1a_8("GetModuleHandleW")))));
                pCreateThread = @ptrCast(@as(*anyopaque, @ptrFromInt(stealth.getProcAddress(kernel32_base, stealth.fnv1a_8("CreateThread")))));
                pFreeLibraryAndExitThread = @ptrCast(@as(*anyopaque, @ptrFromInt(stealth.getProcAddress(kernel32_base, stealth.fnv1a_8("FreeLibraryAndExitThread")))));
                pSleep = @ptrCast(@as(*anyopaque, @ptrFromInt(stealth.getProcAddress(kernel32_base, stealth.fnv1a_8("Sleep")))));
            }

            var user32_base = stealth.getModuleBase(user32_hash);

            if (user32_base == 0 and kernel32_base != 0) {
                const pLoadLibraryA: *const fn ([*:0]const u8) callconv(.c) ?windows.HMODULE = @ptrCast(@as(*anyopaque, @ptrFromInt(stealth.getProcAddress(kernel32_base, stealth.fnv1a_8("LoadLibraryA")))));
                if (pLoadLibraryA("user32.dll")) |u| {
                    user32_base = @intFromPtr(u);
                }
            }

            if (user32_base != 0) {
                pGetAsyncKeyState = @ptrCast(@as(*anyopaque, @ptrFromInt(stealth.getProcAddress(user32_base, stealth.fnv1a_8("GetAsyncKeyState")))));
            }

            _ = pCreateThread(null, 0, espThread, hInstance, 0, null);
        },
        else => {},
    }
    return windows.TRUE;
}
