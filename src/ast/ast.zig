pub const Parser = @import("parser.zig");
pub const Lexer = @import("lexer.zig");

pub const number_special_ident = "#number";
pub const cons_list_ident = "Cons";
pub const nil_list_ident = "Nil";

pub const TokenSlice = struct {
    start: u32,
    end: u32,

    pub fn combine(left: TokenSlice, right: TokenSlice) TokenSlice {
        return .{
            .start = left.start,
            .end = right.end,
        };
    }
};

pub fn Node(comptime T: type) type {
    return struct {
        val: T,
        tslice: TokenSlice,
    };
}

pub const Name = struct {
    val: []const u8,
};

pub const Object = struct {
    name: []const u8,
    portlist: ?[]Node(Object),

    pub fn isNumber(self: *const Object) bool {
        return self.name[0] == '#';
    }

    pub fn getNumberIfNumber(self: *const Object) ?[]const u8 {
        if (self.isNumber()) {
            return self.portlist.?[0].val.name;
        }
        return null;
    }
};

pub const ActivePair = struct {
    lhs: Node(Object),
    rhs: Node(Object),
};

pub const Expression = union(enum) {
    binary_op: BinaryExpr,
    unary_op: UnaryExpr,
    atom: Node(Object),

    pub const BinaryExpr = struct {
        lhs: *Node(Expression),
        rhs: *Node(Expression),
        tag: Tag,

        pub const Tag = enum {
            eq,
            logic_or,
            logic_and,
            less,
            leq,
            greater,
            geq,

            pub fn symbol(self: Tag) []const u8 {
                return switch (self) {
                    .eq => "==",
                    .logic_or => "||",
                    .logic_and => "&&",
                    .less => "<",
                    .leq => "<=",
                    .greater => ">",
                    .geq => ">=",
                };
            }
        };
    };

    pub const UnaryExpr = struct {
        item: *Node(Expression),
        tag: Tag,

        pub const Tag = enum {
            not,
        };
    };
};

pub const RuleExpression = struct {
    expr: ?*Node(Expression),
    pairs: []Node(ActivePair),
};

pub const Rule = struct {
    lhs: Node(Object),
    rhs: Node(Object),
    rule_exprs: []RuleExpression,
};

pub const Statement = union(enum) {
    free_stmt: []const Name,
    active_pair: ActivePair,
    rule: Rule,
    print_stmt: Name,
    use_stmt: []const u8,
    const_stmt,
};

pub const Program = struct {
    statements: []Node(Statement),
};

test {
    _ = &.{
        Lexer,
        Parser,
    };
}
