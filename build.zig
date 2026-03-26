const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const offsets_mod = b.createModule(.{
        .root_source_file = b.path("offsets.zig"),
    });
    const schemas_mod = b.createModule(.{
        .root_source_file = b.path("client_dll.zig"),
    });

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_mod.addImport("offsets", offsets_mod);
    root_mod.addImport("client_dll", schemas_mod);

    const lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "FutaGlow",
        .root_module = root_mod,
    });

    lib.root_module.strip = true;
    b.installArtifact(lib);
}
