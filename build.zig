const std = @import("std");

const hegel_rust_url = "git@github.com:hegeldev/hegel-rust.git";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const no_bin = b.option(bool, "no-bin", "type-check without installing the example binary") orelse false;
    const supplied_library = b.option(
        []const u8,
        "hegel-rust-library",
        "Use a supplied native Hegel archive instead of cloning or running Cargo",
    );
    const hegel_rust_path_option = b.option(
        []const u8,
        "hegel-rust-path",
        "Path to a checkout of git@github.com:hegeldev/hegel-rust.git",
    );
    // Resolve the hegel-rust checkout relative to this package's build root,
    // not the consumer's cwd. A bare relative path resolves against whichever
    // `zig build` invocation runs the cargo/clone step, so when this package is
    // imported from another package the checkout would be cloned into the
    // consumer's tree. Rooting it here makes the default work standalone and as
    // a dependency; an explicitly absolute --hegel-rust-path is honored as-is.
    const hegel_rust_path_rel = hegel_rust_path_option orelse ".deps/hegel-rust";
    const hegel_rust_path = if (std.fs.path.isAbsolute(hegel_rust_path_rel))
        hegel_rust_path_rel
    else
        b.pathJoin(&.{
            b.root.toString(b.graph.arena) catch @panic("OOM"),
            hegel_rust_path_rel,
        });

    const hegel_rust_step = b.step("hegel-rust", "Prepare the hegel-rust static C library");
    const hegel_lib = if (supplied_library) |path|
        if (std.fs.path.isAbsolute(path)) path else b.pathJoin(&.{
            b.root.toString(b.graph.arena) catch @panic("OOM"),
            path,
        })
    else library: {
        const hegel_target_dir = hegelRustTargetDir(b, hegel_rust_path, target.result);
        hegel_rust_step.dependOn(hegelRustBuildStep(
            b,
            hegel_rust_path,
            hegel_target_dir,
            hegel_rust_path_option == null,
        ));
        break :library hegelRustStaticLibraryPath(b, hegel_target_dir, target.result);
    };

    const mod = b.addModule("hegel_zig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkHegel(mod, hegel_lib, target);

    // Consumers depend on `hegel-rust` before linking. A supplied archive has
    // an external producer; the linker still validates the archive it consumes.

    const exe = b.addExecutable(.{
        .name = "hegel_zig_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "hegel_zig", .module = mod }},
        }),
    });
    exe.step.dependOn(hegel_rust_step);
    if (no_bin) {
        b.getInstallStep().dependOn(&exe.step);
    } else {
        b.installArtifact(exe);
    }

    const run_step = b.step("run", "Run the example");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);

    const mod_tests = b.addTest(.{ .root_module = mod });
    mod_tests.step.dependOn(hegel_rust_step);
    const run_mod_tests = b.addRunArtifact(mod_tests);
    run_mod_tests.addPassthruArgs();

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    exe_tests.step.dependOn(hegel_rust_step);
    const run_exe_tests = b.addRunArtifact(exe_tests);
    run_exe_tests.addPassthruArgs();

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

fn hegelRustBuildStep(
    b: *std.Build,
    hegel_rust_path: []const u8,
    hegel_target_dir: []const u8,
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
        "--target-dir",
        hegel_target_dir,
    });
    if (previous) |step| cargo.step.dependOn(step);
    return &cargo.step;
}

fn hegelRustStaticLibraryPath(
    b: *std.Build,
    hegel_target_dir: []const u8,
    target: std.Target,
) []const u8 {
    const lib_name = switch (target.os.tag) {
        .windows => "hegel_c.lib",
        else => "libhegel_c.a",
    };
    return b.pathJoin(&.{ hegel_target_dir, "release", lib_name });
}

fn hegelRustTargetDir(
    b: *std.Build,
    hegel_rust_path: []const u8,
    target: std.Target,
) []const u8 {
    // Cargo's default target directory is shared by host platforms. Keep the
    // archive and its object files separated so a Linux VM cannot link a
    // previously built Darwin archive (or vice versa).
    const target_name = b.fmt(
        "target-{s}-{s}-{s}",
        .{ @tagName(target.os.tag), @tagName(target.cpu.arch), @tagName(target.abi) },
    );
    return b.pathJoin(&.{ hegel_rust_path, target_name });
}

fn linkHegel(
    module: *std.Build.Module,
    hegel_lib: []const u8,
    target: std.Build.ResolvedTarget,
) void {
    // `hegel_lib` is an absolute path rooted at this package's build root (see
    // `build`). A `cwd_relative` LazyPath resolves against the cwd of the
    // linking invocation, but an absolute sub-path wins over that cwd, so the
    // object file resolves correctly whether this module is used standalone or
    // imported from another package.
    module.addObjectFile(.{ .cwd_relative = hegel_lib });
    module.linkSystemLibrary("c", .{});
    if (target.result.os.tag == .linux) module.linkSystemLibrary("unwind", .{});
}
