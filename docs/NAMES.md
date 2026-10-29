# Names and agents

An **`Agent`** is a node of the interaction net. A **`Name`** is a wire. A wire is shared
by its two ends, so a Name works as a small mailbox: the first end to arrive leaves a
value, the second end takes it.

How rules create and connect these is in [RULES.md](RULES.md).

## 1. Agents

An agent has one principal port and `arity` aux ports. When two principal ports meet,
the agents form an active pair and a rule rewrites them.

```zig
Agent = { id, ports: [10]?Value }        // aux ports only
Value = name: *Name | agent: *Agent | special
```

There is no field for the principal port. A port that holds `.agent = A` is wired to
A's principal port, so a term like `Add(r, S(Z()))` is a tree of pointers:

```
  Add(r, S(Z()))

    +-----+
    | Add |  ports = [ name r, agent S ]
    +-----+                       |
                                  v
                               +-----+
                               |  S  |  ports = [ agent Z ]
                               +-----+             |
                                                   v
                                                +-----+
                                                |  Z  |  ports = [ ]
                                                +-----+
```

## 2. Names

A port that holds `.name = n` is wired to something not known yet. The other end holds
the same `*Name`:

```
      end 1                            end 2
  (Add.ports[0])                  (top-level "r")
        |                                |
        +--------->  +--------+  <-------+
                     | Name r |
                     |  box   |
                     +--------+
```

The box is one machine word (`std.atomic.Value(usize)`), so it can be swapped
atomically:

| box     | meaning                                   | stored as          |
|---------|-------------------------------------------|--------------------|
| EMPTY   | nothing has arrived yet                   | `0`                |
| agent A | one end left A, waiting for the other end | pointer            |
| name m  | one end joined this wire to wire `m`      | pointer, bit 0 set |

Agents and Names are 8-byte aligned, so bit 0 of a pointer is free for the tag.

## 3. Arriving: `link`

Every `~` (from a rule body, a builtin or the top level) ends up in `link` in
`src/vm/link.zig`. When one side is a Name, `link` arrives at it with one swap:

```
      core A                n.box                core B
        |                  [EMPTY]                 |
  swap(n, X) ---------->   [  X  ]                 |
  got EMPTY: done          [  X  ]                 |
  (never touches n again)  [  Y  ]  <--------- swap(n, Y)
        |                                  got X: owns n
        |                                  free(n)
        |                                  active pair X >< Y
        v                                          v
```

- Swap returns EMPTY: you were first. Your value waits in the box; forget `n`.
- Swap returns a value: you were second. The other end is gone for good, so you own
  `n`. Free it and keep linking the value you got.

Two swaps on one box always happen one after the other, so exactly one core gets EMPTY.
The swap is `acq_rel`, so ports written before parking an agent are visible to whoever
takes it.

All cases:

```
  agent ~ agent    active pair, goes to the queue

  name n ~ X       prev = swap(n, X)
                     EMPTY    ->  X waits in n, done
                     agent A  ->  free n, then link(A, X)
                     name m   ->  free n, then link(m, X)
```

`X` can be a name too. Then the box gets a forward to it, and wires form a chain.

## 4. Chains

```
  x ~ y;  y ~ z;

  [ x ] --> [ y ] --> [ z ]     x.box = ->y   y.box = ->z   z.box = EMPTY
```

Nobody walks a chain as a whole. An end that arrives at `x` with agent `A` takes one hop
per swap:

```
  link(x, A)        x       y       z
  ------------    -----   -----   -----
  start            ->y     ->z    EMPTY
  swap(x, A)      freed    ->z    EMPTY    got ->y, go to y
  swap(y, A)      freed   freed   EMPTY    got ->z, go to z
  swap(z, A)      freed   freed     A      got EMPTY, done
```

Each Name it frees had a full box, so that Name's other end already came and left. The
walker is always the last visitor of every Name it frees.

## 5. Looking without arriving

Some code needs to see what is on a wire without leaving anything there:

| function  | what it does                                             | used by                    |
|-----------|----------------------------------------------------------|----------------------------|
| `load`    | reads one box                                            | printing, `printStmt`      |
| `resolve` | follows full boxes, frees them, stops at agent or EMPTY  | conditions, Number, Dup, top-level reuse |
| `unwind`  | follows the chain read-only, returns the agent at the end | currently unused          |

```
  resolve(x):   [ x ] --> [ y ] --> S        returns S, frees x and y
                [ x ] --> [ y ] --> EMPTY    returns y, frees x
```

`resolve` never writes a box, so the other end can still arrive at `y` at any time.

## 6. Why it is safe

1. **Two ends per wire.** The compiler checks that every name in a rule is used exactly
   twice (`compileName` and `Scope.checkNameUsage` in `src/compilation/`). At the top
   level, a third use of a name creates a new `Name`.
2. **One owner per agent.** Only one core can reach an agent: the one evaluating its
   active pair, or the one that built it. Agent ports are plain memory.
3. **One swap per arrival.** The first end parks and leaves. The second end takes the
   value and frees the Name.

`-Dcheck-name-arrivals` (on by default in Debug builds) counts arrivals in `link` and
panics on a third one. When it is off, the counter field is `void` and `@sizeOf(Name)`
is 8 bytes.
