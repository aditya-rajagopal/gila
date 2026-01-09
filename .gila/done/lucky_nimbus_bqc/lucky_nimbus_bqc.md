---
title: Refactor common FS operations
status: done
priority_value: 50
priority: low
owner: adiraj
created: 2025-12-12T17:08:20Z
completed: 2026-01-09T06:19:25Z
tags: 
- cleanup
---

Move all common FS operations such as finding the .gila directory, creating and moving tasks to a separate module.

This may also allow some fuzz testing if I can find a way to mock the FS.
