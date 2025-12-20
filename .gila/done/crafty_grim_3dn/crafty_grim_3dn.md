---
title: Make parser more robust, it will delete unknown properties
status: done
priority_value: 50
priority: medium
owner: adiraj
created: 2025-12-15T15:24:08Z
completed: 2025-12-20T19:50:09Z
---

This is probably going to be implemented by changing the parsing of task.zig to instead loop through properties
in the file and checking against the fields of the Task struct and putting the rest of the lines in a buffer of lines
and they will be printed out in order after all the gila properties.

