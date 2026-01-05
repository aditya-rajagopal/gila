---
title: Make key events in the TUI have a field that tells the physical button pressed
status: todo
priority_value: 50
priority: medium
owner: adiraj
created: 2026-01-05T03:13:25Z
tags: 
- tui
---

When a key event is recieved we can recieve `a` or `A`. We need the codepoint to be the actual key pressed.
We should in addition have a field that indicates the physical button pressed which in this case would be `A` for both cases.

Update: 
Added a physical_key field to the KeyEvent struct. It needs to be updated to be a seperate enum from the code field.
Use a similar key map to what is in fracture so we can map the physical key. 
