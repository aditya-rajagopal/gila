# GILA JSON-RPC 2.0 Server Protocol

## Overview

The GILA server implements a JSON-RPC 2.0 interface for external tool integration. It is designed for use with editors like Neovim.

The server reads JSON-RPC requests from stdin and writes responses to stdout. Each request must be on a single line terminated by a newline character.

## Communication

The server uses stdin and stdout for communication:

- **Input**: Line-delimited JSON-RPC requests, one per line
- **Output**: Line-delimited JSON-RPC responses, one per line
- **Encoding**: UTF-8

Batch requests with `echo`:
```bash
echo "($cat commands.txt)" | gila server
```

For single-request mode (useful for scripting):
```bash
echo "single request" | gila server --run-once
```

## Request Format

All requests must be JSON objects with the following structure:

```json
{
  "jsonrpc": "2.0",
  "method": <string>,
  "params": <object>,
  "id": <number|string|null>
}
```

## Response Format

### Success Response

```json
{
  "jsonrpc": "2.0",
  "result": <object>,
  "id": <same as request>
}
```

### Error Response

```json
{
  "jsonrpc": "2.0",
  "error": {
    "code": <number>,
    "message": <string>
  },
  "id": <same as request>
}
```

## Methods

### task/create

Creates a new task and saves it to the filesystem.

**Params:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| title | string | Yes | Task title (non-empty) |
| username | string | Yes | Task owner |
| description | string | No | Task description |
| priority | string | No | Priority level: `low`, `medium`, `high`, `urgent` (default: `medium`) |
| priority_value | number | No | Priority value 0-100 (default: 50) |
| tags | array | No | List of tags |
| waiting_on | array | No | List of task IDs this task is waiting on |
| blocks | array | No | List of task IDs this task blocks |

**Returns:**

| Field | Type | Description |
|-------|------|-------------|
| task_id | string | Generated task ID |
| file_path | string | Path to task markdown file |
| status | string | Task status: `todo` or `waiting`|

**Example Request:**
```json
{"jsonrpc":"2.0","method":"task/create","params":{"title":"Implement login","username":"john","description":"Add user authentication","priority":"high","tags":["backend","security"]},"id":1}
```

**Example Response:**
```json
{"jsonrpc":"2.0","result":{"task_id":"happy_lemur_xyz","file_path":".gila/todo/happy_lemur_xyz/happy_lemur_xyz.md","status":"todo"},"id":1}
```

---

### task/get

Retrieves a task by its ID.

**Params:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| task_id | string | Yes | The task ID to retrieve |

**Returns:** Full task object with all fields.

| Field | Type | Description |
|-------|------|-------------|
| id | string | Task ID |
| title | string | Task title |
| status | string | Task status |
| priority | string | Priority level |
| priority_value | number | Priority value 0-255 |
| owner | string | Task owner |
| created | string | ISO 8601 timestamp |
| completed | string or null | ISO 8601 timestamp if completed |
| tags | array<string> or null | List of tags |
| waiting_on | array<string> or null | List of task IDs this task is waiting on |
| description | string | Task description |
| file_path | string | Path to task markdown file |

**Example Request:**
```json
{"jsonrpc":"2.0","method":"task/get","params":{"task_id":"happy_lemur_xyz"},"id":2}
```

**Example Response:**
```json
{"jsonrpc":"2.0","result":{"id":"happy_lemur_xyz","title":"Implement login","status":"todo","priority":"high","priority_value":75,"owner":"john","created":"2025-01-08T10:30:00Z","completed":null,"tags":["backend","security"],"waiting_on":[],"description":"Add user authentication","file_path":".gila/todo/happy_lemur_xyz/happy_lemur_xyz.md"},"id":2}
```

---

### task/update

Updates a task's fields or status.

**Params:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| task_id | string | Yes | The task ID to update |
| status | string | No | New status: `todo`, `started`, `done`, `cancelled`, `waiting` |
| title | string | No | New task title |
| description | string | No | New task description |
| priority | string | No | New priority level |
| priority_value | number | No | New priority value 0-100 |
| tags | array | No | New list of tags (replaces existing) |

**Returns:**

| Field | Type | Description |
|-------|------|-------------|
| task_id | string | Task ID |
| status | string | Updated status |
| file_path | string | Path to task markdown file |
| completed | string or null | Completion timestamp if status is done/cancelled |

**Example Request:**
```json
{"jsonrpc":"2.0","method":"task/update","params":{"task_id":"happy_lemur_xyz","status":"started"},"id":3}
```

**Example Response:**
```json
{"jsonrpc":"2.0","result":{"task_id":"happy_lemur_xyz","status":"started","file_path":".gila/started/happy_lemur_xyz/happy_lemur_xyz.md","completed":null},"id":3}
```

---

### task/find

Finds tasks matching specified filters. If no filters are specified, returns all tasks. 

NOTE: The sync command is executed before finding tasks.

**Params:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| priority | string | No | Filter by priority level |
| status | string | No | Filter by status |
| tags | array | No | Filter by tags |
| tags_op | string | No | Tag operator: `and` or `or` (default: `or`) |
| waiting_on | string | No | Filter by dependency |
| waiting_on_op | string | No | Dependency operator: `and` or `or` (default: `or`) |
| limit | number | No | Maximum results (default: all) |
| offset | number | No | Pagination offset (default: 0) |
| fields | array | No | Fields to return (default: `id`, `status`, `title`) |

**Returns:**

| Field | Type | Description |
|-------|------|-------------|
| tasks | array | Array of matching tasks |
| available | number | Total number of matching tasks |
| count | number | Number of tasks returned |
| limit | number | Limit applied |
| offset | number | Offset applied |

**Example Request:**
```json
{"jsonrpc":"2.0","method":"task/find","params":{"status":"todo","tags":["backend"],"limit":10},"id":4}
```

**Example Response:**
```json
{"jsonrpc":"2.0","result":{"tasks":[{"id":"happy_lemur_xyz","status":"todo","title":"Implement login"}],"available":1,"count":1,"limit":10,"offset":0},"id":4}
```

---

### task/sync

Reconcilies task state with the filesystem. This method:

- Moves tasks to correct status folders if they are misplaced
- Transitions `waiting` tasks to `todo` when dependencies are complete
- Removes completed dependencies from `waiting_on` lists

**Params:** None

**Returns:**

| Field | Type | Description |
|-------|------|-------------|
| transitions | array | Array of `{task_id, from, to}` for moved tasks |
| updates | array | Array of `{task_id, change, dependency}` for dependency changes |
| count | number | Total number of changes made |

**Example Request:**
```json
{"jsonrpc":"2.0","method":"task/sync","params":{},"id":5}
```

**Example Response:**
```json
{"jsonrpc":"2.0","result":{"transitions":[{"task_id":"old_task_abc","from":"todo","to":"started"}],"updates":[{"task_id":"waiting_task_xyz","change":"removed_completed_dependency","dependency":"done_dep_123"}],"count":2},"id":5}
```

---

### shutdown

Stops the server gracefully.

**Params:** None

**Returns:**

| Field | Type | Description |
|-------|------|-------------|
| message | string | Confirmation message |

**Example Request:**
```json
{"jsonrpc":"2.0","method":"shutdown","id":6}
```

**Example Response:**
```json
{"jsonrpc":"2.0","result":{"message":"Server shutting down"},"id":6}
```

## Error Codes

| Code | Name | Description |
|------|------|-------------|
| -32700 | Parse error | Invalid JSON in request |
| -32600 | Invalid request | Malformed request structure |
| -32601 | Method not found | Unknown method name |
| -32602 | Invalid params | Invalid method parameters |
| -32603 | Internal error | Server internal error |
| -32001 | Task not found | Referenced task does not exist |
| -32002 | Invalid task ID | Task ID format is invalid |
| -32003 | Validation failed | Task validation failed |
| -32004 | Transition error | Status transition failed |
| -32005 | GILA directory not found | No `.gila` directory found |

## Complete Example Session

```bash
# Start server and send multiple requests
$ gila server
# Request 1: Create a task
{"jsonrpc":"2.0","method":"task/create","params":{"title":"Write documentation","username":"alice"},"id":1}
# Response 1
{"jsonrpc":"2.0","result":{"task_id":"cool_beaver_abc","file_path":".gila/todo/cool_beaver_abc/cool_beaver_abc.md","status":"todo"},"id":1}

# Request 2: Start the task
{"jsonrpc":"2.0","method":"task/update","params":{"task_id":"cool_beaver_abc","status":"started"},"id":2}
# Response 2
{"jsonrpc":"2.0","result":{"task_id":"cool_beaver_abc","status":"started","file_path":".gila/started/cool_beaver_abc/cool_beaver_abc.md","completed":null},"id":2}

# Request 3: Find all started tasks
{"jsonrpc":"2.0","method":"task/find","params":{"status":"started"},"id":3}
# Response 3
{"jsonrpc":"2.0","result":{"tasks":[{"id":"cool_beaver_abc","status":"started","title":"Write documentation"}],"available":1,"count":1,"limit":18446744073709551615,"offset":0},"id":3}

# Request 4: Shutdown
{"jsonrpc":"2.0","method":"shutdown","id":4}
# Response 4
{"jsonrpc":"2.0","result":{"message":"Server shutting down"},"id":4}
```
