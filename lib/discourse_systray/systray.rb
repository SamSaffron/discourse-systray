require "gtk3"
require "open3"
require "optparse"
require "timeout"
require "fileutils"
require "json"

module ::DiscourseSystray
  class Systray
    CONFIG_DIR = File.expand_path("~/.config/discourse-systray")
    CONFIG_FILE = File.join(CONFIG_DIR, "config.json")
    OPTIONS = { debug: false, path: nil }

    def self.load_or_prompt_config
      OptionParser
        .new do |opts|
          opts.banner = "Usage: systray.rb [options]"
          opts.on("--debug", "Enable debug mode") { OPTIONS[:debug] = true }
          opts.on("--path PATH", "Set Discourse path") do |p|
            OPTIONS[:path] = p
          end
          opts.on("--console", "Enable console mode") do
            OPTIONS[:console] = true
          end
          opts.on("--attach", "Attach to existing systray") do
            OPTIONS[:attach] = true
          end
        end
        .parse!
      FileUtils.mkdir_p(CONFIG_DIR) unless Dir.exist?(CONFIG_DIR)

      if OPTIONS[:path]
        save_config(path: OPTIONS[:path])
        return OPTIONS[:path]
      end

      if File.exist?(CONFIG_FILE)
        config = JSON.parse(File.read(CONFIG_FILE))
        return config["path"] if config["path"] && Dir.exist?(config["path"])
      end

      # Show dialog to get path
      dialog =
        Gtk::FileChooserDialog.new(
          title: "Select Discourse Directory",
          parent: nil,
          action: :select_folder,
          buttons: [["Cancel", :cancel], ["Select", :accept]]
        )

      path = nil
      if dialog.run == :accept
        path = dialog.filename
        save_config(path: path)
      else
        puts "No Discourse path specified. Exiting."
        exit 1
      end

      dialog.destroy
      path
    end

    def self.save_config(path:, window_geometry: nil)
      config = { path: path }
      config[:window_geometry] = window_geometry if window_geometry
      File.write(CONFIG_FILE, JSON.generate(config))
      nil # Prevent return value from being printed
    end

    def self.load_config
      return {} unless File.exist?(CONFIG_FILE)
      JSON.parse(File.read(CONFIG_FILE))
    rescue JSON::ParserError
      {}
    end
    BUFFER_SIZE = 1000
    BUFFER_TRIM_INTERVAL = 30 # seconds

    def initialize
      puts "DEBUG: Initializing DiscourseSystray" if OPTIONS[:debug]
      
      @discourse_path = self.class.load_or_prompt_config unless OPTIONS[:attach]
      puts "DEBUG: Discourse path: #{@discourse_path}" if OPTIONS[:debug]
      
      @running = false
      @ember_output = []
      @unicorn_output = []
      @processes = {}
      @ember_running = false
      @unicorn_running = false
      @ember_line_count = 0
      @unicorn_line_count = 0
      @status_window = nil
      @buffer_trim_timer = nil
      
      # Add initial test data to buffers with timestamp
      timestamp = Time.now.strftime("%H:%M:%S")
      @ember_output << "#{timestamp} - Initializing Ember output buffer...\n"
      @unicorn_output << "#{timestamp} - Initializing Unicorn output buffer...\n"
      
      puts "DEBUG: Added initial data to buffers" if OPTIONS[:debug]
      puts "DEBUG: ember_output size: #{@ember_output.size}" if OPTIONS[:debug]
      puts "DEBUG: unicorn_output size: #{@unicorn_output.size}" if OPTIONS[:debug]
      
      # Set up periodic buffer trimming
      setup_buffer_trim_timer unless OPTIONS[:attach]
      
      # Add a direct test of buffer content
      if OPTIONS[:debug]
        puts "DEBUG: ember_output content:"
        @ember_output.each_with_index do |line, i|
          puts "  [#{i}] #{line.inspect}"
        end
        
        puts "DEBUG: unicorn_output content:"
        @unicorn_output.each_with_index do |line, i|
          puts "  [#{i}] #{line.inspect}"
        end
      end
      
      puts "DEBUG: Initialized DiscourseSystray with path: #{@discourse_path}" if OPTIONS[:debug]
    end
    
    def setup_buffer_trim_timer
      @buffer_trim_timer = GLib::Timeout.add_seconds(BUFFER_TRIM_INTERVAL) do
        trim_buffers
        true # Keep the timer running
      end
    end
    
    def trim_buffers
      # Trim buffers if they exceed the buffer size
      if @ember_output.size > BUFFER_SIZE
        excess = @ember_output.size - BUFFER_SIZE
        @ember_output.shift(excess)
        @ember_line_count = [@ember_line_count - excess, 0].max
      end
      
      if @unicorn_output.size > BUFFER_SIZE
        excess = @unicorn_output.size - BUFFER_SIZE
        @unicorn_output.shift(excess)
        @unicorn_line_count = [@unicorn_line_count - excess, 0].max
      end
      
      true
    end

    def init_systray
      @indicator = Gtk::StatusIcon.new
      @indicator.pixbuf =
        GdkPixbuf::Pixbuf.new(
          file: File.join(File.dirname(__FILE__), "../../assets/discourse.png")
        )
      @indicator.tooltip_text = "Discourse Manager"

      @indicator.signal_connect("popup-menu") do |tray, button, time|
        menu = Gtk::Menu.new

        # Create menu items with icons
        start_item = Gtk::ImageMenuItem.new(label: "Start Discourse")
        start_item.image =
          Gtk::Image.new(icon_name: "media-playback-start", size: :menu)

        stop_item = Gtk::ImageMenuItem.new(label: "Stop Discourse")
        stop_item.image =
          Gtk::Image.new(icon_name: "media-playback-stop", size: :menu)

        status_item = Gtk::ImageMenuItem.new(label: "Show Status")
        status_item.image =
          Gtk::Image.new(icon_name: "utilities-system-monitor", size: :menu)

        quit_item = Gtk::ImageMenuItem.new(label: "Quit")
        quit_item.image =
          Gtk::Image.new(icon_name: "application-exit", size: :menu)

        # Add items in new order
        menu.append(start_item)
        menu.append(stop_item)
        menu.append(Gtk::SeparatorMenuItem.new)
        menu.append(status_item)
        menu.append(Gtk::SeparatorMenuItem.new)
        menu.append(quit_item)

        start_item.signal_connect("activate") do
          set_icon(:running)
          start_discourse
          @running = true
        end

        stop_item.signal_connect("activate") do
          set_icon(:stopped)
          stop_discourse
          @running = false
        end

        quit_item.signal_connect("activate") do
          cleanup
          Gtk.main_quit
        end

        status_item.signal_connect("activate") { show_status_window }

        menu.show_all

        # Show/hide items based on running state - AFTER show_all
        start_item.visible = !@running
        stop_item.visible = @running
        menu.popup(nil, nil, button, time)
      end
    end

    def start_discourse
      @ember_output.clear
      @unicorn_output.clear

      Dir.chdir(@discourse_path) do
        @processes[:ember] = start_process("bin/ember-cli")
        @ember_running = true
        @processes[:unicorn] = start_process("bin/unicorn")
        @unicorn_running = true
        update_tab_labels if @notebook
      end
    end

    def stop_discourse
      cleanup
    end

    def cleanup
      return if @processes.empty?

      # First disable updates to prevent race conditions
      @view_timeouts&.values&.each do |id|
        begin
          GLib::Source.remove(id)
        rescue StandardError => e
          puts "Error removing timeout: #{e}" if OPTIONS[:debug]
        end
      end
      @view_timeouts&.clear
      
      # Remove buffer trim timer if it exists
      if @buffer_trim_timer
        begin
          GLib::Source.remove(@buffer_trim_timer)
          @buffer_trim_timer = nil
        rescue StandardError => e
          puts "Error removing buffer trim timer: #{e}" if OPTIONS[:debug]
        end
      end

      # Then stop processes
      @processes.each do |name, process|
        begin
          Process.kill("TERM", process[:pid])
          # Wait for process to finish with timeout
          Timeout.timeout(10) { process[:thread].join }
        rescue StandardError => e
          puts "Error stopping #{name}: #{e}" if OPTIONS[:debug]
        end
      end
      @processes.clear
      @ember_running = false
      @unicorn_running = false

      # Finally clean up UI elements
      update_tab_labels if @notebook && !@notebook.destroyed?

      if @status_window && !@status_window.destroyed?
        @status_window.destroy
        @status_window = nil
      end
    end

    def start_process(command, console: false)
      puts "DEBUG: start_process called with command: #{command}" if OPTIONS[:debug]
      
      return start_console_process(command) if console
      
      begin
        stdin, stdout, stderr, wait_thr = Open3.popen3(command)
        puts "DEBUG: Process started with PID: #{wait_thr.pid}" if OPTIONS[:debug]
      rescue => e
        puts "DEBUG: Error starting process: #{e.message}" if OPTIONS[:debug]
        return nil
      end

      # Create a monitor thread that will detect if process dies
      monitor_thread =
        Thread.new do
          begin
            puts "DEBUG: Monitor thread started for PID: #{wait_thr.pid}" if OPTIONS[:debug]
            wait_thr.value # Wait for process to finish
            is_ember = command.include?("ember-cli")
            @ember_running = false if is_ember
            @unicorn_running = false unless is_ember
            puts "DEBUG: Process #{wait_thr.pid} finished, is_ember=#{is_ember}" if OPTIONS[:debug]
            GLib::Idle.add do
              update_tab_labels if @notebook
              false
            end
          rescue => e
            puts "DEBUG: Error in monitor thread: #{e.message}" if OPTIONS[:debug]
          end
        end

      # Add a test message to the buffer
      buffer = command.include?("ember-cli") ? @ember_output : @unicorn_output
      buffer_name = command.include?("ember-cli") ? "ember_output" : "unicorn_output"
      
      timestamp = Time.now.strftime("%H:%M:%S")
      start_message = "#{timestamp} - Starting #{command}...\n"
      buffer << start_message
      
      puts "DEBUG: Added start message to #{buffer_name}: '#{start_message}'" if OPTIONS[:debug]
      puts "DEBUG: Buffer size is now: #{buffer.size}" if OPTIONS[:debug]
      
      # Force immediate GUI update
      GLib::Idle.add do
        puts "DEBUG: Forcing immediate GUI update after start" if OPTIONS[:debug]
        update_all_views
        false
      end

      # Monitor stdout - send to both console and UX buffer
      Thread.new do
        begin
          puts "DEBUG: Starting stdout monitor thread for #{buffer_name}" if OPTIONS[:debug]
          line_count = 0
          
          while line = stdout.gets
            buffer =
              command.include?("ember-cli") ? @ember_output : @unicorn_output
            
            publish_to_pipe(line)
            puts "[OUT] #{line}" if OPTIONS[:debug]
            
            # Add to buffer with size management
            buffer << line
            line_count += 1
            
            if line_count % 10 == 0
              puts "DEBUG: Processed #{line_count} stdout lines for #{buffer_name}" if OPTIONS[:debug]
            end
            
            # Only trim if significantly over limit to reduce frequent shifts
            if buffer.size > BUFFER_SIZE + 100
              excess = buffer.size - BUFFER_SIZE
              buffer.shift(excess)
              puts "DEBUG: Trimmed #{excess} lines from #{buffer_name}" if OPTIONS[:debug]
              
              # Adjust line count if we're tracking this buffer
              if buffer == @ember_output
                @ember_line_count = [@ember_line_count - excess, 0].max
                puts "DEBUG: Adjusted @ember_line_count to #{@ember_line_count}" if OPTIONS[:debug]
              elsif buffer == @unicorn_output
                @unicorn_line_count = [@unicorn_line_count - excess, 0].max
                puts "DEBUG: Adjusted @unicorn_line_count to #{@unicorn_line_count}" if OPTIONS[:debug]
              end
            end
            
            # Force GUI update - use main thread
            GLib::Idle.add do
              update_all_views
              false
            end
          end
          
          puts "DEBUG: stdout stream ended for #{buffer_name}" if OPTIONS[:debug]
        rescue => e
          puts "DEBUG: Error in stdout thread: #{e.message}" if OPTIONS[:debug]
          puts e.backtrace.join("\n") if OPTIONS[:debug]
        end
      end

      # Monitor stderr - send to both console and UX buffer
      Thread.new do
        begin
          puts "DEBUG: Starting stderr monitor thread for #{buffer_name}" if OPTIONS[:debug]
          line_count = 0
          
          while line = stderr.gets
            buffer =
              command.include?("ember-cli") ? @ember_output : @unicorn_output
            
            publish_to_pipe("ERROR: #{line}")
            puts "[ERR] #{line}" if OPTIONS[:debug]
            
            # Add to buffer with size management
            error_line = "ERROR: #{line}"
            buffer << error_line
            line_count += 1
            
            if line_count % 10 == 0
              puts "DEBUG: Processed #{line_count} stderr lines for #{buffer_name}" if OPTIONS[:debug]
            end
            
            # Only trim if significantly over limit to reduce frequent shifts
            if buffer.size > BUFFER_SIZE + 100
              excess = buffer.size - BUFFER_SIZE
              buffer.shift(excess)
              puts "DEBUG: Trimmed #{excess} lines from #{buffer_name}" if OPTIONS[:debug]
              
              # Adjust line count if we're tracking this buffer
              if buffer == @ember_output
                @ember_line_count = [@ember_line_count - excess, 0].max
                puts "DEBUG: Adjusted @ember_line_count to #{@ember_line_count}" if OPTIONS[:debug]
              elsif buffer == @unicorn_output
                @unicorn_line_count = [@unicorn_line_count - excess, 0].max
                puts "DEBUG: Adjusted @unicorn_line_count to #{@unicorn_line_count}" if OPTIONS[:debug]
              end
            end
            
            # Force GUI update - use main thread
            GLib::Idle.add do
              update_all_views
              false
            end
          end
          
          puts "DEBUG: stderr stream ended for #{buffer_name}" if OPTIONS[:debug]
        rescue => e
          puts "DEBUG: Error in stderr thread: #{e.message}" if OPTIONS[:debug]
          puts e.backtrace.join("\n") if OPTIONS[:debug]
        end
      end

      {
        pid: wait_thr.pid,
        stdin: stdin,
        stdout: stdout,
        stderr: stderr,
        thread: wait_thr,
        monitor: monitor_thread
      }
    end

    def show_status_window
      puts "DEBUG: show_status_window called" if OPTIONS[:debug]
      
      if @status_window&.visible?
        puts "DEBUG: Status window already visible, presenting it" if OPTIONS[:debug]
        @status_window.present
        # Force window to current workspace in i3
        if @status_window.window
          @status_window.window.raise
          if system("which i3-msg >/dev/null 2>&1")
            # First move to current workspace, then focus
            system(
              "i3-msg '[id=#{@status_window.window.xid}] move workspace current'"
            )
            system("i3-msg '[id=#{@status_window.window.xid}] focus'")
          end
        end
        return
      end

      # Clean up any existing window
      if @status_window
        puts "DEBUG: Destroying existing status window" if OPTIONS[:debug]
        @status_window.destroy
        @status_window = nil
      end

      puts "DEBUG: Creating new status window" if OPTIONS[:debug]
      @status_window = Gtk::Window.new("Discourse Status")
      @status_window.set_wmclass("discourse-status", "Discourse Status")

      # Load saved geometry or use defaults
      config = self.class.load_config
      if config["window_geometry"]
        geo = config["window_geometry"]
        @status_window.move(geo["x"], geo["y"])
        @status_window.resize(geo["width"], geo["height"])
        puts "DEBUG: Set window geometry from config: #{geo.inspect}" if OPTIONS[:debug]
      else
        @status_window.set_default_size(800, 600)
        @status_window.window_position = :center
        puts "DEBUG: Set default window size 800x600" if OPTIONS[:debug]
      end
      @status_window.type_hint = :dialog
      @status_window.set_role("discourse-status-dialog")

      # Handle window destruction and hide
      @status_window.signal_connect("delete-event") do
        puts "DEBUG: Window delete-event triggered" if OPTIONS[:debug]
        save_window_geometry
        @status_window.hide
        true # Prevent destruction
      end

      # Save position and size when window is moved or resized
      @status_window.signal_connect("configure-event") do
        save_window_geometry
        false
      end

      puts "DEBUG: Creating notebook" if OPTIONS[:debug]
      @notebook = Gtk::Notebook.new

      # Debug buffer contents before creating views
      puts "DEBUG: ember_output size: #{@ember_output.size}" if OPTIONS[:debug]
      puts "DEBUG: unicorn_output size: #{@unicorn_output.size}" if OPTIONS[:debug]
      
      # Add some test data if buffers are empty
      if @ember_output.empty?
        @ember_output << "Test data for ember output - #{Time.now}\n"
        puts "DEBUG: Added test data to ember_output" if OPTIONS[:debug]
      end
      
      if @unicorn_output.empty?
        @unicorn_output << "Test data for unicorn output - #{Time.now}\n"
        puts "DEBUG: Added test data to unicorn_output" if OPTIONS[:debug]
      end

      puts "DEBUG: Creating ember view" if OPTIONS[:debug]
      @ember_view = create_log_view(@ember_output)
      @ember_label = create_status_label("Ember CLI", @ember_running)
      @notebook.append_page(@ember_view, @ember_label)
      puts "DEBUG: Added ember view to notebook" if OPTIONS[:debug]

      puts "DEBUG: Creating unicorn view" if OPTIONS[:debug]
      @unicorn_view = create_log_view(@unicorn_output)
      @unicorn_label = create_status_label("Unicorn", @unicorn_running)
      @notebook.append_page(@unicorn_view, @unicorn_label)
      puts "DEBUG: Added unicorn view to notebook" if OPTIONS[:debug]

      @status_window.add(@notebook)
      puts "DEBUG: Added notebook to status window" if OPTIONS[:debug]
      
      @status_window.show_all
      puts "DEBUG: Called show_all on status window" if OPTIONS[:debug]
      
      # Force an immediate update of the views
      GLib::Idle.add do
        puts "DEBUG: Forcing immediate update after window creation" if OPTIONS[:debug]
        update_all_views
        false
      end
    end

    def update_all_views
      puts "DEBUG: update_all_views called" if OPTIONS[:debug]
      
      unless @status_window
        puts "DEBUG: @status_window is nil" if OPTIONS[:debug]
        return
      end
      
      if @status_window.destroyed?
        puts "DEBUG: @status_window is destroyed" if OPTIONS[:debug]
        return
      end
      
      unless @ember_view
        puts "DEBUG: @ember_view is nil" if OPTIONS[:debug]
        return
      end
      
      unless @unicorn_view
        puts "DEBUG: @unicorn_view is nil" if OPTIONS[:debug]
        return
      end
      
      begin
        # More defensive checks
        if @ember_view && !@ember_view.destroyed?
          if @ember_view.child && !@ember_view.child.destroyed?
            puts "DEBUG: Updating ember view" if OPTIONS[:debug]
            update_log_view(@ember_view.child, @ember_output)
          else
            puts "DEBUG: @ember_view.child is nil or destroyed" if OPTIONS[:debug]
          end
        else
          puts "DEBUG: @ember_view is destroyed" if OPTIONS[:debug]
        end
        
        if @unicorn_view && !@unicorn_view.destroyed?
          if @unicorn_view.child && !@unicorn_view.child.destroyed?
            puts "DEBUG: Updating unicorn view" if OPTIONS[:debug]
            update_log_view(@unicorn_view.child, @unicorn_output)
          else
            puts "DEBUG: @unicorn_view.child is nil or destroyed" if OPTIONS[:debug]
          end
        else
          puts "DEBUG: @unicorn_view is destroyed" if OPTIONS[:debug]
        end
        
        # Force UI update
        puts "DEBUG: Processing pending GTK events" if OPTIONS[:debug]
        event_count = 0
        while Gtk.events_pending? && event_count < 100  # Limit to prevent infinite loop
          Gtk.main_iteration_do(false)
          event_count += 1
        end
        puts "DEBUG: Processed #{event_count} GTK events" if OPTIONS[:debug]
      rescue StandardError => e
        puts "DEBUG: Error updating views: #{e}" if OPTIONS[:debug]
        puts e.backtrace.join("\n") if OPTIONS[:debug]
      end
    end

    def create_log_view(buffer)
      puts "DEBUG: create_log_view called for #{buffer == @ember_output ? 'ember' : 'unicorn'}" if OPTIONS[:debug]
      
      scroll = Gtk::ScrolledWindow.new
      text_view = Gtk::TextView.new
      text_view.editable = false
      text_view.wrap_mode = :word
      text_view.monospace = true

      puts "DEBUG: TextView created with object_id=#{text_view.object_id}" if OPTIONS[:debug]

      # Set white text on black background - more explicit settings
      begin
        text_view.override_background_color(:normal, Gdk::RGBA.new(0, 0, 0, 1))
        text_view.override_color(:normal, Gdk::RGBA.new(1, 1, 1, 1))
        puts "DEBUG: Set text/background colors" if OPTIONS[:debug]
      rescue => e
        puts "DEBUG: Error setting colors: #{e.message}" if OPTIONS[:debug]
      end
      
      # Set font size explicitly
      begin
        font_desc = Pango::FontDescription.new
        font_desc.family = "Monospace"
        font_desc.size = 10 * Pango::SCALE
        text_view.override_font(font_desc)
        puts "DEBUG: Set font" if OPTIONS[:debug]
      rescue => e
        puts "DEBUG: Error setting font: #{e.message}" if OPTIONS[:debug]
      end

      # Add initial welcome text with timestamp
      timestamp = Time.now.strftime("%H:%M:%S")
      initial_text = "#{timestamp} - Initializing log view...\n"
      
      begin
        text_view.buffer.text = initial_text
        puts "DEBUG: Set initial text: '#{initial_text}'" if OPTIONS[:debug]
      rescue => e
        puts "DEBUG: Error setting initial text: #{e.message}" if OPTIONS[:debug]
      end
      
      # Force immediate update
      begin
        update_log_view(text_view, buffer)
        puts "DEBUG: Called initial update_log_view" if OPTIONS[:debug]
      rescue => e
        puts "DEBUG: Error in initial update_log_view: #{e.message}" if OPTIONS[:debug]
        puts e.backtrace.join("\n") if OPTIONS[:debug]
      end
      
      # Add debug info if in debug mode
      if OPTIONS[:debug]
        begin
          buffer_info = "Buffer object_id=#{buffer.object_id}, size=#{buffer.size}\n"
          text_view.buffer.text += "Debug mode enabled\n"
          text_view.buffer.text += buffer_info
          puts "DEBUG: Added debug info to buffer: #{buffer_info}" if OPTIONS[:debug]
        rescue => e
          puts "DEBUG: Error adding debug info: #{e.message}" if OPTIONS[:debug]
        end
      end

      # Store timeouts in instance variable for proper cleanup
      @view_timeouts ||= {}

      # Set up periodic refresh with validity check - more frequent updates
      timeout_id =
        GLib::Timeout.add(250) do
          if text_view&.parent.nil? || text_view.destroyed?
            puts "DEBUG: TextView destroyed or parent nil, removing timeout" if OPTIONS[:debug]
            @view_timeouts.delete(text_view.object_id)
            false # Stop the timeout if view is destroyed
          else
            begin
              update_log_view(text_view, buffer)
            rescue StandardError => e
              puts "DEBUG: Error in timeout update_log_view: #{e.message}" if OPTIONS[:debug]
              puts e.backtrace.join("\n") if OPTIONS[:debug]
              
              # Add error directly to the buffer without tags
              if OPTIONS[:debug] && !text_view.destroyed? && !text_view.buffer.destroyed?
                begin
                  error_msg = "\nERROR updating view: #{e.message}\n"
                  text_view.buffer.insert(text_view.buffer.end_iter, error_msg)
                  puts "DEBUG: Added error message to buffer: #{error_msg}" if OPTIONS[:debug]
                rescue => e2
                  puts "DEBUG: Error adding error message to buffer: #{e2.message}" if OPTIONS[:debug]
                end
              end
            end
            true # Keep the timeout active
          end
        end

      @view_timeouts[text_view.object_id] = timeout_id
      puts "DEBUG: Set up timeout with id=#{timeout_id}" if OPTIONS[:debug]

      # Clean up timeout when view is destroyed
      text_view.signal_connect("destroy") do
        puts "DEBUG: TextView destroy signal triggered" if OPTIONS[:debug]
        if timeout_id = @view_timeouts.delete(text_view.object_id)
          begin
            GLib::Source.remove(timeout_id)
            puts "DEBUG: Removed timeout #{timeout_id}" if OPTIONS[:debug]
          rescue StandardError => e
            puts "DEBUG: Error removing timeout: #{e.message}" if OPTIONS[:debug]
            nil
          end
        end
      end

      scroll.add(text_view)
      puts "DEBUG: Added TextView to ScrolledWindow" if OPTIONS[:debug]
      scroll
    end

    def create_ansi_tags(buffer)
      # Basic ANSI colors
      {
        "31" => "#ff6b6b", # Brighter red
        "32" => "#87ff87", # Brighter green
        "33" => "#ffff87", # Brighter yellow
        "34" => "#87d7ff", # Brighter blue
        "35" => "#ff87ff", # Brighter magenta
        "36" => "#87ffff", # Brighter cyan
        "37" => "#ffffff"  # White
      }.each do |code, color|
        buffer.create_tag("ansi_#{code}", foreground: color)
      end

      # Add more tags for bold, etc
      buffer.create_tag("bold", weight: :bold)
      
      # Add a default text tag for better visibility
      buffer.create_tag("default_text", foreground: "#ffffff")
    end

    def update_log_view(text_view, buffer)
      puts "DEBUG: update_log_view called" if OPTIONS[:debug]
      
      if text_view.nil?
        puts "DEBUG: text_view is nil" if OPTIONS[:debug]
        return
      end
      
      if text_view.destroyed?
        puts "DEBUG: text_view is destroyed" if OPTIONS[:debug]
        return
      end
      
      if text_view.buffer.nil?
        puts "DEBUG: text_view.buffer is nil" if OPTIONS[:debug]
        return
      end
      
      if text_view.buffer.destroyed?
        puts "DEBUG: text_view.buffer is destroyed" if OPTIONS[:debug]
        return
      end

      # Determine which offset counter to use
      offset_var =
        (
          if buffer.equal?(@ember_output)
            buffer_name = "ember_output"
            :@ember_line_count
          else
            buffer_name = "unicorn_output"
            :@unicorn_line_count
          end
        )
      current_offset = instance_variable_get(offset_var)
      
      puts "DEBUG: update_log_view for #{buffer_name}, buffer.size=#{buffer.size}, current_offset=#{current_offset}" if OPTIONS[:debug]

      # Don't call if we've already processed all lines
      if buffer.size <= current_offset
        puts "DEBUG: No new lines to process (buffer.size <= current_offset)" if OPTIONS[:debug]
        return
      end

      # Always add debug info to the buffer
      if OPTIONS[:debug]
        debug_info = "DEBUG INFO: Buffer=#{buffer_name}, size=#{buffer.size}, offset=#{current_offset}\n"
        puts debug_info
        
        # Force text into the buffer
        if text_view.buffer.text.empty?
          text_view.buffer.text = debug_info
          puts "DEBUG: Added initial debug text to empty buffer" if OPTIONS[:debug]
        end
      end

      # Process only the new lines
      new_lines = buffer[current_offset..-1]
      
      # If there are no new lines, just return
      if new_lines.nil?
        puts "DEBUG: new_lines is nil" if OPTIONS[:debug]
        if text_view.buffer.text.empty?
          text_view.buffer.text = "No log data available yet...\n"
          puts "DEBUG: Added 'No log data' message to empty buffer" if OPTIONS[:debug]
        end
        return
      end
      
      if new_lines.empty?
        puts "DEBUG: new_lines is empty" if OPTIONS[:debug]
        if text_view.buffer.text.empty?
          text_view.buffer.text = "No new log data available...\n"
          puts "DEBUG: Added 'No new log data' message to empty buffer" if OPTIONS[:debug]
        end
        return
      end
      
      puts "DEBUG: Processing #{new_lines.size} new lines" if OPTIONS[:debug]
      
      # Get scroll position
      adj = text_view&.parent&.vadjustment
      was_at_bottom = (adj && adj.value >= adj.upper - adj.page_size - 50)
      old_value = adj ? adj.value : 0

      # Simple approach: just append the text directly
      new_lines.each_with_index do |line, index|
        unless line
          puts "DEBUG: Line #{index} is nil" if OPTIONS[:debug]
          next
        end
        
        # Strip ANSI codes for simplicity
        clean_line = line.gsub(/\e\[[0-9;]*[mK]/, '')
        
        # Debug the line
        if OPTIONS[:debug] && index < 5  # Only show first few lines to avoid flooding
          puts "DEBUG: Adding line #{index}: #{clean_line.inspect}"
        end
        
        # Insert at end of buffer
        begin
          text_view.buffer.insert(text_view.buffer.end_iter, clean_line)
          puts "DEBUG: Successfully inserted line #{index}" if OPTIONS[:debug] && index < 5
        rescue => e
          puts "DEBUG: Error inserting line #{index}: #{e.message}" if OPTIONS[:debug]
        end
      end

      # Update our offset counter
      instance_variable_set(offset_var, buffer.size)
      puts "DEBUG: Updated #{offset_var} to #{buffer.size}" if OPTIONS[:debug]

      # Restore scroll position
      if adj
        if was_at_bottom
          adj.value = adj.upper - adj.page_size
          puts "DEBUG: Scrolled to bottom" if OPTIONS[:debug]
        else
          adj.value = old_value
          puts "DEBUG: Restored scroll position to #{old_value}" if OPTIONS[:debug]
        end
      else
        puts "DEBUG: No adjustment available" if OPTIONS[:debug]
      end
      
      # Check if text was actually added
      puts "DEBUG: Final buffer text length: #{text_view.buffer.text.length}" if OPTIONS[:debug]
      puts "DEBUG: First 100 chars: #{text_view.buffer.text[0..100].inspect}" if OPTIONS[:debug]
    end

    def create_status_label(text, running)
      box = Gtk::Box.new(:horizontal, 5)
      label = Gtk::Label.new(text)
      status = Gtk::Label.new
      color =
        (
          if running
            Gdk::RGBA.new(0.2, 0.8, 0.2, 1)
          else
            Gdk::RGBA.new(0.8, 0.2, 0.2, 1)
          end
        )
      status.override_color(:normal, color)
      status.text = running ? "●" : "○"
      box.pack_start(label, expand: false, fill: false, padding: 0)
      box.pack_start(status, expand: false, fill: false, padding: 0)
      box.show_all
      box
    end

    def update_tab_labels
      return unless @notebook && !@notebook.destroyed?
      return unless @ember_label && @unicorn_label
      return if @ember_label.destroyed? || @unicorn_label.destroyed?

      [@ember_label, @unicorn_label].each do |label|
        next unless label.children && label.children.length > 1
        next if label.children[1].destroyed?

        is_running = label == @ember_label ? @ember_running : @unicorn_running
        begin
          label.children[1].text = is_running ? "●" : "○"
          label.children[1].override_color(
            :normal,
            Gdk::RGBA.new(
              is_running ? 0.2 : 0.8,
              is_running ? 0.8 : 0.2,
              0.2,
              1
            )
          )
        rescue StandardError => e
          puts "Error updating label: #{e}" if OPTIONS[:debug]
        end
      end
    end

    def save_window_geometry
      return unless @status_window&.visible? && @status_window.window

      x, y = @status_window.position
      width, height = @status_window.size

      self.class.save_config(
        path: @discourse_path,
        window_geometry: {
          "x" => x,
          "y" => y,
          "width" => width,
          "height" => height
        }
      )
    end

    def set_icon(status)
      icon_file = status == :running ? "discourse_running.png" : "discourse.png"
      icon_path = File.join(File.dirname(__FILE__), "../../assets", icon_file)
      @indicator.pixbuf = GdkPixbuf::Pixbuf.new(file: icon_path)
    end

    def start_console_process(command)
      stdin, stdout, stderr, wait_thr = Open3.popen3(command)

      # Pipe stdout to console and add to buffer
      Thread.new do
        while line = stdout.gets
          buffer =
            command.include?("ember-cli") ? @ember_output : @unicorn_output
          print line
          buffer << line
          buffer.shift if buffer.size > BUFFER_SIZE
        end
      end

      # Pipe stderr to console and add to buffer
      Thread.new do
        while line = stderr.gets
          buffer =
            command.include?("ember-cli") ? @ember_output : @unicorn_output
          STDERR.print line
          buffer << line
          buffer.shift if buffer.size > BUFFER_SIZE
        end
      end

      {
        pid: wait_thr.pid,
        stdin: stdin,
        stdout: stdout,
        stderr: stderr,
        thread: wait_thr
      }
    end

    PIPE_PATH = "/tmp/discourse_systray_cmd"
    PID_FILE = "/tmp/discourse_systray.pid"

    def self.running?
      return false unless File.exist?(PID_FILE)
      pid = File.read(PID_FILE).to_i
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::ENOENT
      begin
        File.unlink(PID_FILE)
      rescue StandardError
        nil
      end
      false
    end

    attr_reader :discourse_path

    def self.run
      new.run
    end

    def run
      if OPTIONS[:attach]
        require "rb-inotify"

        notifier = INotify::Notifier.new

        begin
          pipe = File.open(PIPE_PATH, "r")

          # Watch for pipe deletion
          notifier.watch(File.dirname(PIPE_PATH), :delete) do |event|
            if event.name == File.basename(PIPE_PATH)
              puts "Pipe was deleted, exiting."
              exit 0
            end
          end

          # Read from pipe in a separate thread
          reader =
            Thread.new do
              begin
                while true
                  if IO.select([pipe], nil, nil, 0.5)
                    while line = pipe.gets
                      puts line
                      STDOUT.flush
                    end
                  end

                  sleep 0.1
                  unless File.exist?(PIPE_PATH)
                    puts "Pipe was deleted, exiting."
                    exit 0
                  end
                end
              rescue EOFError, IOError
                puts "Pipe closed, exiting."
                exit 0
              end
            end

          # Handle notifications in main thread
          notifier.run
        rescue Errno::ENOENT
          puts "Pipe doesn't exist, exiting."
          exit 1
        ensure
          reader&.kill
          pipe&.close
          notifier&.close
        end
      else
        return if self.class.running?

        system("mkfifo #{PIPE_PATH}") unless File.exist?(PIPE_PATH)

        # Create named pipe and write PID file
        system("mkfifo #{PIPE_PATH}") unless File.exist?(PIPE_PATH)
        File.write(PID_FILE, Process.pid.to_s)

        # Set up cleanup on exit
        at_exit do
          begin
            File.unlink(PIPE_PATH) if File.exist?(PIPE_PATH)
            File.unlink(PID_FILE) if File.exist?(PID_FILE)
          rescue StandardError => e
            puts "Error during cleanup: #{e}" if OPTIONS[:debug]
          end
        end

        # Initialize GTK
        Gtk.init

        # Setup systray icon and menu
        init_systray

        # Start GTK main loop
        Gtk.main
      end
    end

    def publish_to_pipe(msg)
      return unless File.exist?(PIPE_PATH)
      puts "Publish to pipe: #{msg}" if OPTIONS[:debug]
      begin
        File.open(PIPE_PATH, "w") { |f| f.puts(msg) }
      rescue Errno::EPIPE, IOError => e
        puts "Error writing to pipe: #{e}" if OPTIONS[:debug]
      end
    end

    def handle_command(cmd)
      puts "Received command: #{cmd}" if OPTIONS[:debug]
    end
  end
end
