const std = @import("std");

const hegel_rust_url = "git@github.com:hegeldev/hegel-rust.git";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const no_bin = b.option(bool, "no-bin", "type-check without installing the example binary") orelse false;
    const hegel_rust_path_option = b.option(
        []const u8,
        "hegel-rust-path",
        "Path to a checkout of git@github.com:hegeldev/hegel-rust.git",
    );
    const hegel_rust_path = hegel_rust_path_option orelse ".deps/hegel-rust";

    const hegel_build = hegelRustBuildStep(b, hegel_rust_path, hegel_rust_path_option == null);
    const hegel_lib = hegelRustStaticLibraryPath(b, hegel_rust_path, target.result);

    const mod = b.addModule("hegel_zig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkHegel(mod, hegel_lib);

    const exe = b.addExecutable(.{
        .name = "hegel_zig_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "hegel_zig", .module = mod }},
        }),
    });
    exe.step.dependOn(hegel_build);
    if (no_bin) {
        b.getInstallStep().dependOn(&exe.step);
    } else {
        b.installArtifact(exe);
    }

    const run_step = b.step("run", "Run the example");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const mod_tests = b.addTest(.{ .root_module = mod });
    mod_tests.step.dependOn(hegel_build);
    const run_mod_tests = b.addRunArtifact(mod_tests);
    if (b.args) |args| run_mod_tests.addArgs(args);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    exe_tests.step.dependOn(hegel_build);
    const run_exe_tests = b.addRunArtifact(exe_tests);
    if (b.args) |args| run_exe_tests.addArgs(args);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

fn hegelRustBuildStep(
    b: *std.Build,
    hegel_rust_path: []const u8,
    should_clone_if_missing: bool,
) *std.Build.Step {
    var previous: ?*std.Build.Step = null;
    if (should_clone_if_missing) {
        const script = b.fmt(
            "set -eu\n" ++
                "if [ ! -d '{0s}/.jj' ] && [ ! -d '{0s}/.git' ]; then\n" ++
                "  mkdir -p .deps\n" ++
                "  if command -v jj >/dev/null 2>&1; then\n" ++
                "    jj git clone {1s} '{0s}'\n" ++
                "  else\n" ++
                "    git clone {1s} '{0s}'\n" ++
                "  fi\n" ++
                "fi\n",
            .{ hegel_rust_path, hegel_rust_url },
        );
        const clone = b.addSystemCommand(&.{ "sh", "-c", script });
        previous = &clone.step;
    }

    const manifest_path = b.pathJoin(&.{ hegel_rust_path, "Cargo.toml" });
    const cargo = b.addSystemCommand(&.{
        "cargo",
        "build",
        "-p",
        "hegeltest-c",
        "--release",
        "--manifest-path",
        manifest_path,
    });
    if (previous) |step| cargo.step.dependOn(step);
    return &cargo.step;
}

fn hegelRustStaticLibraryPath(
    b: *std.Build,
    hegel_rust_path: []const u8,
    target: std.Target,
) []const u8 {
    const lib_name = switch (target.os.tag) {
        .windows => "hegel_c.lib",
        else => "libhegel_c.a",
    };
    return b.pathJoin(&.{ hegel_rust_path, "target", "release", lib_name });
}

fn linkHegel(module: *std.Build.Module, hegel_lib: []const u8) void {
    module.addObjectFile(.{ .cwd_relative = hegel_lib });
    module.linkSystemLibrary("c", .{});
}
