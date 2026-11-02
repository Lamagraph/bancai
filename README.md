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
$ zig build run -- -f ./tests/sorting.in
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
$ ./zig-out/bin/bancai -f ./tests/sorting.in -t 4
Cons(1, Cons(2, Cons(3, Cons(4, Cons(5, Cons(6, Cons(7, Cons(8, Cons(9, Cons(10, Cons(11, Cons(12, Cons(13, Cons(14, Cons(15, Cons(16, Cons(17, Cons(18, Cons(19, Cons(20, Cons(21, Cons(22, Cons(23, Cons(24, Cons(25, Cons(26, Cons(27, Cons(28, Cons(29, Cons(30, Nil()))))))))))))))))))))))))))))))
core-main: 0 interactions (0.0%)
core-0: 116 interactions (25.2%)
core-1: 122 interactions (26.5%)
core-2: 113 interactions (24.6%)
core-3: 109 interactions (23.7%)
total: 460 interactions
```

# Acknowledgement & Lineage

The project is a ground rewrite in **Zig** of the original C interpreter.

- **Original idea and implementation**: [Inpla](https://github.com/inpla/inpla) made by Shinya Sato.
- **License Note**: The core architecture and design are Copyright (c) 2022 Shinya Sato Released under the MIT license. This derivative work retains the original license terms (see `LICENSE-THIRD-PARTY`).
