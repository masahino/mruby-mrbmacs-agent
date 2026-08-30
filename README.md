# mruby-mrbmacs-agent

Minimal foundation for exposing mrbmacs editor capabilities to AI agents.

This gem is responsible for mrbmacs-side tool definitions and tool execution.
AI chat UI, conversation management, and OpenAI Responses API transport remain
the responsibility of `mruby-mrbmacs-aichat`.

The initial version provides `search_project`, `find_files`, `find_file`,
`read_file`, and `read_file_range`. It does not provide an agent loop, API
communication, file editing, shell execution, or LSP/DAP integration.

## Tool interface

Available tool definitions are returned by `Application#agent_tools`. Execute
the project search tool with a literal query:

```ruby
results = app.agent_call_tool(
  'search_project',
  { 'query' => 'target_word' }
)
```

The tool always searches `app.project.root_directory`; callers cannot supply a
different directory. Results contain the project-relative file path, one-based
line number, and matching line text, so the returned path can be passed directly
to `find_file`. The existing
`Mrbmacs.search_project_core` implementation performs the search.

Agent search responses return at most 50 matches and approximately 32 KiB of
result data. Individual matching lines are limited to 500 characters. The
structured response includes `total_matches`, `returned_matches`, and
`truncated` so callers can narrow broad searches. These limits apply only to the
agent tool; the base search core and interactive `M-x search-project` command are
unchanged.

Open a file by passing a path relative to the current project root:

```ruby
result = app.agent_call_tool(
  'find_file',
  { 'path' => 'mrblib/example.rb' }
)
```

`find_file` accepts existing regular files only. Absolute paths, directories,
paths outside the project root, and symlinks that resolve outside the project
root are rejected. The tool opens the validated file through mrbmacs's existing
`find_file` command in another pane, then restores focus to the pane where the
tool request started.

Read a project text file without opening it in the editor:

```ruby
result = app.agent_call_tool('read_file', { 'path' => 'mrblib/agent.rb' })
```

`read_file` accepts files up to 64 KiB. Larger files can be read in one-based
ranges of up to 200 lines with `read_file_range`:

```ruby
result = app.agent_call_tool(
  'read_file_range',
  { 'path' => 'mrblib/agent.rb', 'start_line' => 1, 'end_line' => 100 }
)
```

Both read tools reject binary files, directories, paths outside the project,
and symlinks that resolve outside the project. They read from disk and do not
change the current editor buffer.

Find project-relative paths by matching a case-sensitive literal string against
the complete relative path:

```ruby
result = app.agent_call_tool('find_files', { 'query' => 'build_config' })
```

`find_files` skips `.git`, `build`, `tmp`, and `node_modules`, does not follow
symlinks, and returns sorted paths. Responses are limited to 100 paths and
approximately 32 KiB, with `total_files`, `returned_files`, and `truncated`
describing any omitted results.

## Planned use

Future versions may expose additional editor capabilities such as file
reading, current-buffer access, diagnostics, and LSP operations.
Those capabilities will be added incrementally without making this gem depend
on `mruby-mrbmacs-aichat`.
