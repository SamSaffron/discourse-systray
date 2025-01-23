require "gtk3"
require "open3"
require "optparse"
require "timeout"

DISCOURSE_PATH = "/home/sam/Source/discourse"

# Parse command line options
OPTIONS = { debug: false }

OptionParser
  .new do |opts|
    opts.banner = "Usage: systray.rb [options]"
    opts.on("--debug", "Enable debug mode") { OPTIONS[:debug] = true }
  end
  .parse!

class DiscourseSystemTray
  BUFFER_SIZE = 2000

  def initialize
    @indicator = Gtk::StatusIcon.new
    @indicator.pixbuf = GdkPixbuf::Pixbuf.new(file: "discourse.png")
    @indicator.tooltip_text = "Discourse Manager"
    @running = false
    @ember_output = []
    @unicorn_output = []
    @processes = {}
    @ember_running = false
    @unicorn_running = false

    # Create right-click menu
    @indicator.signal_connect("popup-menu") do |tray, button, time|
      menu = Gtk::Menu.new

      start_item = Gtk::MenuItem.new(label: "Start Discourse")
      stop_item = Gtk::MenuItem.new(label: "Stop Discourse")
      quit_item = Gtk::MenuItem.new(label: "Quit")

      menu.append(start_item)
      menu.append(stop_item)
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

      # Add status menu item
      status_item = Gtk::MenuItem.new(label: "Show Status")
      menu.append(Gtk::SeparatorMenuItem.new)
      menu.append(status_item)

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

    Dir.chdir(DISCOURSE_PATH) do
      @processes[:ember] = start_process("bin/ember-cli")
      @ember_running = true
      @processes[:unicorn] = start_process("RAILS_ENV=development bin/unicorn -c config/unicorn.conf.rb")
      @unicorn_running = true
      update_tab_labels if @notebook
    end
  end

  def stop_discourse
    cleanup
  end

  def cleanup
    return if @processes.empty?
    
    @processes.each do |name, process|
      begin
        Process.kill("TERM", process[:pid])
        # Wait for process to finish with timeout
        Timeout.timeout(10) do
          process[:thread].join
        end
      rescue StandardError => e
        puts "Error stopping #{name}: #{e}" if OPTIONS[:debug]
      end
    end
    @processes.clear
    @ember_running = false
    @unicorn_running = false
    update_tab_labels if @notebook
  end

  def start_process(command)
    stdin, stdout, stderr, wait_thr = Open3.popen3(command)
    
    # Create a monitor thread that will detect if process dies
    monitor_thread = Thread.new do
      wait_thr.value  # Wait for process to finish
      is_ember = command.include?("ember-cli")
      @ember_running = false if is_ember
      @unicorn_running = false unless is_ember
      GLib::Idle.add do
        update_tab_labels if @notebook
        false
      end
    end

    # Monitor stdout
    Thread.new do
      while line = stdout.gets
        buffer = command.include?("ember-cli") ? @ember_output : @unicorn_output
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

    # Monitor stderr
    Thread.new do
      while line = stderr.gets
        buffer = command.include?("ember-cli") ? @ember_output : @unicorn_output
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
    window = Gtk::Window.new("Discourse Status")
    window.set_default_size(800, 600)

    @notebook = Gtk::Notebook.new

    @ember_view = create_log_view(@ember_output)
    @ember_label = create_status_label("Ember CLI", @ember_running)
    @notebook.append_page(@ember_view, @ember_label)

    @unicorn_view = create_log_view(@unicorn_output)
    @unicorn_label = create_status_label("Unicorn", @unicorn_running)
    @notebook.append_page(@unicorn_view, @unicorn_label)

    window.add(@notebook)
    window.show_all
  end

  def update_all_views
    return unless @ember_view && @unicorn_view

    update_log_view(@ember_view.child, @ember_output)
    update_log_view(@unicorn_view.child, @unicorn_output)
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

    # Set up periodic refresh
    GLib::Timeout.add(1000) do
      update_log_view(text_view, buffer)
      true # Keep the timeout active
    end

    scroll.add(text_view)
    scroll
  end

  def create_ansi_tags(buffer)
    # Basic ANSI colors
    {
      "31" => "#ff6b6b",  # Brighter red
      "32" => "#87ff87",  # Brighter green
      "33" => "#ffff87",  # Brighter yellow
      "34" => "#87d7ff",  # Brighter blue
      "35" => "#ff87ff",  # Brighter magenta
      "36" => "#87ffff",  # Brighter cyan
      "37" => "#ffffff"   # White
    }.each do |code, color|
      buffer.create_tag("ansi_#{code}", foreground: color)
    end

    # Add more tags for bold, etc
    buffer.create_tag("bold", weight: :bold)
  end

  def update_log_view(text_view, buffer)
    return if buffer.empty?

    text_view.buffer.text = ""
    iter = text_view.buffer.get_iter_at(offset: 0)

    buffer.each do |line|
      # Parse ANSI sequences
      segments = line.scan(/\e\[([0-9;]*)m([^\e]*)|\e\[K([^\e]*)|([^\e]+)/)

      segments.each do |codes, text, clear_line, plain|
        if codes
          codes
            .split(";")
            .each do |code|
              case code
              when "1"
                text_view.buffer.apply_tag("bold", iter, iter)
              when "31".."37"
                text_view.buffer.apply_tag("ansi_#{code}", iter, iter)
              end
            end
          text_view.buffer.insert(iter, text)
        elsif clear_line
          text_view.buffer.insert(iter, clear_line)
        else
          text_view.buffer.insert(iter, plain || "")
        end
      end
    end

    # Scroll to bottom if near bottom
    if text_view&.parent&.vadjustment
      adj = text_view.parent.vadjustment
      if adj.value >= adj.upper - adj.page_size - 50
        adj.value = adj.upper - adj.page_size
      end
    end
  end

  def create_status_label(text, running)
    box = Gtk::Box.new(:horizontal, 5)
    label = Gtk::Label.new(text)
    status = Gtk::Label.new
    color = running ? Gdk::RGBA.new(0.2, 0.8, 0.2, 1) : Gdk::RGBA.new(0.8, 0.2, 0.2, 1)
    status.override_color(:normal, color)
    status.text = running ? "●" : "○"
    box.pack_start(label, false, false, 0)
    box.pack_start(status, false, false, 0)
    box.show_all
    box
  end

  def update_tab_labels
    return unless @notebook
    @ember_label.children[1].text = @ember_running ? "●" : "○"
    @ember_label.children[1].override_color(:normal, 
      Gdk::RGBA.new(@ember_running ? 0.2 : 0.8, @ember_running ? 0.8 : 0.2, 0.2, 1))
    
    @unicorn_label.children[1].text = @unicorn_running ? "●" : "○"
    @unicorn_label.children[1].override_color(:normal,
      Gdk::RGBA.new(@unicorn_running ? 0.2 : 0.8, @unicorn_running ? 0.8 : 0.2, 0.2, 1))
  end

  def set_icon(status)
    icon_file = status == :running ? "discourse_running.png" : "discourse.png"
    @indicator.pixbuf = GdkPixbuf::Pixbuf.new(file: icon_file)
  end

  def run
    Gtk.main
  end
end

app = DiscourseSystemTray.new
app.run
