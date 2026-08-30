module Mrbmacs
  module AgentTestSupport
    class Window
      attr_accessor :buffer

      def initialize(buffer)
        @buffer = buffer
      end
    end

    class Frame
      attr_accessor :edit_win, :edit_win_list

      def initialize(edit_win, edit_win_list)
        @edit_win = edit_win
        @edit_win_list = edit_win_list
      end

      def switch_window(window)
        @edit_win = window
      end
    end

    class App < Application
      attr_reader :opened_file

      def initialize(project = nil)
        @ext = Extension.new
        @project = project
      end

      def agent_open_file_in_other_pane(path)
        @opened_file = path
      end
    end

    def self.with_project
      tmp_directory = ENV['TMPDIR'] || '/tmp'
      root = File.join(tmp_directory, "mrbmacs-agent-test-#{$$}-#{Time.now.to_i}")
      build_directory = File.join(root, 'build')
      source_file = File.join(root, 'source.txt')
      generated_file = File.join(build_directory, 'generated.txt')

      begin
        Dir.mkdir(root)
        Dir.mkdir(build_directory)
        File.open(source_file, 'w') do |file|
          file.write("first line\ntarget_word here\n")
        end
        File.open(generated_file, 'w') do |file|
          file.write("excluded target_word\n")
        end
        yield root
      ensure
        [source_file, generated_file].each do |file|
          File.delete(file) if File.exist?(file)
        end
        [build_directory, root].each do |directory|
          Dir.rmdir(directory) if Dir.exist?(directory)
        end
      end
    end
  end
end

assert('AgentExtension is an mrbmacs extension') do
  assert_true Mrbmacs::AgentExtension < Mrbmacs::Extension
end

assert('AgentExtension registers agent state') do
  app = Mrbmacs::AgentTestSupport::App.new

  Mrbmacs::AgentExtension.register_agent(app)

  assert_equal({}, app.ext.data['agent'])
end

assert('AgentExtension preserves existing agent state when registered again') do
  app = Mrbmacs::AgentTestSupport::App.new
  app.ext.data['agent'] = { 'enabled' => true }

  Mrbmacs::AgentExtension.register_agent(app)

  assert_equal({ 'enabled' => true }, app.ext.data['agent'])
end

assert('agent_tools exposes project search, file open, and file read tools') do
  app = Mrbmacs::AgentTestSupport::App.new

  tools = app.agent_tools

  assert_equal 5, tools.length
  assert_equal 'search_project', tools[0]['name']
  assert_equal ['query'], tools[0]['input_schema']['required']
  assert_equal({ 'type' => 'string' }, tools[0]['input_schema']['properties']['query'])
  assert_false tools[0]['input_schema']['additionalProperties']
  assert_equal 'find_file', tools[1]['name']
  assert_equal ['path'], tools[1]['input_schema']['required']
  assert_equal({ 'type' => 'string' }, tools[1]['input_schema']['properties']['path'])
  assert_false tools[1]['input_schema']['additionalProperties']
  assert_equal 'read_file', tools[2]['name']
  assert_equal ['path'], tools[2]['input_schema']['required']
  assert_equal 'read_file_range', tools[3]['name']
  assert_equal ['path', 'start_line', 'end_line'], tools[3]['input_schema']['required']
  assert_equal 'find_files', tools[4]['name']
  assert_equal ['query'], tools[4]['input_schema']['required']
end

assert('agent_call_tool searches only the current project') do
  Mrbmacs::AgentTestSupport.with_project do |root|
    app = Mrbmacs::AgentTestSupport::App.new(Mrbmacs::Project.new(root))

    result = app.agent_call_tool('search_project', { 'query' => 'target_word' })
    results = result['matches']

    assert_equal 1, results.length
    assert_equal 'source.txt', results[0]['file']
    assert_equal 2, results[0]['line']
    assert_equal 'target_word here', results[0]['text']
    assert_equal 1, result['total_matches']
    assert_equal 1, result['returned_matches']
    assert_false result['truncated']
  end
end

assert('search_project results can be passed directly to find_file') do
  Mrbmacs::AgentTestSupport.with_project do |root|
    app = Mrbmacs::AgentTestSupport::App.new(Mrbmacs::Project.new(root))
    result = app.agent_call_tool('search_project', { 'query' => 'target_word' })['matches'].first

    app.agent_call_tool('find_file', { 'path' => result['file'] })

    assert_equal File.realpath(File.join(root, 'source.txt')), app.opened_file
  end
end

assert('agent search_project limits result count and line text') do
  Mrbmacs::AgentTestSupport.with_project do |root|
    source_file = File.join(root, 'source.txt')
    File.open(source_file, 'w') do |file|
      60.times { file.write("target_word #{'x' * 600}\n") }
    end
    app = Mrbmacs::AgentTestSupport::App.new(Mrbmacs::Project.new(root))

    result = app.agent_call_tool('search_project', { 'query' => 'target_word' })

    assert_equal 60, result['total_matches']
    assert_equal Mrbmacs::AgentExtension::MAX_SEARCH_RESULTS,
                 result['returned_matches']
    assert_true result['truncated']
    all_text_limited = result['matches'].all? do |match|
      match['text'].length <= Mrbmacs::AgentExtension::MAX_SEARCH_TEXT_CHARS
    end
    assert_true all_text_limited
  end
end

assert('agent_call_tool rejects an unknown tool') do
  app = Mrbmacs::AgentTestSupport::App.new

  assert_raise(ArgumentError) do
    app.agent_call_tool('unknown', {})
  end
end

assert('agent_call_tool rejects invalid search_project arguments') do
  app = Mrbmacs::AgentTestSupport::App.new(Mrbmacs::Project.new(Dir.pwd))

  [nil, {}, { 'query' => nil }, { 'query' => '' }].each do |arguments|
    assert_raise(ArgumentError) do
      app.agent_call_tool('search_project', arguments)
    end
  end
end

assert('agent_call_tool rejects search_project without a project') do
  app = Mrbmacs::AgentTestSupport::App.new

  assert_raise(ArgumentError) do
    app.agent_call_tool('search_project', { 'query' => 'target_word' })
  end
end

assert('agent_call_tool opens a regular file relative to the project root') do
  Mrbmacs::AgentTestSupport.with_project do |root|
    app = Mrbmacs::AgentTestSupport::App.new(Mrbmacs::Project.new(root))

    result = app.agent_call_tool('find_file', { 'path' => 'source.txt' })

    assert_equal File.realpath(File.join(root, 'source.txt')), app.opened_file
    assert_equal({ 'path' => 'source.txt', 'opened' => true }, result)
  end
end

assert('agent find_file opens in another pane and restores the original pane') do
  Mrbmacs::AgentTestSupport.with_project do |root|
    original_buffer = Object.new
    file_buffer = Object.new
    original_window = Mrbmacs::AgentTestSupport::Window.new(original_buffer)
    file_window = Mrbmacs::AgentTestSupport::Window.new(file_buffer)
    frame = Mrbmacs::AgentTestSupport::Frame.new(
      original_window,
      [original_window, file_window]
    )
    app = Mrbmacs::AgentTestSupport::App.new(Mrbmacs::Project.new(root))
    app.instance_variable_set(:@frame, frame)
    app.instance_variable_set(:@current_buffer, original_buffer)
    opened_window = nil
    app.define_singleton_method(:other_window) do
      @frame.switch_window(file_window)
      @current_buffer = file_window.buffer
    end
    app.define_singleton_method(:find_file) do |_path|
      opened_window = @frame.edit_win
    end

    app.send(:agent_open_file_in_other_pane, File.join(root, 'source.txt'))

    assert_equal file_window, opened_window
    assert_equal original_window, frame.edit_win
    assert_equal original_buffer, app.current_buffer
  end
end

assert('agent_call_tool rejects invalid find_file arguments') do
  app = Mrbmacs::AgentTestSupport::App.new(Mrbmacs::Project.new(Dir.pwd))

  [nil, {}, { 'path' => nil }, { 'path' => '' }].each do |arguments|
    assert_raise(ArgumentError) do
      app.agent_call_tool('find_file', arguments)
    end
  end
end

assert('agent_call_tool rejects absolute paths and directories') do
  Mrbmacs::AgentTestSupport.with_project do |root|
    app = Mrbmacs::AgentTestSupport::App.new(Mrbmacs::Project.new(root))

    assert_raise(ArgumentError) do
      app.agent_call_tool('find_file', { 'path' => File.join(root, 'source.txt') })
    end
    assert_raise(ArgumentError) do
      app.agent_call_tool('find_file', { 'path' => 'build' })
    end
    assert_raise(ArgumentError) do
      app.agent_call_tool('find_file', { 'path' => '~/source.txt' })
    end
  end
end

assert('agent_call_tool rejects traversal outside the project root') do
  Mrbmacs::AgentTestSupport.with_project do |root|
    outside_file = "#{root}-outside.txt"
    begin
      File.open(outside_file, 'w') { |file| file.write('outside') }
      app = Mrbmacs::AgentTestSupport::App.new(Mrbmacs::Project.new(root))

      assert_raise(ArgumentError) do
        app.agent_call_tool('find_file', { 'path' => "../#{File.basename(outside_file)}" })
      end
    ensure
      File.delete(outside_file) if File.exist?(outside_file)
    end
  end
end

assert('agent_call_tool rejects a symlink to a file outside the project root') do
  if File.respond_to?(:symlink)
    Mrbmacs::AgentTestSupport.with_project do |root|
      outside_file = "#{root}-outside.txt"
      link = File.join(root, 'outside-link.txt')
      begin
        File.open(outside_file, 'w') { |file| file.write('outside') }
        File.symlink(outside_file, link)
        app = Mrbmacs::AgentTestSupport::App.new(Mrbmacs::Project.new(root))

        assert_raise(ArgumentError) do
          app.agent_call_tool('find_file', { 'path' => 'outside-link.txt' })
        end
      ensure
        File.delete(link) if File.exist?(link)
        File.delete(outside_file) if File.exist?(outside_file)
      end
    end
  end
end

assert('agent_call_tool reads a project text file without changing editor state') do
  Mrbmacs::AgentTestSupport.with_project do |root|
    app = Mrbmacs::AgentTestSupport::App.new(Mrbmacs::Project.new(root))
    current_buffer = Object.new
    app.instance_variable_set(:@current_buffer, current_buffer)

    result = app.agent_call_tool('read_file', { 'path' => 'source.txt' })

    assert_equal 'source.txt', result['file']
    assert_equal "first line\ntarget_word here\n", result['content']
    assert_equal current_buffer, app.current_buffer
    assert_nil app.opened_file
  end
end

assert('agent_call_tool reads a one-based file line range') do
  Mrbmacs::AgentTestSupport.with_project do |root|
    app = Mrbmacs::AgentTestSupport::App.new(Mrbmacs::Project.new(root))

    result = app.agent_call_tool(
      'read_file_range',
      { 'path' => 'source.txt', 'start_line' => 2, 'end_line' => 20 }
    )

    assert_equal 'source.txt', result['file']
    assert_equal 2, result['start_line']
    assert_equal 2, result['end_line']
    assert_equal "target_word here\n", result['content']
  end
end

assert('agent_call_tool validates read_file_range line numbers') do
  Mrbmacs::AgentTestSupport.with_project do |root|
    app = Mrbmacs::AgentTestSupport::App.new(Mrbmacs::Project.new(root))
    invalid_ranges = [
      [0, 1],
      [2, 1],
      [1, 201],
      [3, 3],
      ['1', 2]
    ]

    invalid_ranges.each do |start_line, end_line|
      assert_raise(ArgumentError) do
        app.agent_call_tool(
          'read_file_range',
          { 'path' => 'source.txt', 'start_line' => start_line, 'end_line' => end_line }
        )
      end
    end
  end
end

assert('agent file read tools reject binary and oversized files') do
  Mrbmacs::AgentTestSupport.with_project do |root|
    binary_file = File.join(root, 'binary.dat')
    large_file = File.join(root, 'large.txt')
    begin
      File.open(binary_file, 'wb') { |file| file.write("text\0data") }
      File.open(large_file, 'wb') do |file|
        file.write('x' * (Mrbmacs::AgentExtension::MAX_READ_BYTES + 1))
      end
      app = Mrbmacs::AgentTestSupport::App.new(Mrbmacs::Project.new(root))

      assert_raise(ArgumentError) do
        app.agent_call_tool('read_file', { 'path' => 'binary.dat' })
      end
      assert_raise(ArgumentError) do
        app.agent_call_tool('read_file', { 'path' => 'large.txt' })
      end
      assert_raise(ArgumentError) do
        app.agent_call_tool(
          'read_file_range',
          { 'path' => 'binary.dat', 'start_line' => 1, 'end_line' => 1 }
        )
      end
    ensure
      File.delete(binary_file) if File.exist?(binary_file)
      File.delete(large_file) if File.exist?(large_file)
    end
  end
end

assert('agent_call_tool finds sorted project-relative file paths by name') do
  Mrbmacs::AgentTestSupport.with_project do |root|
    nested_directory = File.join(root, 'nested-name')
    nested_file = File.join(nested_directory, 'other.txt')
    begin
      Dir.mkdir(nested_directory)
      File.open(nested_file, 'w') { |file| file.write('content') }
      app = Mrbmacs::AgentTestSupport::App.new(Mrbmacs::Project.new(root))

      by_name = app.agent_call_tool('find_files', { 'query' => 'source' })
      by_directory = app.agent_call_tool('find_files', { 'query' => 'nested-name' })

      assert_equal ['source.txt'], by_name['files']
      assert_equal ['nested-name/other.txt'], by_directory['files']
      assert_false by_name['truncated']
      assert_equal 1, by_name['total_files']
    ensure
      File.delete(nested_file) if File.exist?(nested_file)
      Dir.rmdir(nested_directory) if Dir.exist?(nested_directory)
    end
  end
end

assert('agent find_files excludes configured directories and symlinks') do
  Mrbmacs::AgentTestSupport.with_project do |root|
    link = File.join(root, 'linked-source.txt')
    begin
      app = Mrbmacs::AgentTestSupport::App.new(Mrbmacs::Project.new(root))
      File.symlink(File.join(root, 'source.txt'), link) if File.respond_to?(:symlink)

      result = app.agent_call_tool('find_files', { 'query' => '.txt' })

      assert_true result['files'].include?('source.txt')
      assert_false result['files'].include?('build/generated.txt')
      assert_false result['files'].include?('linked-source.txt')
    ensure
      File.delete(link) if File.exist?(link)
    end
  end
end

assert('agent find_files results can be passed directly to read_file') do
  Mrbmacs::AgentTestSupport.with_project do |root|
    app = Mrbmacs::AgentTestSupport::App.new(Mrbmacs::Project.new(root))
    path = app.agent_call_tool('find_files', { 'query' => 'source.txt' })['files'].first

    result = app.agent_call_tool('read_file', { 'path' => path })

    assert_equal 'source.txt', result['file']
  end
end

assert('agent find_files rejects invalid arguments and missing projects') do
  app = Mrbmacs::AgentTestSupport::App.new(Mrbmacs::Project.new(Dir.pwd))
  [nil, {}, { 'query' => nil }, { 'query' => '' }].each do |arguments|
    assert_raise(ArgumentError) { app.agent_call_tool('find_files', arguments) }
  end

  app = Mrbmacs::AgentTestSupport::App.new
  assert_raise(ArgumentError) do
    app.agent_call_tool('find_files', { 'query' => 'source' })
  end
end

assert('agent find_files limits the number of returned paths') do
  Mrbmacs::AgentTestSupport.with_project do |root|
    files = []
    begin
      101.times do |index|
        path = File.join(root, "limited-#{index}.txt")
        File.open(path, 'w') { |file| file.write('content') }
        files << path
      end
      app = Mrbmacs::AgentTestSupport::App.new(Mrbmacs::Project.new(root))

      result = app.agent_call_tool('find_files', { 'query' => 'limited-' })

      assert_equal 101, result['total_files']
      assert_equal Mrbmacs::AgentExtension::MAX_FIND_FILES_RESULTS,
                   result['returned_files']
      assert_true result['truncated']
      assert_equal result['files'].sort, result['files']
    ensure
      files.each { |file| File.delete(file) if File.exist?(file) }
    end
  end
end
