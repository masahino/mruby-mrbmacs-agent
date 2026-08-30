# mruby-mrbmacs-agent

Minimal foundation for exposing mrbmacs editor capabilities to AI agents.

This gem is responsible for mrbmacs-side tool definitions and tool execution.
AI chat UI, conversation management, and OpenAI Responses API transport remain
the responsibility of `mruby-mrbmacs-aichat`.

The initial version provides `search_project` and `find_file`. It does not
provide an agent loop, API communication, file editing, shell execution, or
LSP/DAP integration.

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

## Planned use

Future versions may expose additional editor capabilities such as file
reading, current-buffer access, diagnostics, and LSP operations.
Those capabilities will be added incrementally without making this gem depend
on `mruby-mrbmacs-aichat`.
