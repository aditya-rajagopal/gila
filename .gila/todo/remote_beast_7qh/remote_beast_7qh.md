---
title: Allow providing arguments multiple times?
status: todo
priority: low
priority_value: 50
owner: adiraj
created: 2025-12-19T17:17:56Z
---

It is possible that the `parseFlagValue()` custom function could possibly take Self as a pointer argument 
instead of returning a new Self. This will allow multiple argument calls to be made to the function for it to 
deal with how it likes. 

The usecase for me is the following:

```sh
gila todo --tag=tag1 --waiting_on=task_1 --tag=tag2 --waiting_on=task_2 ...
```

Sometimes this is a bit more readable than:

```sh
gila todo --tag=tag1,tag2 --waiting_on=task_1,task_2 ...
```

I'm not sure if this is a good idea or not, but it's something to think about.
