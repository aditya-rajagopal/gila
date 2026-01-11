# Version 0.2.0
- (2026-01-11) Bug fix: Fixed a bug where `--edit` flag was not working. Io requires an allocator to be passed when initializing `std.Io.Threaded`
- (2026-01-11) [ready_tail_tzs](./.gila/done/ready_tail_tzs/ready_tail_tzs.md) Added `--owner` flag to the `todo` command to set the owner of a task
- (2026-01-11) [ready_tail_tzs](./.gila/done/ready_tail_tzs/ready_tail_tzs.md) Added `gila todo --edit` to open the task description file in the editor after creating the task
- (2026-01-09) Updated [SPEC.md](SPEC.md)
- (2026-01-08) Fixed a bug in task parsing where `-` in tags were causing issues.
- (2026-01-08) Added `server` command to start a JSON-RPC 2.0 server for programmatic access
- (2026-01-08) Added tests to all commands
