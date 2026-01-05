---
title: When executing done, if there is a waiting_on list we need to check the tasks in it before deciding to transition to done
status: todo
priority_value: 50
priority: medium
owner: adiraj
created: 2025-12-22T21:39:00Z
---
When a done command is executed currently we have a todo for dealing with tasks that have a waiting_on list. If the folder status is waiting on or if it is in any other status with a waiting_on list double check that either those tasks dont exist(in which case we remove them from the list) or they exist and are marked as done/cancelled. If that is the case we remove it form the waiting_on list. 

If at the end of this process the list is empty we can safely mark it as done. If not we will write it back into the file with the updated waiting_on list and transition it to waiting if it was in some other state.
