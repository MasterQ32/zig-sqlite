const std = @import("std");
const builtin = @import("builtin");

var sqlite3: ?*std.build.LibExeObjStep = null;

fn linkSqlite(b: *std.build.LibExeObjStep) void {
    b.linkLibC();

    if (sqlite3) |lib| {
        b.linkLibrary(lib);
    } else {
        b.linkSystemLibrary("sqlite3");
    }
}

fn getTarget(original_target: std.zig.CrossTarget, bundled: bool) std.zig.CrossTarget {
    if (bundled) {
        var tmp = original_target;

        if (tmp.isGnuLibC()) {
            const min_glibc_version = std.builtin.Version{
                .major = 2,
                .minor = 28,
                .patch = 0,
            };
            if (tmp.glibc_version) |ver| {
                if (ver.order(min_glibc_version) == .lt) {
                    std.debug.panic("sqlite requires glibc version >= 2.28", .{});
                }
            } else {
                tmp.setGnuLibCVersion(2, 28, 0);
            }
        }

        return tmp;
    }

    return original_target;
}

const TestTarget = struct {
    target: std.zig.CrossTarget = @as(std.zig.CrossTarget, .{}),
    mode: std.builtin.Mode = .Debug,
    single_threaded: bool = false,
    bundled: bool,
};

const all_test_targets = switch (builtin.target.cpu.arch) {
    .x86_64 => switch (builtin.target.os.tag) {
        .linux => [_]TestTarget{
            // Targets linux but other CPU archs.
            TestTarget{
                .target = .{},
                .bundled = false,
            },
            TestTarget{
                .target = .{
                    .cpu_arch = .x86_64,
                    .abi = .musl,
                },
                .bundled = true,
            },
            TestTarget{
                .target = .{
                    .cpu_arch = .i386,
                    .abi = .musl,
                },
                .bundled = true,
            },
            TestTarget{
                .target = .{
                    .cpu_arch = .aarch64,
                    .abi = .musl,
                },
                .bundled = true,
            },
            TestTarget{
                .target = .{
                    .cpu_arch = .riscv64,
                    .abi = .musl,
                },
                .bundled = true,
            },
            TestTarget{
                .target = .{
                    .cpu_arch = .mips,
                    .abi = .musl,
                },
                .bundled = true,
            },
            TestTarget{
                .target = .{
                    .cpu_arch = .arm,
                    .abi = .musleabihf,
                },
                .bundled = true,
            },
            // Targets windows
            TestTarget{
                .target = .{
                    .cpu_arch = .x86_64,
                    .os_tag = .windows,
                },
                .bundled = true,
            },
            TestTarget{
                .target = .{
                    .cpu_arch = .i386,
                    .os_tag = .windows,
                },
                .bundled = true,
            },
            // Targets macOS
            TestTarget{
                .target = .{
                    .cpu_arch = .x86_64,
                    .os_tag = .macos,
                },
                .bundled = true,
            },
            TestTarget{
                .target = .{
                    .cpu_arch = .aarch64,
                    .os_tag = .macos,
                },
                .bundled = true,
            },
        },
        .windows => [_]TestTarget{
            TestTarget{
                .target = .{
                    .cpu_arch = .x86_64,
                    .abi = .gnu,
                },
                .bundled = true,
            },
            TestTarget{
                .target = .{
                    .cpu_arch = .i386,
                    .abi = .gnu,
                },
                .bundled = true,
            },
        },
        .freebsd => [_]TestTarget{
            TestTarget{
                .target = .{},
                .bundled = false,
            },
            TestTarget{
                .target = .{
                    .cpu_arch = .x86_64,
                },
                .bundled = true,
            },
        },
        .macos => [_]TestTarget{
            TestTarget{
                .target = .{
                    .cpu_arch = .x86_64,
                },
                .bundled = true,
            },
        },
        else => [_]TestTarget{
            TestTarget{
                .target = .{},
                .bundled = false,
            },
        },
    },
    else => [_]TestTarget{
        TestTarget{
            .target = .{},
            .bundled = false,
        },
    },
};

pub fn build(b: *std.build.Builder) !void {
    const in_memory = b.option(bool, "in_memory", "Should the tests run with sqlite in memory (default true)") orelse true;
    const dbfile = b.option([]const u8, "dbfile", "Always use this database file instead of a temporary one");
    const use_bundled = b.option(bool, "use_bundled", "Use the bundled sqlite3 source instead of linking the system library (default false)");

    const target = b.standardTargetOptions(.{});

    // If the target is native we assume the user didn't change it with -Dtarget and run all test targets.
    // Otherwise we run a single test target.
    const test_targets = if (target.isNative())
        &all_test_targets
    else
        &[_]TestTarget{.{
            .target = target,
            .bundled = use_bundled orelse false,
        }};

    const test_step = b.step("test", "Run library tests");

    // By default the tests will only be execute for native test targets, however they will be compiled
    // for _all_ targets defined in `test_targets`.
    //
    // If you want to execute tests for other targets you can pass -fqemu, -fdarling, -fwine, -frosetta.

    for (test_targets) |test_target| {
        const bundled = use_bundled orelse test_target.bundled;
        const cross_target = getTarget(test_target.target, bundled);

        const tests = b.addTest("sqlite.zig");

        if (bundled) {
            const lib = b.addStaticLibrary("sqlite", null);
            lib.addCSourceFile("c/sqlite3.c", &[_][]const u8{"-std=c99"});
            lib.linkLibC();
            lib.setTarget(cross_target);
            lib.setBuildMode(test_target.mode);
            sqlite3 = lib;
        }

        const lib = b.addStaticLibrary("zig-sqlite", "sqlite.zig");
        if (bundled) lib.addIncludeDir("c");
        linkSqlite(lib);
        lib.setTarget(cross_target);
        lib.setBuildMode(test_target.mode);

        const single_threaded_txt = if (test_target.single_threaded) "single" else "multi";
        tests.setNamePrefix(b.fmt("{s}-{s}-{s} ", .{
            cross_target.zigTriple(b.allocator),
            @tagName(test_target.mode),
            single_threaded_txt,
        }));
        tests.single_threaded = test_target.single_threaded;
        tests.setBuildMode(test_target.mode);
        tests.setTarget(cross_target);
        if (bundled) tests.addIncludeDir("c");
        linkSqlite(tests);

        const tests_options = b.addOptions();
        tests.addOptions("build_options", tests_options);

        tests_options.addOption(bool, "in_memory", in_memory);
        tests_options.addOption(?[]const u8, "dbfile", dbfile);

        test_step.dependOn(&tests.step);
    }

    // Fuzzing

    const lib = b.addStaticLibrary("sqlite", null);
    lib.addCSourceFile("c/sqlite3.c", &[_][]const u8{"-std=c99"});
    lib.linkLibC();
    lib.setBuildMode(.Debug);
    lib.setTarget(getTarget(target, true));

    // The library
    const fuzz_lib = b.addStaticLibrary("fuzz-lib", "fuzz/main.zig");
    fuzz_lib.addIncludeDir("c");
    fuzz_lib.setBuildMode(.Debug);
    fuzz_lib.setTarget(getTarget(target, true));
    fuzz_lib.linkLibrary(lib);
    fuzz_lib.want_lto = true;
    fuzz_lib.bundle_compiler_rt = true;
    fuzz_lib.addPackagePath("sqlite", "sqlite.zig");

    // Setup the output name
    const fuzz_executable_name = "fuzz";
    const fuzz_exe_path = try std.fs.path.join(b.allocator, &.{ b.cache_root, fuzz_executable_name });

    // We want `afl-clang-lto -o path/to/output path/to/library`
    const fuzz_compile = b.addSystemCommand(&.{ "afl-clang-lto", "-o", fuzz_exe_path });
    fuzz_compile.addArtifactArg(lib);
    fuzz_compile.addArtifactArg(fuzz_lib);

    // Install the cached output to the install 'bin' path
    const fuzz_install = b.addInstallBinFile(.{ .path = fuzz_exe_path }, fuzz_executable_name);

    // Add a top-level step that compiles and installs the fuzz executable
    const fuzz_compile_run = b.step("fuzz", "Build executable for fuzz testing using afl-clang-lto");
    // fuzz_compile_run.dependOn(&fuzz_lib.step);
    fuzz_compile_run.dependOn(&fuzz_compile.step);
    fuzz_compile_run.dependOn(&fuzz_install.step);

    // Compile a companion exe for debugging crashes
    const fuzz_debug_exe = b.addExecutable("fuzz-debug", "fuzz/main.zig");
    fuzz_debug_exe.addIncludeDir("c");
    fuzz_debug_exe.setBuildMode(.Debug);
    fuzz_debug_exe.setTarget(getTarget(target, true));
    fuzz_debug_exe.linkLibrary(lib);
    fuzz_debug_exe.addPackagePath("sqlite", "sqlite.zig");

    // Only install fuzz-debug when the fuzz step is run
    const install_fuzz_debug_exe = b.addInstallArtifact(fuzz_debug_exe);
    fuzz_compile_run.dependOn(&install_fuzz_debug_exe.step);
}
