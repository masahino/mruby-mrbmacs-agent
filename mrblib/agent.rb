module Mrbmacs
  # Extension entry point for AI agent capabilities.
  class AgentExtension < Extension
    SEARCH_PROJECT_TOOL = {
      'name' => 'search_project',
      'description' => 'Search the current project for a literal string.',
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
      'description' => 'Open a file relative to the current project root.',
      'input_schema' => {
        'type' => 'object',
        'properties' => {
          'path' => { 'type' => 'string' }
        },
        'required' => ['path'],
        'additionalProperties' => false
      }
    }.freeze

    def self.register_agent(app)
      app.ext.data['agent'] ||= {}
    end
  end

  class Application
    def agent_tools
      [AgentExtension::SEARCH_PROJECT_TOOL, AgentExtension::FIND_FILE_TOOL]
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
        Mrbmacs.search_project_core(arguments['query'], root).map do |result|
          agent_project_relative_search_result(result, root_prefix)
        end
      when 'find_file'
        agent_find_file(arguments)
      else
        raise ArgumentError, "Unknown agent tool: #{name}"
      end
    end

    private

    def agent_project_relative_search_result(result, root_prefix)
      converted = result.dup
      file = converted['file'].to_s
      if file.start_with?(root_prefix)
        converted['file'] = file[root_prefix.length..-1]
      end
      converted
    end

    def agent_find_file(arguments)
      unless arguments.is_a?(Hash) && arguments['path'].is_a?(String) &&
             !arguments['path'].empty?
        raise ArgumentError, 'find_file requires a non-empty relative path'
      end
      unless @project && Dir.exist?(@project.root_directory)
        raise ArgumentError, 'Project is not available'
      end

      relative_path = arguments['path']
      if File.absolute_path?(relative_path) || relative_path.start_with?('~')
        raise ArgumentError, 'find_file requires a project-relative path'
      end

      root = File.realpath(@project.root_directory)
      root_prefix = root.end_with?(File::SEPARATOR) ? root : "#{root}#{File::SEPARATOR}"
      candidate = File.expand_path(relative_path, root)
      unless candidate.start_with?(root_prefix)
        raise ArgumentError, 'find_file path is outside the project root'
      end
      unless FileTest.file?(candidate)
        raise ArgumentError, 'find_file requires an existing regular file'
      end

      resolved_path = File.realpath(candidate)
      unless resolved_path.start_with?(root_prefix)
        raise ArgumentError, 'find_file path is outside the project root'
      end

      agent_open_file_in_other_pane(resolved_path)
      { 'path' => relative_path, 'opened' => true }
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
