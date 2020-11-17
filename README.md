# hello

Multi-threaded cross-platform HTTP/1.1 web server example in [Zig](https://ziglang.org) using [lithdew/pike](https://github.com/lithdew/pike) and [kprotty/zap](htps://github.com/kprotty/zap).

## Setup

This example requires a nightly version of Zig. Make sure that port 9000 is available.

```
git clone --recurse-modules https://github.com/lithdew/hello
cd hello && zig run http.zig
```

## Benchmarks

```
$ cat /proc/cpuinfo | grep 'model name' | uniq
model name : Intel(R) Core(TM) i7-7700HQ CPU @ 2.80GHz

$ wrk -t12 -c100 -d30s http://127.0.0.1:9000
Running 30s test @ http://127.0.0.1:9000
  12 threads and 100 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   417.19us    0.90ms  30.21ms   96.78%
    Req/Sec    26.86k     3.31k   39.72k    73.08%
  9629837 requests in 30.04s, 459.19MB read
Requests/sec: 320538.80
Transfer/sec:     15.28MB
```