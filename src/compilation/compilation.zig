const std = @import("std");

pub const Instruction = @import("instruction.zig");
pub const Condition = @import("condition.zig");

const Types = @import("shared_runtime").Types;
const AST = @import("ast");

pub fn getNumberType(str: []const u8) !Types.Special {
    const contains = struct {
        pub fn contains(s: []const u8, selected: u8) bool {
            for (s) |char| {
                if (char == selected) return true;
            }
            return false;
        }
    }.contains;

    if (contains(str, '.')) {
        return Types.Special{ .float = try std.fmt.parseFloat(f32, str) };
    } else {
        return Types.Special{ .integer = try std.fmt.parseInt(i32, str, 10) };
    }
}

/// Assuming gpa owns the std.ArrayList(T), converts to owned list,
/// dupes the list using arena and returns it.
pub fn toArenaOwnedSlice(comptime T: type, lst: *std.ArrayList(T), gpa: std.mem.Allocator, arena: std.mem.Allocator) ![]T {
    const owned = try lst.toOwnedSlice(gpa);
    defer gpa.free(owned);
    const duped = try arena.dupe(T, owned);
    return duped;
}

const TokenSlice = AST.TokenSlice;

pub const Diagnostic = struct {
    tag: ErrTag = undefined,

    pub const ErrTag = union(enum) {
        name_used_twice: struct {
            first: TokenSlice,
            second: TokenSlice,
        },
        unknown_name: TokenSlice,
        agent_in_argument: TokenSlice,
        name_used_once: TokenSlice,
    };

    pub const HandledError = error{
        AgentInArgument,
        UnknownName,
        NameUsedTwice,
        NameUsedOnce,
    };

    pub fn isHandledError(err: anyerror) bool {
        return switch (err) {
            HandledError.AgentInArgument,
            HandledError.UnknownName,
            HandledError.NameUsedTwice,
            HandledError.NameUsedOnce,
            => true,
            else => false,
        };
    }

    const Printing = @import("profiler").Printing;
    const Token = AST.Lexer.Token;

    fn multiLineMarkup(
        connectedSlices: []const TokenSlice,
        tokens: []const Token,
        lines: *const Printing.Lines,
        gpa: std.mem.Allocator,
    ) ![]const u8 {
        var _arena = std.heap.ArenaAllocator.init(gpa);
        defer _arena.deinit();

        const arena = _arena.allocator();
        const init_line = tokens[connectedSlices[0].start].loc.start.line;
        var idx = init_line;

        var list: std.ArrayList([]const u8) = .empty;
        defer list.deinit(gpa);

        for (connectedSlices) |slice| {
            const starting_line = tokens[slice.start].loc.start.line;
            const ending_line = tokens[slice.end].loc.end.line;

            while (idx < starting_line) : (idx += 1) {
                try list.append(gpa, try lines.getEnumerated(arena, idx));
            }

            if (ending_line == idx) {
                try list.append(gpa, try lines.getEnumerated(arena, idx));
                try list.append(gpa, try singleLineMarkup(&.{slice}, tokens, arena, Printing.Lines.enumeration_padding));
                idx += 1;
            } else {
                while (idx <= ending_line) : (idx += 1) {
                    const enumerated = try lines.getEnumerated(arena, idx);
                    try list.append(gpa, enumerated);

                    const markup_line = try arena.alloc(u8, enumerated.len);

                    if (idx == starting_line) {
                        const ch = tokens[slice.start].loc.start.ch + Printing.Lines.enumeration_padding;

                        @memset(markup_line, ' ');
                        markup_line[ch] = '^';

                        if (ch + 1 < markup_line.len)
                            @memset(markup_line[ch + 1 ..], '~');
                    } else if (idx == ending_line) {
                        const ch = tokens[slice.end].loc.end.ch + Printing.Lines.enumeration_padding;

                        @memset(markup_line, ' ');
                        @memset(markup_line[Printing.Lines.enumeration_padding .. ch + 1], '~');
                    } else {
                        @memset(markup_line[0..Printing.Lines.enumeration_padding], ' ');
                        @memset(markup_line[Printing.Lines.enumeration_padding..], '~');
                    }

                    try list.append(gpa, markup_line);
                }
            }
        }

        var ret: []const u8 = "";
        for (list.items) |line| {
            const cur = ret;
            defer gpa.free(cur);
            ret = try std.fmt.allocPrint(gpa, "{s}\n{s}", .{ ret, line });
        }

        return ret;
    }

    /// Doesn't check if the tokens are really on the same line. The caller owns the slice.
    fn singleLineMarkup(
        connectedSlices: []const TokenSlice,
        tokens: []const Token,
        allocator: std.mem.Allocator,
        padding: usize,
    ) ![]const u8 {
        const end = tokens[connectedSlices[connectedSlices.len - 1].end].loc.end.ch;
        const markup_line = try allocator.alloc(u8, end + padding);
        @memset(markup_line, ' ');
        for (connectedSlices) |slice| {
            markup_line[tokens[slice.start].loc.start.ch + padding] = '^';
            for (markup_line[tokens[slice.start].loc.start.ch + padding + 1 .. tokens[slice.end].loc.end.ch + padding]) |*c| {
                c.* = '~';
            }
        }
        return markup_line;
    }

    fn symbol(self: *const Diagnostic) []const u8 {
        return switch (self.tag) {
            .name_used_twice => "Name used more than twice",
            .unknown_name => "Unknown name",
            .agent_in_argument => "Agent in the argument list",
            .name_used_once => "Unused name: name has only been used once",
        };
    }

    fn hint(self: *const Diagnostic) []const u8 {
        return switch (self.tag) {
            .name_used_twice => "Names should be used exactly twice in one scope. Consider using duplicator agents (Dup2, Dup3, ...).",
            .unknown_name => "Check for typos.",
            .agent_in_argument =>
            \\What you're probably trying to do is nested pattern matching.
            \\Unfortunately it is either unimplemented or will never be implemented.
            \\Consider using real interaction nets nested pattern matching using additional helper agents.
            ,
            .name_used_once => "Check for typos. Names should be used exactly twice in one scope.",
        };
    }

    /// The message ends with a line break. The caller owns the message.
    pub fn getPrettyMessage(
        self: *const Diagnostic,
        source_file: [:0]const u8,
        tokens: []const Token,
        gpa: std.mem.Allocator,
    ) ![]const u8 {
        var lines = try Printing.Lines.init(gpa, source_file);
        defer lines.deinit();
        const start_token, const end_token, const connectedSlices: []const TokenSlice = switch (self.tag) {
            .unknown_name,
            .agent_in_argument,
            .name_used_once,
            => |tslice| .{ tokens[tslice.start], tokens[tslice.end], &.{tslice} },

            .name_used_twice,
            => |names| .{ tokens[names.first.start], tokens[names.second.end], &.{ names.first, names.second } },
        };

        if (start_token.loc.start.line == end_token.loc.end.line) {
            const line = lines.lines[start_token.loc.start.line];
            const marked_line = try singleLineMarkup(connectedSlices, tokens, gpa, 0);
            defer gpa.free(marked_line);
            return try std.fmt.allocPrint(
                gpa,
                "Rule compilation error on line {} index {}: {s}\n{s}\n{s}\n\nHint: {s}\n",
                .{
                    start_token.loc.start.line + 1,
                    start_token.loc.start.ch + 1,
                    self.symbol(),
                    line,
                    marked_line,
                    self.hint(),
                },
            );
        } else {
            const marked_lines = try multiLineMarkup(connectedSlices, tokens, &lines, gpa);
            defer gpa.free(marked_lines);
            return try std.fmt.allocPrint(
                gpa,
                "Rule compilation error starting on line {} index {}: {s}\n{s}\n\nHint: {s}\n",
                .{
                    start_token.loc.start.line + 1,
                    start_token.loc.start.ch + 1,
                    self.symbol(),
                    marked_lines,
                    self.hint(),
                },
            );
        }
    }
};
