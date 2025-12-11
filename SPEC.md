# GILA

> VERSION: 0.0.1
> STATUS: DRAFT
> DATE: 2025-12-05

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
* **Status**: A state a **Task** can be in. Can be one of `TODO`, `DONE`, `IN_PROGRESS`, `CANCELLED`, or `WAITING`.
* **Description**: A structured description of a **Task**.
* **Tags**: A list of words that can be used to categorize **Tasks**.
* **Priority**: The priority of the task. Can be one of `LOW`, `MEDIUM`, `HIGH`, or `URGENT`. Can also have an optional integer value.
* **Created Date**: The date when the task artifact was created.
* **Completed Date**: The date when the task was completed.
* **Comments**: A list of comments for the task that track progress and other information.
* **Owner**: The person who owns the task.

## File Tree

All artifacts must be stored in a directory called `.gila`. Each folder with this name represents tasks for a single project.

The children of this directory **may** contain a folder for each **Status** that the task can be in. It is recommended 
to create a **Status** folder only if a task exists in that status currently or has been in that status in the past.

Each **Status** folder contains one folder for each **Task** that is in that status. The folders must have the following name format:

`task_TASKID`

See [TASKID](#taskid) for more information on the format. 

Each **Task** folder **must** contain the following files:

* `description.md`: A markdown file containing the description of the **Task**. See [Task Description](#task-description) for more information.
* `comments.md`: A markdown file containing the comments for the **Task**.

NOTE: When there is a descrepancy between the contents of `description.md` and the [TASKID](#taskid) the contents of `description.md` must be used.
And tools should warn users and move the contents of the **Task** folder to the correct location. e.g. if it is in the TODO folder but
the status in `description.md` was changed to DONE externally the task should be moved to DONE the next time the tool is run.

**All** files and folders other than the ones speficially mentioned above are considered supplemental to the project, status, or task 
depending on where they are located. It is recommended to put all files and folders related to a specific **Task** in the directory with its unique identifier.
The entire `.gila` directory is intended to be committed to a remote repository.

### Example

```
.gila
├── todo
│   ├── task_20251205_120000_adiraj
│   │   ├── description.md
│   │   └── comments.md
│   │   └── supplemental_file1
│   └── task_20251205_120001_adiraj
│       ├── description.md
│       └── comments.md
└── done
    ├── task_20251205_120002_adiraj
    │   ├── description.md
    │   └── comments.md
    │   └── supplemental_file1
    │   └── supplemental_file2
    └── task_20251205_120003_adiraj
        ├── description.md
        └── comments.md
```

### Task

### TASKID

Each task is to be created with a unique identifier. The identifier has the following format:

`YYYYMMDD_HHMMSS_name`

Where:

* `YYYYMMDD` is the year, month, and day of the task's **Created Date**
* `HHMMSS` is the hour, minute, and second of the task's **Created Date**
* `name` is the name of the username of the task's creator

Example:

`20251205_120000_adiraj`

### Referencing Tasks

Anywhere a task is to be referenced it should be in one of the following formats:
* `[[task_TASKID]]`: This is the preferred format for referencing a task in a markdown file.
* `GILA(TASKID)`: This is the preferred format for referencing a task in a comment within code.

### Task Description

Each **Task** Folder contains a file called `description.md`. The file **must** have the following header:

```
# <Task Name>

------
status: <TODO|DONE|IN_PROGRESS|CANCELLED|WAITING>
priority: <LOW|MEDIUM|HIGH|URGENT>, <optional integer value>
owner: <Owner>
created: YYYY-MM-DD HH:MM:SS.fff
completed: YYYY-MM-DD HH:MM:fff (only if status is DONE or CANCELLED)
waiting_on: <TaskRef1>, <TaskRef2>, ... (only if status is WAITING)
<optional fields>
tags: <Tag1>, <Tag2>, ...
</optional fields>
------

# Description
```

There are fields that **must** be present in the **Description** that are situationally:

* `waiting_on`: only present if the task is in the `WAITING` status. This contains a list of **Task**s that need to be completed before this task can be completed. 
* `completed`: only present if the task is in the `DONE` or `CANCELLED` status. 

There are optional fileds that need not be present at all to be a valid **Description**:

* `tags`: A list of tags that are comma seperated that can be used to categorize tasks.

### Comments

Each **Task** folder **must** contain a file called `comments.md`. The file **must** have the following header:

```
# Comments

======
header: YYYY-MM-DD HH:MM:SS.fff <User>
<Comment>
------

======
header: YYYY-MM-DD HH:MM:SS.fff <User>
<Comment>
------
...
```

The `YYYY-MM-DD HH:MM:SS.fff` is the date and time when the comment was made. The `<User>` is the name of the user who made the comment.

