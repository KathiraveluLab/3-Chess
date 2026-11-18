const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core_mod = b.addModule("three_chess", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "3-chess",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "three_chess", .module = core_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    const wasm_core_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });

    const wasm = b.addExecutable(.{
        .name = "3chess",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .imports = &.{
                .{ .name = "three_chess", .module = wasm_core_mod },
            },
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;

    const install_wasm_out = b.addInstallArtifact(wasm, .{});
    const install_wasm_web = b.addInstallFileWithDir(
        wasm.getEmittedBin(),
        .{ .custom = "../web" },
        "3chess.wasm",
    );
    b.getInstallStep().dependOn(&install_wasm_out.step);
    b.getInstallStep().dependOn(&install_wasm_web.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the 3-Chess CLI and server");
    run_step.dependOn(&run_cmd.step);

    const mod_tests = b.addTest(.{
        .root_module = core_mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run 96-cell engine and topology unit tests");
    test_step.dependOn(&run_mod_tests.step);
}
