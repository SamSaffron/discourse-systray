require "gtk3"
require "open3"

DISCOURSE_PATH = "/home/sam/Source/discourse"

class DiscourseSystemTray
  BUFFER_SIZE = 2000

  def initialize
    @indicator = Gtk::StatusIcon.new
    @indicator.pixbuf = GdkPixbuf::Pixbuf.new(file: "discourse.png")
    @indicator.tooltip_text = "Discourse Manager"

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
      end

      stop_item.signal_connect("activate") do
        set_icon(:stopped)
        stop_discourse
      end

      quit_item.signal_connect("activate") { Gtk.main_quit }

      @ember_output = []
      @unicorn_output = []
      @processes = {}

      # Add status menu item
      status_item = Gtk::MenuItem.new(label: "Show Status")
      menu.append(Gtk::SeparatorMenuItem.new)
      menu.append(status_item)

      status_item.signal_connect("activate") { show_status_window }

      menu.show_all
      menu.popup(nil, nil, button, time)
    end
  end

  def start_discourse
    Dir.chdir(DISCOURSE_PATH) do
      @processes[:ember] = start_process("bin/ember-cli")
      @processes[:unicorn] = start_process("bin/unicorn")
    end
  end

  def stop_discourse
    @processes.each do |name, process|
      begin
        Process.kill("TERM", process[:pid])
      rescue StandardError
        nil
      end
    end
    @processes.clear
  end

  def start_process(command)
    stdin, stdout, stderr, wait_thr = Open3.popen3(command)

    # Monitor stdout
    Thread.new do
      while line = stdout.gets
        buffer = command.include?("ember-cli") ? @ember_output : @unicorn_output
        buffer << "[OUT] #{line}"
        buffer.shift if buffer.size > BUFFER_SIZE
      end
    end

    # Monitor stderr
    Thread.new do
      while line = stderr.gets
        buffer = command.include?("ember-cli") ? @ember_output : @unicorn_output
        buffer << "[ERR] #{line}"
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

  def show_status_window
    window = Gtk::Window.new("Discourse Status")
    window.set_default_size(800, 600)

    notebook = Gtk::Notebook.new

    ember_view = create_log_view(@ember_output)
    notebook.append_page(ember_view, Gtk::Label.new("Ember CLI"))

    unicorn_view = create_log_view(@unicorn_output)
    notebook.append_page(unicorn_view, Gtk::Label.new("Unicorn"))

    window.add(notebook)
    window.show_all
  end

  def create_log_view(buffer)
    scroll = Gtk::ScrolledWindow.new
    text_view = Gtk::TextView.new
    text_view.editable = false

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
      "31" => "red",
      "32" => "green",
      "33" => "yellow",
      "34" => "blue",
      "35" => "magenta",
      "36" => "cyan",
      "37" => "white"
    }.each do |code, color|
      buffer.create_tag("ansi_#{code}", foreground: color)
    end

    # Add more tags for bold, etc
    buffer.create_tag("bold", weight: Pango::WEIGHT_BOLD)
  end

  def update_log_view(text_view, buffer)
    return if buffer.empty?

    text_view.buffer.text = ""
    iter = text_view.buffer.get_iter_at_offset(0)

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

      text_view.buffer.insert(iter, "\n")
    end

    # Scroll to bottom if near bottom
    adj = text_view.parent.vadjustment
    if adj.value >= adj.upper - adj.page_size - 50
      adj.value = adj.upper - adj.page_size
    end
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
