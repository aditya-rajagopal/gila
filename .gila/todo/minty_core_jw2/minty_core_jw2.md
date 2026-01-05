---
title: Event handing needs a loop in case you get multiple events
status: todo
priority_value: 50
priority: medium
owner: adiraj
created: 2026-01-05T03:17:33Z
tags: 
- tui
---

When you flick the scroll wheel really fast you might get multiple scroll events in a single poll.
This is currently not handled.
