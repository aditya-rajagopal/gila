# GILA

> VERSION: 0.1.0
> STATUS: DRAFT
> DATE: 2025-12-16

## Abstract

This document describes the GILA specification for a local plain-text task tracking system for developers. It is designed to be 
simple to implement to allow anyone to create tools to read and manage these files in any development environement.
A feature of GILA is that the artifacts are meant to be local and human readable and commitable to remote repositories.

## Introduction

### Motivation

Very often while during development I tend to create tasks within comments for me to come back to later. Often this is disorganized
and it is hard to add more information to them when more information comes along. I often have `TODO` comments littered throughout
my codebase and I dont like it. I also dislike tools like JIRA and Github issues for creating tasks as I usually just want
some place to add information like images, debug logs, and thoughts for me to reference later. Lastly I value being able to 
locally view all my tasks and check them in when I sync my repositories across multiple machines. The aim is to create a 
portable and lightweight specification for creating and managing tasks.

### Scope

GILA is a specification and not a specific tool.

GILA is designed to be
* Local plain-text: All the artifacts are meant to be local and human readable and commitable to remote repositories.
* Simple and portable. Anyone should be able to create tools to read and manage these files in any development environement
* Flexible: Should be extendable in the future when new needs pop up
* Extensible: Should be able to add new features in the future by anyone for specific needs

GILA is ***NOT*** designed to be
* Generic: It is not meant to be a generic task tracking system without extensions designed for specific needs

The specification gives definitions of the format for the file tree, naming conventions, and the structure of the files.
Additionally there may be suggestions for task generation and parsing tools. Rationale for these will be provided when possible, 
though it is not required.

## Terminology

* **Task**: A single artifact identified by a **TASKID**.
* **TASKID**: A unique identifier for a **Task**. See [TASKID](#taskid) for more information.
* **Status**: A state a **Task** can be in. Can be one of `todo`, `done`, `in_progress`, `cancelled`, or `waiting`.
* **Description**: A structured description of a **Task**.
* **Tags**: A list of words that can be used to categorize **Tasks**.
* **Priority**: The priority of the task. Can be one of `low`, `medium`, `high`, or `urgent`. Can also have an optional integer value.
* **Created Date**: The date when the task artifact was created.
* **Completed Date**: The date when the task was completed.
* **Comments**: A list of comments for the task that track progress and other information.
* **Owner**: The person who owns the task.

## File Tree

All artifacts must be stored in a directory called `.gila`. Each folder with this name represents tasks for a single project.

The children of this directory **may** contain a folder for each **Status** that the task can be in. It is recommended 
to create a **Status** folder only if a task exists in that status currently or has been in that status in the past.

Each **Status** folder contains one folder for each **Task** that is in that status. The name of the folder must be the **TaskID** of the task.
See [TASKID](#taskid) for more information on the format. 

Each **Task** folder **must** contain the following files:

* `(TASKID).md`: A markdown file containing the description of the **Task** with the same task_id as the folder name.

NOTE: When there is a descrepancy between the contents of `*.md` and the [TASKID](#taskid) and its location the contents of `*.md` must be used.
And tools should warn users and move the contents of the **Task** folder to the correct location. e.g. if it is in the `todo` folder but
the status in `(TASKID).md` was changed to DONE externally the task should be moved to DONE the next time the tool is run.

**All** files and folders other than the ones speficially mentioned above are considered supplemental to the project, status, or task 
depending on where they are located. It is recommended to put all files and folders related to a specific **Task** in the directory with its unique identifier.
The entire `.gila` directory is intended to be committed to a remote repository.

### Example

```
.gila
├── todo
│   ├── blaring_magma_6kr
│   │   ├── blaring_magma_6kr.md
│   │   └── supplemental_file1
└── done
    ├── ashamed_thorn_0ka
    │   ├── ashamed_thorn_0ka.md
    │   ├── supplemental_file1
    │   └── supplemental_file2
    └── lucky_nimbus_bqc
        └── lucky_nimbus_bqc.md
```

### Task

### TASKID

Each task is to be created with a unique identifier. The identifier has the following format:

`word_word_ccc`

Where:

* `word` is any word in the language of the user
* `ccc` is a 3 digit base32 number

The choice of words must be large enough so that random id generation has enough entropy to avoid collisions.
Look into the birthday paradox for more information.

A random 3 digit base32 number represents `2^15` unique ids. If you have a dictionary of `2^9` words you can generate
`2^9 * 2^9 * 2^15 = 2^33` unique ids which is large enough for most projects. If you require more collision resistance you can use
a larger dictionary.

For tools it is recommended to use atleast a total of `2^32` unique ids to avoid collisions.
Also it is recommended to have(depending on the language) the use of a different dictionary of word for the first and second word.
With one being an adjective and the other being a noun. This will help the id be more memorable and readable.

Example:

`blaring_magma_6kr`

### Task ID

The **Task ID** is the unique identifier for a **Task**. It has the following format:


### Referencing Tasks

Anywhere a task is to be referenced it should be in one of the following formats:
* `[[TASKID]]`: This is the preferred format for referencing a task in the **Description** file.
* `GILA(TASKID)`: This is the preferred format for referencing a task in a comment within code.

### Task Description

Each **Task** Folder contains a file called `(TASKID).md`. The file **must** have the following header:

```
---
status: <todo|done|in_progress|cancelled|waiting>
priority: <low|medium|high|urgent>
priority_value: 0-255
owner: <Owner>
created: YYYY-MM-DDTHH:MM:SSZ
completed: YYYY-MM-DDTHH:MM:SSZ (only if status is DONE or CANCELLED)
waiting_on:
- "[[TaskID]]"
- "[[TaskID]]"
- ... (only if status is WAITING)
<optional fields>
tags:
- <Tag1>
- <Tag2>
- ...
</optional fields>
---

# <Task Name>

```

NOTE: All times are in UTC and are formatted as `YYYY-MM-DDTHH:MM:SSZ`.

There are fields that **must** be present in the **Description** that are situationally:

* `waiting_on`: only present if the task is in the `waiting` status. This contains a list of **Task**s that need to be completed before this task can be completed. 
* `completed`: only present if the task is in the `done` or `cancelled` status. 

There are optional fileds that need not be present at all to be a valid **Description**:

* `tags`: A list of tags with one tag per line that must start with a `-`. The tags can be used to categorize tasks.

