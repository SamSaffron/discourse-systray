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
      @status_window = nil
      @buffer_trim_timer = nil
      
      # Initialize pipe queue for background processing
      initialize_pipe_queue
      
      # Add initial welcome message to buffers with timestamp
      timestamp = Time.now.strftime("%H:%M:%S")
      @ember_output << "#{timestamp} - Discourse Ember CLI Log\n"
      @ember_output << "Start Discourse to see Ember CLI logs here.\n"
      @ember_output << "\n"
      
      @unicorn_output << "#{timestamp} - Discourse Unicorn Log\n"
      @unicorn_output << "Start Discourse to see Unicorn logs here.\n"
      @unicorn_output << "\n"
      
      # Add a visual separator
      @ember_output << "=" * 50 + "\n"
      @unicorn_output << "=" * 50 + "\n"
      
      puts "DEBUG: Added initial data to buffers" if OPTIONS[:debug]
      puts "DEBUG: ember_output size: #{@ember_output.size}" if OPTIONS[:debug]
      puts "DEBUG: unicorn_output size: #{@unicorn_output.size}" if OPTIONS[:debug]
      
      # Set up periodic buffer trimming
      setup_buffer_trim_timer unless OPTIONS[:attach]
      
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
      
      # Stop pipe thread
      if @pipe_thread
        begin
          @pipe_queue.push(:exit) if @pipe_queue
          @pipe_thread.join(2) # Wait up to 2 seconds
          @pipe_thread.kill if @pipe_thread.alive?
        rescue StandardError => e
          puts "Error stopping pipe thread: #{e}" if OPTIONS[:debug]
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
            wait_thr.value # Wait for process to finish
            is_ember = command.include?("ember-cli")
            @ember_running = false if is_ember
            @unicorn_running = false unless is_ember
            GLib::Idle.add do
              update_tab_labels if @notebook
              false
            end
          rescue => e
            puts "DEBUG: Error in monitor thread: #{e.message}" if OPTIONS[:debug]
          end
        end

      # Clear the buffer before starting
      buffer = command.include?("ember-cli") ? @ember_output : @unicorn_output
      buffer.clear
      
      # Add a start message to the buffer
      timestamp = Time.now.strftime("%H:%M:%S")
      buffer << "#{timestamp} - Starting #{command}...\n"
      
      # Force immediate GUI update
      GLib::Idle.add do
        update_all_views
        false
      end

      # Monitor stdout
      Thread.new do
        begin
          while line = stdout.gets
            buffer = command.include?("ember-cli") ? @ember_output : @unicorn_output
            puts "[OUT] #{line}" if OPTIONS[:debug]
            
            # Add to buffer with size management
            buffer << line
            
            # Print buffer size for debugging
            if OPTIONS[:debug]
              puts "DEBUG: Added to buffer: #{line.inspect}"
              if buffer.size % 10 == 0
                puts "DEBUG: Buffer size now: #{buffer.size}"
              end
            end
            
            # Trim if needed
            if buffer.size > BUFFER_SIZE
              buffer.shift(buffer.size - BUFFER_SIZE)
            end
            
            # Force GUI update on main thread
            GLib::Idle.add do
              update_all_views
              false
            end
            
            # Also publish to pipe for --attach mode in background
            publish_to_pipe(line, process: command.include?("ember-cli") ? :ember : :unicorn, stream: :stdout)
          end
        rescue => e
          puts "DEBUG: Error in stdout thread: #{e.message}" if OPTIONS[:debug]
          puts e.backtrace.join("\n") if OPTIONS[:debug]
          
          # Add error to buffer for visibility
          buffer = command.include?("ember-cli") ? @ember_output : @unicorn_output
          error_msg = "ERROR: Exception in stdout thread: #{e.message}\n"
          buffer << error_msg
          
          # Force GUI update
          GLib::Idle.add do
            update_all_views
            false
          end
        end
      end

      # Monitor stderr
      Thread.new do
        begin
          while line = stderr.gets
            buffer = command.include?("ember-cli") ? @ember_output : @unicorn_output
            puts "[ERR] #{line}" if OPTIONS[:debug]
            
            # Format error line
            error_line = "E: #{line}"
            
            # Add to buffer with size management
            buffer << error_line
            
            # Print buffer size for debugging
            if OPTIONS[:debug]
              puts "DEBUG: Added to buffer: #{error_line.inspect}"
              if buffer.size % 10 == 0
                puts "DEBUG: Buffer size now: #{buffer.size}"
              end
            end
            
            # Trim if needed
            if buffer.size > BUFFER_SIZE
              buffer.shift(buffer.size - BUFFER_SIZE)
            end
            
            # Force GUI update on main thread
            GLib::Idle.add do
              update_all_views
              false
            end
            
            # Also publish to pipe for --attach mode in background
            publish_to_pipe(error_line, process: command.include?("ember-cli") ? :ember : :unicorn, stream: :stderr)
          end
        rescue => e
          puts "DEBUG: Error in stderr thread: #{e.message}" if OPTIONS[:debug]
          puts e.backtrace.join("\n") if OPTIONS[:debug]
          
          # Add error to buffer for visibility
          buffer = command.include?("ember-cli") ? @ember_output : @unicorn_output
          error_msg = "ERROR: Exception in stderr thread: #{e.message}\n"
          buffer << error_msg
          
          # Force GUI update
          GLib::Idle.add do
            update_all_views
            false
          end
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
            system("i3-msg '[id=#{@status_window.window.xid}] move workspace current'")
            system("i3-msg '[id=#{@status_window.window.xid}] focus'")
          end
        end
        
        # Force an update of the views even if window is already visible
        GLib::Idle.add do
          update_all_views
          false
        end
        
        return
      end

      # Clean up any existing window and notebook
      if @status_window
        puts "DEBUG: Destroying existing status window" if OPTIONS[:debug]
        @notebook = nil # Clear notebook reference
        @ember_view = nil
        @unicorn_view = nil
        @ember_label = nil
        @unicorn_label = nil
        @status_window.destroy
        @status_window = nil
      end

      # Create new window and components
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

      # Create notebook only if it doesn't exist
      puts "DEBUG: Creating notebook" if OPTIONS[:debug]
      @notebook = Gtk::Notebook.new

      # Only create views if they don't exist
      if @ember_view.nil?
        puts "DEBUG: Creating ember view" if OPTIONS[:debug]
        @ember_view = create_log_view(@ember_output)
        @ember_label = create_status_label("Ember CLI", @ember_running)
        @notebook.append_page(@ember_view, @ember_label)
      end

      if @unicorn_view.nil?
        puts "DEBUG: Creating unicorn view" if OPTIONS[:debug]
        @unicorn_view = create_log_view(@unicorn_output)
        @unicorn_label = create_status_label("Unicorn", @unicorn_running)
        @notebook.append_page(@unicorn_view, @unicorn_label)
      end

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
      
      # Basic validity checks
      return unless @status_window && !@status_window.destroyed?
      return unless @ember_view && @unicorn_view
      
      begin
        # Always update both views for now to ensure content is displayed
        if @ember_view && !@ember_view.destroyed? && @ember_view.child && !@ember_view.child.destroyed?
          update_log_view(@ember_view.child, @ember_output)
        end
        
        if @unicorn_view && !@unicorn_view.destroyed? && @unicorn_view.child && !@unicorn_view.child.destroyed?
          update_log_view(@unicorn_view.child, @unicorn_output)
        end
        
        # Process any pending GTK events
        while Gtk.events_pending?
          Gtk.main_iteration_do(false)
        end
      rescue => e
        puts "DEBUG: Error in update_all_views: #{e.message}" if OPTIONS[:debug]
        puts e.backtrace.join("\n") if OPTIONS[:debug]
      end
    end

    def create_log_view(buffer)
      puts "DEBUG: create_log_view called for #{buffer == @ember_output ? 'ember' : 'unicorn'}" if OPTIONS[:debug]
      
      # Create a scrolled window to contain the text view
      scroll = Gtk::ScrolledWindow.new
      
      # Create a simple text view with minimal configuration
      text_view = Gtk::TextView.new
      text_view.editable = false
      text_view.cursor_visible = false
      text_view.wrap_mode = :word
      
      # Use a fixed-width font
      text_view.monospace = true
      
      # Set colors - white text on black background
      text_view.override_background_color(:normal, Gdk::RGBA.new(0, 0, 0, 1))
      text_view.override_color(:normal, Gdk::RGBA.new(1, 1, 1, 1))
      
      # Set font size explicitly
      font_desc = Pango::FontDescription.new
      font_desc.family = "Monospace"
      font_desc.size = 12 * Pango::SCALE
      text_view.override_font(font_desc)
      
      # Set initial text
      text_view.buffer.text = "Loading log data...\n"
      
      # Add the text view to the scrolled window
      scroll.add(text_view)
      
      # Set up a timer to update the view more frequently
      @view_timeouts ||= {}
      timeout_id = GLib::Timeout.add(250) do
        if text_view.destroyed? || scroll.destroyed?
          @view_timeouts.delete(text_view.object_id)
          false # Stop the timer
        else
          begin
            update_log_view(text_view, buffer)
          rescue => e
            puts "DEBUG: Error updating log view: #{e.message}" if OPTIONS[:debug]
          end
          true # Continue the timer
        end
      end
      
      # Store the timeout ID for cleanup
      @view_timeouts[text_view.object_id] = timeout_id
      
      # Clean up when the view is destroyed
      text_view.signal_connect("destroy") do
        if id = @view_timeouts.delete(text_view.object_id)
          GLib::Source.remove(id) rescue nil
        end
      end
      
      # Do an initial update
      update_log_view(text_view, buffer)
      
      # Return the scrolled window
      scroll
    end

    # We're not using ANSI tags anymore since we're stripping ANSI codes

    def update_log_view(text_view, buffer)
      puts "DEBUG: update_log_view called" if OPTIONS[:debug]
      
      # Basic validity checks
      return if text_view.nil? || text_view.destroyed?
      return if text_view.buffer.nil? || text_view.buffer.destroyed?

      # Debug buffer content
      if OPTIONS[:debug]
        puts "DEBUG: Buffer size: #{buffer.size}"
        if buffer.size > 0
          puts "DEBUG: First line: #{buffer.first.inspect}"
          puts "DEBUG: Last line: #{buffer.last.inspect}"
        end
      end

      # If buffer is empty, add a placeholder message
      if buffer.empty?
        buffer << "No log data available yet. Start Discourse to see logs.\n"
      end

      # Completely replace the buffer content with all lines
      begin
        # Make a local copy of the buffer to avoid race conditions
        buffer_copy = buffer.dup
        
        # Join all buffer lines into a single string
        all_content = buffer_copy.join("")
        
        # Strip ANSI codes
        clean_content = all_content.gsub(/\e\[[0-9;]*[mK]/, '')
        
        # Always update the content to ensure it's displayed
        text_view.buffer.text = clean_content
        
        puts "DEBUG: Updated buffer text (#{clean_content.length} chars)" if OPTIONS[:debug]
        
        # Scroll to bottom
        adj = text_view&.parent&.vadjustment
        if adj
          adj.value = adj.upper - adj.page_size
        end
        
        # Process any pending GTK events to ensure UI updates
        while Gtk.events_pending?
          Gtk.main_iteration_do(false)
        end
      rescue => e
        puts "DEBUG: Error updating text view: #{e.message}" if OPTIONS[:debug]
        puts e.backtrace.join("\n") if OPTIONS[:debug]
        
        # Try a fallback approach
        begin
          text_view.buffer.text = "Error displaying log. See console for details.\n#{e.message}"
        rescue => e2
          puts "DEBUG: Even fallback approach failed: #{e2.message}" if OPTIONS[:debug]
        end
      end
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

        # Set up signal handling for Ctrl+C
        Signal.trap("INT") do
          puts "Received interrupt signal, shutting down..."
          exit 0
        end
        
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
          reader = Thread.new do
            # Set thread abort on exception
            Thread.current.abort_on_exception = true
            
            begin
              while true
                begin
                  # Use non-blocking read with timeout
                  ready = IO.select([pipe], nil, nil, 0.1)
                  if ready && ready[0].include?(pipe)
                    line = pipe.gets
                    if line
                      puts line
                      STDOUT.flush
                    end
                  end
                rescue IOError, Errno::EBADF => e
                  puts "DEBUG: Pipe read error: #{e.message}" if OPTIONS[:debug]
                  break
                end

                # Check if pipe still exists
                unless File.exist?(PIPE_PATH)
                  puts "Pipe was deleted, exiting."
                  exit 0
                end
                
                # Small sleep to prevent CPU hogging
                sleep 0.01
              end
            rescue EOFError, IOError
              puts "Pipe closed, exiting."
              exit 0
            end
          end
          
          # Set up non-blocking notifier processing
          # Instead of notifier.run which blocks indefinitely, use a loop with timeout
          while true
            # Process any pending inotify events, with timeout
            notifier.process
            
            # Sleep briefly to prevent CPU hogging
            sleep 0.1
          end
        rescue Errno::ENOENT
          puts "Pipe doesn't exist, exiting."
          exit 1
        rescue Interrupt
          puts "Interrupted, exiting."
          exit 0
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

    # Queue for pipe messages to avoid blocking
    def initialize_pipe_queue
      @pipe_queue = Queue.new
      @pipe_thread = Thread.new do
        loop do
          begin
            msg = @pipe_queue.pop
            break if msg == :exit
            
            if File.exist?(PIPE_PATH)
              begin
                # Use non-blocking write with timeout
                Timeout.timeout(0.5) do
                  File.open(PIPE_PATH, "w") do |f|
                    f.puts(msg)
                    f.flush
                  end
                end
              rescue Timeout::Error
                puts "Timeout writing to pipe" if OPTIONS[:debug]
              rescue Errno::EPIPE, IOError => e
                puts "Error writing to pipe: #{e}" if OPTIONS[:debug]
              end
            end
          rescue => e
            puts "Error in pipe thread: #{e}" if OPTIONS[:debug]
          end
          
          # Small sleep to prevent CPU hogging
          sleep 0.01
        end
      end
    end
    
    def publish_to_pipe(msg, process: nil, stream: nil)
      source_info = "[#{process || 'unknown'}:#{stream || 'unknown'}]"
      puts "Publish to pipe #{source_info}: #{msg}" if OPTIONS[:debug]
      
      @pipe_queue.push(msg) if @pipe_queue
    end

    def handle_command(cmd)
      puts "Received command: #{cmd}" if OPTIONS[:debug]
    end
  end
end
