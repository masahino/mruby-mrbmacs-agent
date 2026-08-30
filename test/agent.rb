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

assert('agent_tools exposes search_project and find_file') do
  app = Mrbmacs::AgentTestSupport::App.new

  tools = app.agent_tools

  assert_equal 2, tools.length
  assert_equal 'search_project', tools[0]['name']
  assert_equal ['query'], tools[0]['input_schema']['required']
  assert_equal({ 'type' => 'string' }, tools[0]['input_schema']['properties']['query'])
  assert_false tools[0]['input_schema']['additionalProperties']
  assert_equal 'find_file', tools[1]['name']
  assert_equal ['path'], tools[1]['input_schema']['required']
  assert_equal({ 'type' => 'string' }, tools[1]['input_schema']['properties']['path'])
  assert_false tools[1]['input_schema']['additionalProperties']
end

assert('agent_call_tool searches only the current project') do
  Mrbmacs::AgentTestSupport.with_project do |root|
    app = Mrbmacs::AgentTestSupport::App.new(Mrbmacs::Project.new(root))

    results = app.agent_call_tool('search_project', { 'query' => 'target_word' })

    assert_equal 1, results.length
    assert_equal 'source.txt', results[0]['file']
    assert_equal 2, results[0]['line']
    assert_equal 'target_word here', results[0]['text']
  end
end

assert('search_project results can be passed directly to find_file') do
  Mrbmacs::AgentTestSupport.with_project do |root|
    app = Mrbmacs::AgentTestSupport::App.new(Mrbmacs::Project.new(root))
    result = app.agent_call_tool('search_project', { 'query' => 'target_word' }).first

    app.agent_call_tool('find_file', { 'path' => result['file'] })

    assert_equal File.realpath(File.join(root, 'source.txt')), app.opened_file
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
