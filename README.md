# bancai

Bancai is a (not yet) parallel interaction nets interpreter, inspired by [Inpla](https://github.com/inpla/inpla). The language is Inpla's dialect.

Interaction nets is a computational model with some restrictions, that allow for trivial parallelism.

## How to run

Install zig compiler v0.16, then it's simple:

```
$ zig build
$ zig build test
$ zig build run -- -f ./tests/list_sorting.in
```

Note that this will compile in debug mode. For release mode use `-Doptimize=ReleaseFast`.

## Quick reference

You can read a basic user manual at `docs/LANGUAGE.md`.

## Current state

Bancai is in early development. Single-threaded evaluation of interaction nets, based on Inpla model, is fully implemented. Parallel execution is in active development.

# Acknowledgement & Lineage

The project is a ground rewrite in **Zig** of the original C interpreter.

- **Original idea and implementation**: [Inpla](https://github.com/inpla/inpla) made by Shinya Sato.
- **License Note**: The core architecture and design are Copyright (c) 2022 Shinya Sato Released under the MIT license. This derivative work retains the original license terms (see `LICENSE-THIRD-PARTY`).
