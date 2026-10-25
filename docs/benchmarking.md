# Profiling and benchmarking

**Bancai** allows you to collect execution stats if compiled with specific build flags.

## Execution time and interaction count

`-Dbenchmark` to get execution time and interactions count per active pair statement.

```shell
$ zig build run -Doptimize=ReleaseFast -Dbenchmark -- -f ./benchmarks/merge_sort.in -m 40000000

analyzed data for (MakeRandomList ~ #number) begin
1 interaction in 0.036405s
end.
analyzed data for (Cons ~ msort) begin
36042471 interactions in 9.379277s
end.
analyzed data for (checkSorted ~ Cons) begin
2400000 interactions in 0.360727s
end.
True()
```

## Memory consumption

`-Dprint-memory-usage` allows you to collect information on agent and name heap usage, specifically, the free and used count after interaction, and peak fullness during execution per active pair statement.

When using `-Dheap=basic` along with `-Dbenchmark` and the aforementioned flag, you also get information on the exact agent heap structure. Use `--profiling-window` CLI flag to also collect periodic snapshot during the active pair statement execution.

```

$ zig build run -Doptimize=ReleaseFast -Dbenchmark -Dprint-memory-usage -Dheap=basic -- -f ./benchmarks/merge_sort.in -m 40000000 --profiling-window 10000000
analyzed data for (MakeRandomList ~ #number) begin
1 interaction in 0.033423s
Profiling data after 1 interaction
#0013 -                                  #number    800000
#0018 -                                     Cons    800000
#0019 -                                      Nil         1

Heap(Agent): used = 1600001, free = 38399999, peak = 1600003
Heap(Name): used = 1, free = 39999999, peak = 1
end.
analyzed data for (Cons ~ msort) begin
36042117 interactions in 10.91963s
Profiling data after 10000000 interactions
#0013 -                                  #number    800000
#0018 -                                     Cons    342434
#0019 -                                      Nil         1
#0021 -                                    msort         5
#0022 -                                  ms_tail    457566
#0023 -                                    split    457570
#0024 -                                    merge    457570

Profiling data after 20000000 interactions
#0013 -                                  #number    800000
#0018 -                                     Cons    551418
#0019 -                                      Nil    800000
#0022 -                                  ms_tail         2
#0024 -                                    merge    551419
#0025 -                                  mergeCC    248580

Profiling data after 30000000 interactions
#0013 -                                  #number    800000
#0018 -                                     Cons    799489
#0019 -                                      Nil       512
#0025 -                                  mergeCC       511

Profiling data after 36042117 interactions
#0013 -                                  #number    800000
#0018 -                                     Cons    800000
#0019 -                                      Nil         1

Heap(Agent): used = 1600001, free = 38399999, peak = 3200006
Heap(Name): used = 800000, free = 39200000, peak = 3199928
end.
...
```

## Exporting to csv

By default, data is printed to `stderr` using Zig's `std.debug.print`. You can also collect data in table format using bancai's `--export-csv-dir` flag. The data is organazied into subdirectories within the specified directory, with names corresponding to the profiled active pair statements.

```
$ zig build run -Doptimize=ReleaseFast -Dbenchmark -Dprint-memory-usage -Dheap=basic -- -f ./benchmarks/merge_sort.in -m 40000000 --profiling-window 10000000 --export-csv-dir=./example-bench &> /dev/null
$ tree example-bench
example-bench
├── 0MakeRandomList~#number
│   ├── agent_structure.csv
│   └── bench.csv
├── 1Cons~msort
│   ├── agent_structure.csv
│   └── bench.csv
└── 2checkSorted~Cons
    ├── agent_structure.csv
    └── bench.csv
```
