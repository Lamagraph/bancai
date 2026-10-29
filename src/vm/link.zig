const std = @import("std");

const Runtime = @import("shared_runtime");
const Memory = Runtime.Memory;
const EquationFetcher = Runtime.EquationFetcher;
const Types = Runtime.Types;
const Name = Types.Name;
const Value = Types.Value;
const Equation = Types.Equation;
const EquationUnnormalized = Types.EquationUnnormalized;

const Debug = @import("debug");
const Config = @import("config");

pub fn link(name_heap: Memory.Heap(Name), lhs: Value, rhs: Value) ?Equation {
    var x = lhs;
    var y = rhs;
    while (true) {
        if (x != .name) std.mem.swap(Value, &x, &y);
        if (x != .name) return Equation{ .lhs = x.agent, .rhs = y.agent };

        x.name.assertArrival();
        const parked = x.name.swap(y) orelse return null;

        name_heap.freeOne(x.name);
        x = parked;
    }
}

pub fn pushEquation(
    name_heap: Memory.Heap(Name),
    equation_fetcher: EquationFetcher,
    eq: EquationUnnormalized,
) !void {
    if (link(name_heap, eq.lhs, eq.rhs)) |active_pair| {
        try equation_fetcher.push(active_pair);
    }
}

pub fn pushUrgentEquation(
    name_heap: Memory.Heap(Name),
    equation_fetcher: EquationFetcher,
    eq: EquationUnnormalized,
) !void {
    if (link(name_heap, eq.lhs, eq.rhs)) |active_pair| {
        try equation_fetcher.pushUrgent(active_pair);
    }
}
