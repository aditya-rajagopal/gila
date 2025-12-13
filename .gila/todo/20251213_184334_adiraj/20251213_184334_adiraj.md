---
title: Flesh out test runner and maybe move to stdx
status: todo
priority: medium
priority_value: 50
owner: adiraj
created: 2025-12-13T18:43:34Z
---

The custom test runner is currently a very barebones implementation. It should be able to run all the tests
similar to the default test runner but we can define globals and such that exist in the `@import("root")` struct.

Maybe this needs to live in the stdx library as a template? I am not sure how to achieve this.

Maybe i can write the test runner main in stdx and you can write your own test runner and just set

```zig
const stdx = @import("stdx");

pub var some_global_used_by_things: u64 = 0;

pub fn main = stdx.test_runner;
```

