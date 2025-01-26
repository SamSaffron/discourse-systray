require "gtk3"
require "open3"
require "optparse"
require "timeout"
require "fileutils"
require "json"

class DiscourseSystemTray
  CONFIG_DIR = File.expand_path("~/.config/discourse-systray")
  CONFIG_FILE = File.join(CONFIG_DIR, "config.json")
  OPTIONS = { debug: false, path: nil }

  def self.load_or_prompt_config
    OptionParser
      .new do |opts|
        opts.banner = "Usage: systray.rb [options]"
        opts.on("--debug", "Enable debug mode") { OPTIONS[:debug] = true }
        opts.on("--path PATH", "Set Discourse path") { |p| OPTIONS[:path] = p }
        opts.on("--console", "Enable console mode") { OPTIONS[:console] = true }
        opts.on("--attach", "Attach to existing systray") { OPTIONS[:attach] = true }
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
  BUFFER_SIZE = 2000

  def initialize
    @discourse_path = self.class.load_or_prompt_config
    @indicator = Gtk::StatusIcon.new
    @indicator.pixbuf =
      GdkPixbuf::Pixbuf.new(
        file: File.join(File.dirname(__FILE__), "../../assets/discourse.png")
      )
    @indicator.tooltip_text = "Discourse Manager"
    @running = false
    @ember_output = []
    @unicorn_output = []
    @processes = {}
    @ember_running = false
    @unicorn_running = false
    # Maintain line offset counters
    @ember_line_count = 0
    @unicorn_line_count = 0
    @status_window = nil

    # Create right-click menu
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
    return start_console_process(command) if console
    stdin, stdout, stderr, wait_thr = Open3.popen3(command)

    # Create a monitor thread that will detect if process dies
    monitor_thread =
      Thread.new do
        wait_thr.value # Wait for process to finish
        is_ember = command.include?("ember-cli")
        @ember_running = false if is_ember
        @unicorn_running = false unless is_ember
        GLib::Idle.add do
          update_tab_labels if @notebook
          false
        end
      end

    # Monitor stdout - send to both console and UX buffer
    Thread.new do
      while line = stdout.gets
        buffer = command.include?("ember-cli") ? @ember_output : @unicorn_output
        puts line if OPTIONS[:console]  # Send to console
        puts "[OUT] #{line}" if OPTIONS[:debug]
        buffer << line
        buffer.shift if buffer.size > BUFFER_SIZE
        # Force GUI update
        GLib::Idle.add do
          update_all_views
          false
        end
      end
    end

    # Monitor stderr - send to both console and UX buffer
    Thread.new do
      while line = stderr.gets
        buffer = command.include?("ember-cli") ? @ember_output : @unicorn_output
        STDERR.puts line if OPTIONS[:console]  # Send to console
        puts "[ERR] #{line}" if OPTIONS[:debug]
        buffer << line
        buffer.shift if buffer.size > BUFFER_SIZE
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
    if @status_window&.visible?
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
      @status_window.destroy
      @status_window = nil
    end

    @status_window = Gtk::Window.new("Discourse Status")
    @status_window.set_wmclass("discourse-status", "Discourse Status")

    # Load saved geometry or use defaults
    config = self.class.load_config
    if config["window_geometry"]
      geo = config["window_geometry"]
      @status_window.move(geo["x"], geo["y"])
      @status_window.resize(geo["width"], geo["height"])
    else
      @status_window.set_default_size(800, 600)
      @status_window.window_position = :center
    end
    @status_window.type_hint = :dialog
    @status_window.set_role("discourse-status-dialog")

    # Handle window destruction and hide
    @status_window.signal_connect("delete-event") do
      save_window_geometry
      @status_window.hide
      true # Prevent destruction
    end

    # Save position and size when window is moved or resized
    @status_window.signal_connect("configure-event") do
      save_window_geometry
      false
    end

    @notebook = Gtk::Notebook.new

    @ember_view = create_log_view(@ember_output)
    @ember_label = create_status_label("Ember CLI", @ember_running)
    @notebook.append_page(@ember_view, @ember_label)

    @unicorn_view = create_log_view(@unicorn_output)
    @unicorn_label = create_status_label("Unicorn", @unicorn_running)
    @notebook.append_page(@unicorn_view, @unicorn_label)

    @status_window.add(@notebook)
    @status_window.show_all
  end

  def update_all_views
    return unless @status_window && !@status_window.destroyed?
    return unless @ember_view && @unicorn_view
    return unless @ember_view.child && @unicorn_view.child
    return if @ember_view.destroyed? || @unicorn_view.destroyed?
    return if @ember_view.child.destroyed? || @unicorn_view.child.destroyed?

    begin
      if @ember_view.visible? && @ember_view.child.visible?
        update_log_view(@ember_view.child, @ember_output)
      end
      if @unicorn_view.visible? && @unicorn_view.child.visible?
        update_log_view(@unicorn_view.child, @unicorn_output)
      end
    rescue StandardError => e
      puts "Error updating views: #{e}" if OPTIONS[:debug]
    end
  end

  def create_log_view(buffer)
    scroll = Gtk::ScrolledWindow.new
    text_view = Gtk::TextView.new
    text_view.editable = false
    text_view.wrap_mode = :word

    # Set white text on black background
    text_view.override_background_color(:normal, Gdk::RGBA.new(0, 0, 0, 1))
    text_view.override_color(:normal, Gdk::RGBA.new(1, 1, 1, 1))

    # Create text tags for colors
    _tag_table = text_view.buffer.tag_table
    create_ansi_tags(text_view.buffer)

    # Initial text
    update_log_view(text_view, buffer)

    # Store timeouts in instance variable for proper cleanup
    @view_timeouts ||= {}

    # Set up periodic refresh with validity check
    timeout_id =
      GLib::Timeout.add(1000) do
        if text_view&.parent.nil? || !text_view&.parent&.visible?
          @view_timeouts.delete(text_view.object_id)
          false # Stop the timeout if view is destroyed
        else
          begin
            update_log_view(text_view, buffer)
          rescue StandardError
            nil
          end
          true # Keep the timeout active
        end
      end

    @view_timeouts[text_view.object_id] = timeout_id

    # Clean up timeout when view is destroyed
    text_view.signal_connect("destroy") do
      if timeout_id = @view_timeouts.delete(text_view.object_id)
        begin
          GLib::Source.remove(timeout_id)
        rescue StandardError
          nil
        end
      end
    end

    scroll.add(text_view)
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
      "37" => "#ffffff" # White
    }.each do |code, color|
      buffer.create_tag("ansi_#{code}", foreground: color)
    end

    # Add more tags for bold, etc
    buffer.create_tag("bold", weight: :bold)
  end

  def update_log_view(text_view, buffer)
    return if buffer.empty? || text_view.nil? || text_view.destroyed?
    return unless text_view.visible? && text_view.parent&.visible?
    return if text_view.buffer.nil? || text_view.buffer.destroyed?

    # Determine which offset counter to use
    offset_var = (buffer.equal?(@ember_output) ? :@ember_line_count : :@unicorn_line_count)
    current_offset = instance_variable_get(offset_var)

    # Don't call if we've already processed all lines or if text_view is invalid
    return if buffer.size <= current_offset
    return if text_view.nil? || text_view.destroyed?
    return unless text_view.visible? && text_view.parent&.visible?
    return if text_view.buffer.nil? || text_view.buffer.destroyed?

    adj = text_view&.parent&.vadjustment
    was_at_bottom = (adj && adj.value >= adj.upper - adj.page_size - 50)
    old_value = adj ? adj.value : 0

    # Process only the new lines
    new_lines = buffer[current_offset..-1]
    new_lines.each do |line|
      ansi_segments = line.scan(/\e\[([0-9;]*)m([^\e]*)|\e\[K([^\e]*)|([^\e]+)/)
      segment_start_iter = text_view.buffer.end_iter.dup

      ansi_segments.each do |codes, text_part, clear_part, plain|
        chunk = text_part || clear_part || plain.to_s
        chunk_start_iter = text_view.buffer.end_iter
        text_view.buffer.insert(chunk_start_iter, chunk)

        # For each ANSI code, apply tags
        if codes
          codes.split(";").each do |code|
            case code
            when "1"
              text_view.buffer.apply_tag("bold", chunk_start_iter, text_view.buffer.end_iter)
            when "31".."37"
              text_view.buffer.apply_tag("ansi_#{code}", chunk_start_iter, text_view.buffer.end_iter)
            end
          end
        end
      end
    end

    # Update our offset counter
    instance_variable_set(offset_var, buffer.size)

    # Restore scroll position
    if adj
      if was_at_bottom
        adj.value = adj.upper - adj.page_size
      else
        adj.value = old_value
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
        buffer = command.include?("ember-cli") ? @ember_output : @unicorn_output
        print line
        buffer << line
        buffer.shift if buffer.size > BUFFER_SIZE
      end
    end

    # Pipe stderr to console and add to buffer
    Thread.new do
      while line = stderr.gets
        buffer = command.include?("ember-cli") ? @ember_output : @unicorn_output
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

  def run
    if OPTIONS[:attach]
      pid_file = "/tmp/discourse_systray.pid"
      if File.exist?(pid_file)
        existing_pid = File.read(pid_file).strip.to_i
        if system("ps -p #{existing_pid} > /dev/null 2>&1")
          puts "Attaching to existing systray with PID=#{existing_pid}"
          puts "i3 doesn't support focusing by PID. Window focus will not be changed."
          exit 0
        else
          puts "No running systray found at PID=#{existing_pid}, starting new instance..."
        end
      else
        puts "No systray PID file found, starting new instance..."
      end
    end

    if OPTIONS[:console]
      Dir.chdir(@discourse_path) do
        ps = []
        ps << start_process("bin/ember-cli", console: true)
        ps << start_process("bin/unicorn", console: true)
        # Wait for both processes to finish
        ps.each { |p| p[:thread].join }
      end
    else
      pid_file = "/tmp/discourse_systray.pid"
      File.write(pid_file, Process.pid) rescue nil
      Gtk.main
    end
  end
end
