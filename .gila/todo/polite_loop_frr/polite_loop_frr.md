---
title: Concurancy when doing find and sync
status: todo
priority_value: 50
priority: medium
owner: adiraj
created: 2026-01-10T18:57:43Z
tags: 
- perf
---

Currently from probing Most of the time is spent in waiting for the system to open a file for us.
```
INFO(sync): Total time in parseFolder 297.834us
INFO(sync): Total time in opening file: count 55 total 197.62us
```

We can do a single pass over the tasks and figure out which ones are in the wrong state and only process those.
This can be done concurrently. The current architecture does not lend itself to coconcurrency as we need to process
folders in order. We can still do that but if we know beforehand which tasks need syncing we dont need to process each file
in order.

Eg. we can load, status, does_it have waiting_on, does it have completed, etc. As jobs that can suspend
when waiting for io from the system.
