const std = @import("std");
const HeapKind = @import("src/shared_runtime/memory.zig").HeapKind;

pub const DebugPrintConfig = struct {
    print_compiled_instructions: bool = false,
    print_interactions: bool = false,
    print_memory_usage: bool = false,
    print_frees: bool = false,
    benchmark: bool = false,
};

/// It doesn't return what you think it returns.
pub fn setupGoldenTesting(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) struct {
    *std.Build.Step.Run,
    *std.Build.Step.Run,
} {
    const golden_testing = b.addExecutable(.{
        .name = "golden_test_runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/golden_testing.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{},
        }),
    });
    b.installArtifact(golden_testing);
    const golden_testing_run_step = b.step("golden-test", "Run golden testing");
    const golden_testing_run_cmd = b.addRunArtifact(golden_testing);

    golden_testing_run_step.dependOn(&golden_testing_run_cmd.step);
    golden_testing_run_cmd.step.dependOn(b.getInstallStep());

    // tests for the tester

    const golden_testing_tests = b.addTest(.{
        .root_module = golden_testing.root_module,
    });
    return .{ golden_testing_run_cmd, b.addRunArtifact(golden_testing_tests) };
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod_ast = b.addModule("ast", .{
        .target = target,
        .root_source_file = b.path("src/ast/ast.zig"),
    });

    const mod_debug = b.addModule("debug", .{
        .target = target,
        .root_source_file = b.path("src/debug.zig"),
    });

    const mod_printing = b.addModule("printing", .{
        .root_source_file = b.path("src/printing/printing.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "debug", .module = mod_debug },
        },
    });

    const mod_shared_runtime = b.addModule("shared_runtime", .{
        .root_source_file = b.path("src/shared_runtime/runtime.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "debug", .module = mod_debug },
            .{ .name = "ast", .module = mod_ast },
        },
    });

    const mod_compilation = b.addModule("compilation", .{
        .root_source_file = b.path("src/compilation/compilation.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "ast", .module = mod_ast },
            .{ .name = "printing", .module = mod_printing },
            .{ .name = "shared_runtime", .module = mod_shared_runtime },
        },
    });

    const mod_vm = b.addModule("vm", .{
        .root_source_file = b.path("src/vm/vm.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "compilation", .module = mod_compilation },
            .{ .name = "ast", .module = mod_ast },
            .{ .name = "printing", .module = mod_printing },
            .{ .name = "shared_runtime", .module = mod_shared_runtime },
            .{ .name = "debug", .module = mod_debug },
        },
    });

    mod_shared_runtime.addImport("vm", mod_vm);
    mod_shared_runtime.addImport("compilation", mod_compilation);
    mod_compilation.addImport("vm", mod_vm);
    mod_printing.addImport("shared_runtime", mod_shared_runtime);
    mod_ast.addImport("printing", mod_printing);

    const submodules: []const std.Build.Module.Import = &.{
        .{ .name = "ast", .module = mod_ast },
        .{ .name = "printing", .module = mod_printing },
        .{ .name = "compilation", .module = mod_compilation },
        .{ .name = "shared_runtime", .module = mod_shared_runtime },
        .{ .name = "vm", .module = mod_vm },
        .{ .name = "debug", .module = mod_debug },
    };

    const exe = b.addExecutable(.{
        .name = "bancai",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = submodules,
        }),
        // To use llvm debugger:
        // .use_llvm = true,
    });

    // for perf
    exe.root_module.omit_frame_pointer = b.option(bool, "no-omit-frame-pointer", "Do not omit frame pointer");

    const clap = b.dependency("clap", .{});
    exe.root_module.addImport("clap", clap.module("clap"));

    const debug_printing = DebugPrintConfig{
        .print_compiled_instructions = b.option(bool, "print-compiled-instructions", "Print compiled instructions") orelse false,
        .print_interactions = b.option(bool, "print-interactions", "Print interaction points when they happen") orelse false,
        .print_memory_usage = b.option(bool, "print-memory-usage", "Print memory usage after top-level interactions") orelse false,
        .print_frees = b.option(bool, "print-frees", "Print message when a agent/name free happens") orelse false,
        .benchmark = b.option(bool, "benchmark", "Print time spent in interactions") orelse false,
    };

    const options = b.addOptions();
    options.addOption(DebugPrintConfig, "debug_printing", debug_printing);

    const heap_kind = b.option(HeapKind, "heap", "Which heap implementation to use") orelse .objpool;
    options.addOption(HeapKind, "heap", heap_kind);

    const mod_options = options.createModule();

    mod_printing.addImport("config", mod_options);
    mod_shared_runtime.addImport("config", mod_options);
    mod_debug.addImport("config", mod_options);
    mod_compilation.addImport("config", mod_options);
    mod_vm.addImport("config", mod_options);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run bancai");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const golden_testing_run_cmd, const run_golden_tests_tests = setupGoldenTesting(b, target, optimize);

    const generate_goldens = b.option(bool, "generate", "Generate golden tests") orelse false;
    const mode_str = if (generate_goldens) "generate" else "compare";

    golden_testing_run_cmd.addArtifactArg(exe);
    golden_testing_run_cmd.addArg(mode_str);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    for (submodules) |submodule| {
        const submodule_tests = b.addTest(.{ .root_module = submodule.module, .name = submodule.name });
        const run_submodule_tests = b.addRunArtifact(submodule_tests);
        test_step.dependOn(&run_submodule_tests.step);
    }

    test_step.dependOn(&run_golden_tests_tests.step);
    test_step.dependOn(&golden_testing_run_cmd.step);
}
