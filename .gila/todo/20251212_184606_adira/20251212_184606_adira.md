---
title: Figure out if the allocator for the application can live on the stack always
status: todo
priority: medium
priority_value: 50
owner: adira
created: 2025-12-12T18:46:06Z
---

Currently the allocator for the application is an arena backed by a stack buffer.
This is probably an issue if files that are being loaded are going to be too large.

When the time comes and files get large this might need to be a single heap allocation at the start of the application.
