module Mrbmacs
  # Extension entry point for AI agent capabilities.
  class AgentExtension < Extension
    SEARCH_PROJECT_TOOL = {
      'name' => 'search_project',
      'description' => 'Search file contents in the current project for a literal string. ' \
                       'Use find_files instead when only file names or paths are needed.',
      'input_schema' => {
        'type' => 'object',
        'properties' => {
          'query' => { 'type' => 'string' }
        },
        'required' => ['query'],
        'additionalProperties' => false
      }
    }.freeze
    FIND_FILE_TOOL = {
      'name' => 'find_file',
      'description' => 'Open a known project-relative file in another editor pane. ' \
                       'Do not use this tool merely to verify a path returned by find_files.',
      'input_schema' => {
        'type' => 'object',
        'properties' => {
          'path' => { 'type' => 'string' }
        },
        'required' => ['path'],
        'additionalProperties' => false
      }
    }.freeze
    READ_FILE_TOOL = {
      'name' => 'read_file',
      'description' => 'Read a known project-relative text file only when its contents are ' \
                       'required. Do not use this tool to verify names or paths returned by ' \
                       'find_files.',
      'input_schema' => {
        'type' => 'object',
        'properties' => {
          'path' => { 'type' => 'string' }
        },
        'required' => ['path'],
        'additionalProperties' => false
      }
    }.freeze
    READ_FILE_RANGE_TOOL = {
      'name' => 'read_file_range',
      'description' => 'Read a one-based line range only when file contents are required. ' \
                       'Do not use this tool to verify names or paths returned by find_files.',
      'input_schema' => {
        'type' => 'object',
        'properties' => {
          'path' => { 'type' => 'string' },
          'start_line' => { 'type' => 'integer' },
          'end_line' => { 'type' => 'integer' }
        },
        'required' => ['path', 'start_line', 'end_line'],
        'additionalProperties' => false
      }
    }.freeze
    FIND_FILES_TOOL = {
      'name' => 'find_files',
      'description' => 'Find project-relative file paths containing a literal string. Use ' \
                       'this tool for questions about file names or locations. Returned paths ' \
                       'are sufficient when only names or locations are requested; do not read ' \
                       'files merely to confirm them.',
      'input_schema' => {
        'type' => 'object',
        'properties' => {
          'query' => { 'type' => 'string' }
        },
        'required' => ['query'],
        'additionalProperties' => false
      }
    }.freeze
    MAX_READ_BYTES = 64 * 1024
    MAX_READ_LINES = 200
    MAX_SEARCH_RESULTS = 50
    MAX_SEARCH_OUTPUT_BYTES = 32 * 1024
    MAX_SEARCH_TEXT_CHARS = 500
    MAX_FIND_FILES_RESULTS = 100
    MAX_FIND_FILES_OUTPUT_BYTES = 32 * 1024
    FIND_FILES_EXCLUDED_DIRECTORIES = ['.git', 'build', 'tmp', 'node_modules'].freeze

    def self.register_agent(app)
      app.ext.data['agent'] ||= {}
    end
  end

  class Application
    def agent_tools
      tools = [
        AgentExtension::SEARCH_PROJECT_TOOL,
        AgentExtension::FIND_FILE_TOOL,
        AgentExtension::READ_FILE_TOOL,
        AgentExtension::READ_FILE_RANGE_TOOL,
        AgentExtension::FIND_FILES_TOOL
      ]
      Command.metadata.each do |name, metadata|
        api = metadata['api']
        next if api.nil?

        tools << {
          'name' => name.to_s,
          'description' => metadata['description'],
          'input_schema' => api['input_schema']
        }
      end
      tools
    end

    def agent_call_tool(name, arguments)
      case name
      when 'search_project'
        unless arguments.is_a?(Hash) && arguments['query'].is_a?(String) &&
               !arguments['query'].empty?
          raise ArgumentError, 'search_project requires a non-empty query string'
        end
        unless @project && Dir.exist?(@project.root_directory)
          raise ArgumentError, 'Project is not available'
        end

        root = File.realpath(@project.root_directory)
        root_prefix = root.end_with?(File::SEPARATOR) ? root : "#{root}#{File::SEPARATOR}"
        results = Mrbmacs.search_project_core(arguments['query'], root)
        agent_search_project_result(arguments['query'], results, root_prefix)
      when 'find_file'
        agent_find_file(arguments)
      when 'read_file'
        agent_read_file(arguments)
      when 'read_file_range'
        agent_read_file_range(arguments)
      when 'find_files'
        agent_find_files(arguments)
      else
        metadata = Command.metadata[name.to_sym]
        api = metadata.nil? ? nil : metadata['api']
        handler = api.nil? ? nil : api['handler']
        raise ArgumentError, "Unknown agent tool: #{name}" if handler.nil?

        send(handler, arguments)
      end
    end

    private

    def agent_find_files(arguments)
      unless arguments.is_a?(Hash) && arguments['query'].is_a?(String) &&
             !arguments['query'].empty?
        raise ArgumentError, 'find_files requires a non-empty query string'
      end
      unless @project && Dir.exist?(@project.root_directory)
        raise ArgumentError, 'Project is not available'
      end

      query = arguments['query']
      root = File.realpath(@project.root_directory)
      root_prefix = root.end_with?(File::SEPARATOR) ? root : "#{root}#{File::SEPARATOR}"
      directories = [root]
      files = []
      until directories.empty?
        directory = directories.pop
        begin
          Dir.foreach(directory) do |entry|
            next if entry == '.' || entry == '..'

            path = File.join(directory, entry)
            if File.directory?(path)
              next if File.symlink?(path)
              next if AgentExtension::FIND_FILES_EXCLUDED_DIRECTORIES.include?(entry)

              directories << path
              next
            end
            next if File.symlink?(path) || !FileTest.file?(path)

            relative_path = path[root_prefix.length..-1]
            files << relative_path if relative_path.include?(query)
          end
        rescue StandardError
          next
        end
      end
      files.sort!

      returned_files = []
      output_bytes = 0
      files.each do |file|
        break if returned_files.length >= AgentExtension::MAX_FIND_FILES_RESULTS
        break if output_bytes + file.bytesize + 8 > AgentExtension::MAX_FIND_FILES_OUTPUT_BYTES

        returned_files << file
        output_bytes += file.bytesize + 8
      end
      {
        'query' => query,
        'files' => returned_files,
        'total_files' => files.length,
        'returned_files' => returned_files.length,
        'truncated' => returned_files.length < files.length
      }
    end

    def agent_search_project_result(query, results, root_prefix)
      matches = []
      output_bytes = 0
      truncated = false
      results.each do |result|
        if matches.length >= AgentExtension::MAX_SEARCH_RESULTS
          truncated = true
          break
        end

        converted = agent_project_relative_search_result(result, root_prefix)
        text = converted['text'].to_s
        if text.length > AgentExtension::MAX_SEARCH_TEXT_CHARS
          converted['text'] = text[0, AgentExtension::MAX_SEARCH_TEXT_CHARS]
          truncated = true
        end
        result_bytes = converted['file'].to_s.bytesize +
                       converted['line'].to_s.bytesize +
                       converted['text'].to_s.bytesize + 64
        if output_bytes + result_bytes > AgentExtension::MAX_SEARCH_OUTPUT_BYTES
          truncated = true
          break
        end

        matches << converted
        output_bytes += result_bytes
      end
      truncated = true if matches.length < results.length
      {
        'query' => query,
        'matches' => matches,
        'total_matches' => results.length,
        'returned_matches' => matches.length,
        'truncated' => truncated
      }
    end

    def agent_project_relative_search_result(result, root_prefix)
      converted = result.dup
      file = converted['file'].to_s
      if file.start_with?(root_prefix)
        converted['file'] = file[root_prefix.length..-1]
      end
      converted
    end

    def agent_find_file(arguments)
      resolved_path, relative_path = agent_project_file(arguments, 'find_file')

      agent_open_file_in_other_pane(resolved_path)
      { 'path' => relative_path, 'opened' => true }
    end

    def agent_read_file(arguments)
      resolved_path, relative_path = agent_project_file(arguments, 'read_file')
      if File.size(resolved_path) > AgentExtension::MAX_READ_BYTES
        raise ArgumentError, 'read_file exceeds the 65536-byte limit; use read_file_range'
      end

      content = File.read(resolved_path, mode: 'rb')
      raise ArgumentError, 'read_file does not support binary files' if content.include?("\0")

      { 'file' => relative_path, 'content' => content }
    end

    def agent_read_file_range(arguments)
      resolved_path, relative_path = agent_project_file(arguments, 'read_file_range')
      start_line = arguments['start_line']
      end_line = arguments['end_line']
      unless start_line.is_a?(Integer) && end_line.is_a?(Integer)
        raise ArgumentError, 'read_file_range requires integer line numbers'
      end
      if start_line < 1 || end_line < 1 || start_line > end_line
        raise ArgumentError, 'read_file_range requires 1-based start_line <= end_line'
      end
      if end_line - start_line + 1 > AgentExtension::MAX_READ_LINES
        raise ArgumentError, 'read_file_range exceeds the 200-line limit'
      end

      content = ''
      actual_end_line = nil
      File.open(resolved_path, 'rb') do |file|
        line_number = 0
        file.each_line do |line|
          line_number += 1
          next if line_number < start_line
          break if line_number > end_line

          if line.include?("\0")
            raise ArgumentError, 'read_file_range does not support binary files'
          end
          if content.bytesize + line.bytesize > AgentExtension::MAX_READ_BYTES
            raise ArgumentError, 'read_file_range exceeds the 65536-byte limit'
          end
          content << line
          actual_end_line = line_number
        end
      end
      if actual_end_line.nil?
        raise ArgumentError, 'read_file_range start_line is beyond the end of the file'
      end

      {
        'file' => relative_path,
        'start_line' => start_line,
        'end_line' => actual_end_line,
        'content' => content
      }
    end

    def agent_project_file(arguments, tool_name)
      unless arguments.is_a?(Hash) && arguments['path'].is_a?(String) &&
             !arguments['path'].empty?
        raise ArgumentError, "#{tool_name} requires a non-empty relative path"
      end
      unless @project && Dir.exist?(@project.root_directory)
        raise ArgumentError, 'Project is not available'
      end

      input_path = arguments['path']
      if File.absolute_path?(input_path) || input_path.start_with?('~')
        raise ArgumentError, "#{tool_name} requires a project-relative path"
      end

      root = File.realpath(@project.root_directory)
      root_prefix = root.end_with?(File::SEPARATOR) ? root : "#{root}#{File::SEPARATOR}"
      candidate = File.expand_path(input_path, root)
      unless candidate.start_with?(root_prefix)
        raise ArgumentError, "#{tool_name} path is outside the project root"
      end
      unless FileTest.file?(candidate)
        raise ArgumentError, "#{tool_name} requires an existing regular file"
      end

      resolved_path = File.realpath(candidate)
      unless resolved_path.start_with?(root_prefix)
        raise ArgumentError, "#{tool_name} path is outside the project root"
      end

      [resolved_path, resolved_path[root_prefix.length..-1]]
    end

    def agent_open_file_in_other_pane(path)
      original_window = @frame.edit_win
      begin
        if @frame.edit_win_list.size == 1
          split_window_vertically
          if @frame.edit_win_list.size == 1
            raise ArgumentError, 'find_file could not create another pane'
          end
        end
        other_window
        find_file(path)
      ensure
        if @frame.edit_win_list.include?(original_window)
          @frame.switch_window(original_window)
          @current_buffer = original_window.buffer
        end
      end
    end
  end
end
