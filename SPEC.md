# GILA

> Version: 0.3.0
> Status: Draft
> Date: 2026-01-09

## 1. Abstract

This document defines GILA, a plain-text task tracking system designed for software developers. 
GILA stores tasks as human-readable markdown files with YAML frontmatter in a `.gila` directory structure. 
The format is designed to be version-control friendly, portable across development environments, and simple enough for any tool to implement.

GILA is designed to be
* Local plain-text: All the artifacts are meant to be local and human readable and commitable to remote repositories.
* Simple and portable. Anyone should be able to create tools to read and manage these files in any development environement
* Flexible: Should be extendable in the future when new needs pop up
* Extensible: Should be able to add new features in the future by anyone for specific needs

GILA is ***NOT*** designed to be
* Generic: It is not meant to be a generic task tracking system without extensions designed for specific needs

## 2. Terminology

### 2.1. Terminology

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "MAY", and "OPTIONAL" 
in this document are to be interpreted as described in [RFC 2119](https://www.ietf.org/rfc/rfc2119.txt).

### 2.2. Domain Terms

**Task**: A single trackable unit of work identified by a unique TASKID.
**TASKID**: A unique identifier for a Task following the format defined in Section 5.
**Status**: The current state of a Task. One of: `todo`, `started`, `done`, `cancelled`, or `waiting`.
**Priority**: The urgency level of a Task. One of: `low`, `medium`, `high`, or `urgent`.
**Frontmatter**: The YAML metadata block at the beginning of a task file, delimited by `---` lines.
**Description**: The freeform markdown content following the frontmatter.

## 3. File System Structure

### 3.1. Root Directory

All GILA artifacts MUST be stored in a directory named `.gila` at the project root. Each `.gila` directory represents tasks for a single project.

The `.gila` directory is intended to be committed to version control alongside project source code.

### 3.2. Status Directories

The `.gila` directory MUST contain subdirectories for each status value IF there is a task with that status:
Implementations MUST NOT require all status directories to be present if there are no tasks in that status.

### 3.3. Task Directories

Each task is stored in its own directory within the appropriate status directory. The directory name MUST be the TASKID of the task:

```
.gila/{status}/{taskid}/
```

Each task directory MUST contain exactly one task file named `{taskid}.md`.

Example:
```
.gila/todo/blaring_magma_6kr/blaring_magma_6kr.md
```

### 3.4. Source of Truth

When the status indicated by a task's directory location differs from the `status` field in the task file, the task file MUST be treated as authoritative.

Implementations SHOULD:
1. Log a warning when this discrepancy is detected
2. Move the task directory to match the file's status during synchronization

### 3.5. Supplemental Files

Any files or directories within the GILA proejct other than those required by the SPEC considered supplemental materials. These MAY include:

- Screenshots or images
- Log files
- Related documentation
- Any other files relevant to the task

Implementations MUST NOT read or write to these supplemental files. When tasks are transitioned to a new status,
implmentations MUST preserve the supplemental files relative to its original task.

## 4. Task Identifier (TASKID)

### 4.1. Format

A TASKID MUST follow this format:

```
{word}_{word}_{base32}
```

Where:
- `{word}` is an alphabetic string (a-z, case-insensitive)
- `{base32}` is exactly 3 characters from the base32 alphabet
- The base32 alphabet MUST be: `0123456789abcdefghjkmnpqrstvwxyz`. This alphabet excludes the characters `i`, `l`, `o`, and `u` to avoid visual ambiguity.

The recommended structure uses an adjective for the first word and a noun for the second word to improve memorability.

Example: `blaring_magma_6kr`

### 4.2. Generation Requirements

Implementations generating TASKIDs SHOULD provide sufficient entropy to minimize collision probability. The RECOMMENDED minimum is 2^32 possible unique identifiers.
This heavily depends on the usecase and the desired level of security.

To achieve this minimum entropy with the recommended format:
- First word pool: at least 1024 unique words (10 bits)
- Second word pool: at least 128 unique words (7 bits)
- Base32 suffix: 3 characters providing 15 bits

Total: 10 + 7 + 15 = 32 bits of entropy.

### 4.3. Validation Rules

A valid TASKID MUST satisfy all of the following:

1. Contain exactly two underscore characters
2. The final underscore MUST be at position `length - 4` (i.e., exactly 3 characters follow it)
3. The final 3 characters MUST be from the base32 alphabet
4. All characters before the final 3 MUST be alphabetic (a-z) or underscore

### 4.4. Referencing Tasks

When referencing a task within markdown content (such as the description field), use:

```
[[taskid]]
```

When referencing a task within source code comments, use:

```
GILA(taskid)
```

The `waiting_on` field uses a quoted variant of the markdown format:

```
"[[taskid]]"
```

## 5. Task File Format

### 5.1. File Naming

The task file MUST be named `{taskid}.md` where `{taskid}` is the task's identifier.

### 5.2. Frontmatter Structure

A task file MUST begin with YAML frontmatter enclosed by `---` delimiters:

```
---
{field}: {value}
...
---
{description}
```

Fields MUST appear one per line in the format `{field}: {value}`.

List fields use YAML list syntax:
```
{field}:
- {item1}
- {item2}
```

### 5.3. Required Fields

The following fields MUST be present in every task file:

| Field | Type | Description |
|-------|------|-------------|
| `status` | enum | Current task state |
| `title` | string | Human-readable task title |
| `priority` | enum | Task priority level |
| `priority_value` | integer | Numeric priority (0-255) |
| `owner` | string | Task owner identifier |
| `created` | datetime | Creation timestamp |

### 5.4. Conditional Fields

These fields are required or prohibited based on task status:

| Field | Type | Condition |
|-------|------|-----------|
| `completed` | datetime | REQUIRED if status is `done` or `cancelled`; MUST NOT be present otherwise |
| `waiting_on` | list | REQUIRED if status is `waiting` |

### 5.5. Optional Fields

| Field | Type | Description |
|-------|------|-------------|
| `tags` | list | Categorization tags |

When the `tags` field is present, it MUST contain at least one tag.

### 5.6. Extension Fields

Implementations MUST preserve any fields not defined in this specification. Unknown fields MUST be written back to the file unchanged when the task is modified.

This mechanism allows tools to add custom metadata without breaking compatibility with other implementations.

### 5.7. Description Body

All content after the closing `---` delimiter is the task description. This content:

- MAY be empty
- MAY contain arbitrary markdown
- Has no required structure
- SHOULD NOT be parsed or validated by implementations

## 6. Field Specifications

### 6.1. title

**Type**: String

**Validation**:
- MUST NOT be empty
- MUST NOT contain carriage return (`\r`) or line feed (`\n`) characters

### 6.2. status

**Type**: Enumeration

**Values**:
- `todo` - Task has not been started
- `started` - Task is actively being worked on
- `done` - Task has been completed successfully
- `cancelled` - Task has been abandoned without completion
- `waiting` - Task is blocked pending completion of other tasks

**Validation**: Value MUST be one of the defined values (case-sensitive).

### 6.3. priority

**Type**: Enumeration

**Values**:
- `low`
- `medium`
- `high`
- `urgent`

**Validation**: Value MUST be one of the defined values (case-sensitive).

### 6.4. priority_value

**Type**: Unsigned 8-bit integer

**Range**: 0-255

**Description**: Provides fine-grained priority ordering within a priority level. Higher values indicate higher priority.

**Validation**: Value MUST be in the range 0-255.

### 6.5. owner

**Type**: String

**Validation**: MUST NOT be empty. MUST NOT contain carriage return (`\r`) or line feed (`\n`) characters.

It is RECOMMENDED to use a consistent identifier such as a username or email address.

### 6.6. created

**Type**: Datetime

**Format**: ISO 8601 UTC timestamp: `YYYY-MM-DDTHH:MM:SSZ`

**Example**: `2026-01-09T14:30:00Z`

**Validation**: MUST be a valid UTC timestamp with `Z` suffix.

### 6.7. completed

**Type**: Datetime

**Format**: ISO 8601 UTC timestamp: `YYYY-MM-DDTHH:MM:SSZ`

**Constraints**:
- MUST be present when status is `done` or `cancelled`
- MUST NOT be present when status is `todo`, `started`, or `waiting`

### 6.8. waiting_on

**Type**: List of strings

**Format**: Each item MUST be a quoted TASKID reference: `"[[taskid]]"`

**Example**:
```yaml
waiting_on:
- "[[blaring_magma_6kr]]"
- "[[lucky_nimbus_bqc]]"
```

**Requirements**:
- Each item MUST match the pattern `"[[{taskid}]]"` where `{taskid}` is a valid TASKID else it MUST be removed from the list.
- The list MUST NOT be empty when present
- Referenced tasks SHOULD exist (implementations MAY warn when references cannot be resolved)
- If an operation to remove a reference task causes the list to become empty, the task MUST be transitioned to `todo`

**Constraints**:
- MUST be present when status is `waiting`
- MUST NOT be present when status is `done`, or `cancelled`
- If present in a `todo` or `started` task, an implementation MUST transition the task to `waiting`

Implementations MAY discard tasks from the `waiting_on` list if:
- The referenced task is not found
- The referenced task is `done` or `cancelled`

### 6.9. tags

**Type**: List of strings

**Example**:
```yaml
tags:
- backend
- urgent
- sprint-42
```

**Validation**:
- When present, MUST contain at least one tag
- Individual tags MUST NOT be empty
- Individual tags MUST NOT contain `\r` or `\n` characters

## 7. Validation Rules

### 7.1. Structural Validation

Implementations MUST validate:

1. The file begins with `---` on the first line
2. A second `---` line exists to close the frontmatter
3. All required fields are present
4. Field values match their specified types
5. The TASKID is valid per Section 4.3
6. The `title`, `owner`, `priority`, `priority_value`, `status`, and `created` fields are non-empty
7. Each field values must be valid per specifications in section [6](#6-field-specifications)

### 7.2. Reference Validation

Implementations SHOULD validate that TASKIDs referenced in `waiting_on` correspond to existing tasks. When a referenced task cannot be found:
- Implementations SHOULD log a warning
- Implementations MAY treat this as a non-fatal validation issue
- Implementations MUST NOT silently ignore missing references
- Implementations MAY modify the `waiting_on` list only if the referenced task is `done` or `cancelled` or if the referenced task is not found

### 7.3. Status-Field Constraints

The following constraints MUST be enforced:

| Status | `completed` | `waiting_on` |
|--------|-------------|--------------|
| `todo` | MUST NOT be present | MUST NOT be present. If present must be transitioned to `waiting` |
| `started` | MUST NOT be present | MUST NOT be present. If present must be transitioned to `waiting` |
| `done` | MUST be present | MUST NOT be present |
| `cancelled` | MUST be present | MUST NOT be present |
| `waiting` | MUST NOT be present | MUST be present (non-empty). If empty, must be transitioned to `todo` |

## 8. Status Transitions

The following MUST be enforced if a task's status must:

1. **Transition to `done` or `cancelled`**:
   - If the task has a `waiting_on` if present all referenced tasks MUST be `done` or `cancelled`. The `waiting_on` list MUST be discarded.
   - Set `completed` to the current UTC timestamp if not already set

2. **Transition to `waiting`**:
   - Ensure `waiting_on` contains at least one valid reference
   - MUST NOT be in `done` or `cancelled` status

3. **Transition to `todo` or `started`**:
   - Remove `completed` if present
   - If the task has a `waiting_on` if present all referenced tasks MUST be `done` or `cancelled`. The `waiting_on` list MUST be discarded.

4. **Move task directory** to the new status directory preserving any supplemental files within with no modifications.

## 9. Extensibility

### 9.1. Custom Fields

Implementations MAY add custom fields to the frontmatter. Custom fields:

- MUST NOT conflict with field names defined in this specification
- SHOULD use a namespace prefix to avoid future conflicts (e.g., `x-myapp-field`)
- MUST be preserved by other implementations that do not recognize them

### 9.2. Supplemental Files

Task directories MAY contain any additional files. Common uses include:

- Screenshots demonstrating bugs
- Log files for debugging
- Design documents or mockups
- Related data files

Implementations MUST preserve supplemental files when moving task directories.
