<h1 align="center">
  <picture>
    <img src="docs/assets/bancai-banner.svg" alt="bancai" width="720">
  </picture>
</h1>

<p align="center"><em>Parallel interaction nets interpreter in Zig</em></p>

<p align="center">
  <img src="https://img.shields.io/badge/zig-0.17-f7a41d?logo=zig&logoColor=white" alt="Zig 0.17">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-e8290f" alt="MIT license"></a>
  <img src="https://img.shields.io/badge/status-early%20development-ff6a12" alt="Status: early development">
</p>

Bancai is a parallel interaction nets interpreter, inspired by [Inpla](https://github.com/inpla/inpla). The language is Inpla's dialect.

Interaction nets is a computational model with some restrictions, that allow for trivial parallelism.

## How to run

Install zig compiler v0.17, then it's simple:

```
$ zig build
$ zig build test
$ zig build run -- -f ./tests/list_sorting.in
```

Note that this will compile in debug mode. For release mode use `-Doptimize=ReleaseFast`.

## Example

Sum a list with two rules:

```
Sum(r, acc) >< Cons(x, xs) =>
    Add(acc', acc) ~ x,
    Sum(r, acc') ~ xs;

Sum(r, acc) >< Nil() =>
    r ~ acc;

Sum(r, 0) ~ [1, 2, 3, 4];
r; free r;
```

```
$ zig build run -- -f sum.in
10
```

More examples live in `tests/`.

## Quick reference

You can read a basic user manual at [`docs/LANGUAGE.md`](docs/LANGUAGE.md).

## Current state

Bancai is in early development. Single-threaded evaluation of interaction nets, based on Inpla model, is fully implemented. A minimal version of parallel execution is implemented: run with `-t N` to use `N` threads. Build with `-Dprint-core-stats` to see how interactions are distributed between cores:

```
$ zig build -Dprint-core-stats
$ ./zig-out/bin/bancai -f ./tests/list_sorting.in -t 4
Cons(1, Cons(22, Cons(13, Cons(11, Cons(2, Cons(22, Cons(4, Cons(1, Cons(0, Nil())))))))))
Cons(0, Cons(1, Cons(1, Cons(2, Cons(4, Cons(11, Cons(13, Cons(22, Cons(22, Nil())))))))))
core-main: 0 interactions (0.0%)
core-0: 21 interactions (19.8%)
core-1: 49 interactions (46.2%)
core-2: 21 interactions (19.8%)
core-3: 15 interactions (14.2%)
total: 106 interactions
```

# Acknowledgement & Lineage

The project is a ground rewrite in **Zig** of the original C interpreter.

- **Original idea and implementation**: [Inpla](https://github.com/inpla/inpla) made by Shinya Sato.
- **License Note**: The core architecture and design are Copyright (c) 2022 Shinya Sato Released under the MIT license. This derivative work retains the original license terms (see `LICENSE-THIRD-PARTY`).
