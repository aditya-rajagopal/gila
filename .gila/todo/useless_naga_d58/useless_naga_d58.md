---
title: Decide if resize events need to be handled with callbacks or polling
status: todo
priority_value: 50
priority: medium
owner: adiraj
created: 2026-01-05T04:36:42Z
tags: 
- tui
---

I dont know for sure if resizes are better handled with a callback for SIGWINCH or with polling the terminal size
every loop of the application.
