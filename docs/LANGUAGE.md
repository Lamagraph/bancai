Bancai is an interaction nets interpreter, designed to be a playground for interaction nets implementation ideas. Bancai features an Inpla-like programming language. Users may define their own interaction rules and nets.

To follow along with the terminology, reading articles on Ives Lafont's interaction nets is advised. For basic introduction to bancai-specific implementation of interaction nets, skip ahead to the **Core ideas** section down below.

# Programming

To start a computation one must connect two agents with their principal ports. Agents connected that way form an _active pair_ (`~`):

```
// active pair that represents peano numerals addition: 1 + 1
Add(r, S(Z())) ~ S(Z());
```

This would prompt you with a "Unknown rule" error. Two agents can interact only if interaction rule for their marks is defined. Let's go ahead and define them. We need to specify the types of agents, for which we define the rule, and a list of active pairs, a concept that we already know:

```
// x + S(y) = S(x + y)
Add(r, x) >< S(y) =>
  r ~ S(w),
  Add(w, x) ~ y;

// x + 0 = 0
Add(r, x) >< Z() =>
  r ~ x;

// Defining an interaction net using the active pair (~) operator
Add(r, S(Z())) ~ S(Z());

// We can print the value, that some name points to, by referencing it on the top level.
r;
```

Notice, that `r` is the auxillary port that collects the result. This is a common pattern in interaction nets, which one may seem counter-intuitive, considering it is an auxillary port, not principal. Actually, a name having an agent on it means that the principal port of the agent is connected to the free port, i.e. name. In this implementation, if two agents are connected via primary ports, they have to interact (or throw `UnknownRule` error). This way, the result of an interaction forms a tree.

Interaction nets are not limited to one resulting values. **All** ports of some agents may be used as additional arguments to a computation, as well as its result. It is up to you to decide how to use them. Let's look at an example of using builtin duplicator agent (`Dup` or `Dup2`), and the use of builtin numeric extension:

```
// We don't have to put numbers inside a `Number` agent, but
// Since we don't really have types, just typing `x` seems off.
F(a, b) >< Number(x) =>
  Dup(x1, x2) ~ x,
  Add(a, 1) ~ x1,
  Add(b, 2) ~ x2;

F(a, b) ~ Number(3);

// Should print: "4 5"
a; b;
```

The usage of duplicator allows us to bypass the limitation of "using the name once" by eagerly copying the subnet, that it points to and providing references for the copied subnets. `a` and `b` are the results of computating `F(...) ~ Number(...)` net.

For now, that's all there is to it: rules and nets. For more interesting examples, you may look at the `tests` directory.

# Extension of interaction nets

While interaction nets can be used to compute anything, it will be rather painful to do so without extensions. Fortunately, bancai is designed to be a playground for testing such extensions.

Bancai currently has several extensions. Examples:

1. Builtin agents. Added by creating a separate table for builtin agents, that contains function pointers to their implementation, making it somewhat easy to add new ones.
2. Floating-point and integer numbers. These are added by extending the `Value` concept. Each number is translated to an agent with a reserved name `#number`, and one auxillary port which always contains the underlying number.
3. Conditional rules. Each rule can come with an optional list of conditions and implementation in case this condition is satisfied. Implemented by using an additional interpreter of expressions in the condition clause. The capabilities are now limited, but they can easily be extended.
4. Syntactic sugar for lists. `[]` is `Nil()`, `[a,b,c]` is `Cons(a, Cons(b, Cons(c, Nil())))`, `x:xs` is `Cons(x, xs)`.

# Core ideas

bancai is using two basic concepts to implement interaction nets: agents and names.

## Agent

Agent is the core thing behind interactions. Each agent has its "mark" or "type", that defines how it interacts with other agents, e.g.: `Agent()`, "Agent" is a mark. Agents may be seen as algebraic data type constructors in functional languages or as functions.

Agents can be connected to other agents in special places called _ports_. Each agent has a principal port, and a non-negative number of auxillary ports. This number is called _arity_. Arity is directly tied to agent's mark. You can see this restriction as "Any function has a fixed number of arguments" in conventional programming languages.

## Name

Name is a special reference. You can think of it as a variable or a function parameter.

Names have a restriction. They can only be used once (and they will appear twice in your programs, once coming in and once leaving the scope).

Under the hood bancai uses a concept called `Value`, which is basically a reference for another agent or name. This way, the agent is its identifier and a list of `Value`'s on auxillary ports. A name is simply an optional `Value`.

Names are specific to this current implementation. It is speculative whether we can represent ports in a different way more efficiently, without introducing these optional references.
