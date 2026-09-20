//! SharedRuntime is a fat struct, a pointer to which is passed
//! around anywhere there is something shared in the vm.
//!
//! Replaces ugly(?) global variables.
const std = @import("std");

pub const Types = @import("types.zig");
pub const Memory = @import("memory.zig");
pub const EquationFetcher = @import("equation_fetcher.zig");

const Instruction = @import("compilation").Instruction;
const VM = @import("vm");
const Builtin = VM.Builtin;
const Importer = VM.Importer;
const Token = @import("ast").Lexer.Token;
const Debug = @import("debug");

const Config = @import("config");

const Self = @This();

const Agent = Types.Agent;
const Value = Types.Value;
const Name = Types.Name;
const AgentsKey = Instruction.AgentsKey;
const ConditionedRule = Instruction.ConditionedRule;

pub const File = struct {
    path: []const u8,
    contents: [:0]const u8,
    tokens: []Token,
};

pub const IdCountingHashMap = struct {
    map: std.StringHashMap(Agent.Id),
    free_id: Agent.Id = Builtin.user_agent_id_start,

    pub fn init(allocator: std.mem.Allocator) !IdCountingHashMap {
        // Another solution is just bypassing normal search in hashmap in get function
        var map = std.StringHashMap(Agent.Id).init(allocator);

        for (Builtin.builtin_agents) |builtin_ag| {
            try map.put(builtin_ag.name, Builtin.BuiltinNameMap.get(builtin_ag.name).?);
        }

        return .{
            .map = map,
        };
    }

    pub fn isNumber(self: *const IdCountingHashMap, id: Agent.Id) bool {
        _ = self;
        return id == Builtin.BuiltinNameMap.get(Builtin.number_builtin_ident).?;
    }

    pub fn findKey(self: *const IdCountingHashMap, val: Agent.Id) ?[]const u8 {
        var iterator = self.map.iterator();
        while (iterator.next()) |kv| {
            if (kv.value_ptr.* == val) {
                return kv.key_ptr.*;
            }
        }
        return null;
    }

    pub fn get(self: *IdCountingHashMap, key: []const u8) !Agent.Id {
        if (self.map.get(key)) |val| {
            return val;
        } else {
            Debug.log(.print_compiled_instructions, "Getting {} for key: {s}\n", .{ self.free_id, key });

            try self.map.put(key, self.free_id);
            defer self.free_id += 1;
            return self.free_id;
        }
    }
};

pub const ArityMap = struct {
    map: std.AutoHashMap(Agent.Id, Agent.Arity),

    pub fn get(self: *ArityMap, id: Agent.Id, port_count: usize) !Agent.Arity {
        if (self.map.get(id)) |arity| {
            if (arity != @as(u8, @intCast(port_count))) {
                return error.ArityMismatch;
            }
            return arity;
        } else {
            const arity: u8 = @intCast(port_count);
            try self.map.put(id, arity);
            return arity;
        }
    }

    pub fn arityOf(self: *const ArityMap, id: Agent.Id) Agent.Arity {
        return self.map.get(id).?;
    }

    pub fn init(allocator: std.mem.Allocator) !ArityMap {
        var map = std.AutoHashMap(Agent.Id, Agent.Arity).init(allocator);

        for (Builtin.builtin_agents) |builtin_ag| {
            try map.put(Builtin.BuiltinNameMap.get(builtin_ag.name).?, builtin_ag.arity);
        }

        return .{
            .map = map,
        };
    }
};

pub const RuleSearchResult = struct {
    rules: []ConditionedRule,
    tag: Tag,

    const Tag = enum {
        normal,
        swap,

        /// wildcard_lhs means that lhs is defined and rhs is a wildcard
        wildcard_lhs,
        wildcard_rhs,
    };
};

pub const RuleTable = struct {
    map: std.AutoHashMap(AgentsKey, []ConditionedRule),

    pub fn get(self: *const RuleTable, ap: AgentsKey) !RuleSearchResult {
        if (self.map.get(ap)) |rules| {
            return .{ .rules = rules, .tag = .normal };
        } else if (self.map.get(.{ .lhs = ap.rhs, .rhs = ap.lhs })) |rules| {
            return .{ .rules = rules, .tag = .swap };
        } else {
            return error.UnknownRule;
        }
    }
    pub fn init(allocator: std.mem.Allocator) RuleTable {
        return .{
            .map = std.AutoHashMap(AgentsKey, []ConditionedRule).init(allocator),
        };
    }
};

pub fn getAgentName(self: *const Self, agent_id: Agent.Id) ?[]const u8 {
    return self.agent_id_map.findKey(agent_id);
}

agent_id_map: IdCountingHashMap,
agent_arities: ArityMap,
associated_names: std.StringHashMap(?*Name),
io: std.Io,
threaded: *std.Io.Threaded,
_arena: *std.heap.ArenaAllocator,
arena: std.mem.Allocator,
gpa: std.mem.Allocator,

rule_table: RuleTable,
wildcard_table: std.AutoHashMap(Agent.Id, []ConditionedRule),

/// Importer contains the gpa, provided in .init(...)
importer: Importer,

main_file: File,

pub fn init(gpa: std.mem.Allocator, page: std.mem.Allocator, main_file: File) !Self {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(page);

    const threaded = try gpa.create(std.Io.Threaded);
    threaded.* = std.Io.Threaded.init(gpa, .{});

    const allocator = arena.allocator();
    try Builtin.init(allocator);

    return .{
        ._arena = arena,
        .arena = allocator,
        .gpa = gpa,
        .agent_id_map = try IdCountingHashMap.init(allocator),
        .associated_names = std.StringHashMap(?*Name).init(allocator),
        .agent_arities = try ArityMap.init(allocator),
        .rule_table = RuleTable.init(allocator),
        .wildcard_table = std.AutoHashMap(Agent.Id, []ConditionedRule).init(allocator),
        .threaded = threaded,
        .io = threaded.io(),
        .importer = .init(gpa),
        .main_file = main_file,
    };
}

pub fn deinit(self: *Self) void {
    Builtin.deinit();
    self.threaded.deinit();
    self.gpa.destroy(self.threaded);

    self._arena.deinit();
    self.gpa.destroy(self._arena);

    self.importer.deinit(self.gpa);
}

test {
    _ = .{
        Memory,
        Types,
    };
}
