# Discourse Systray

A system tray application for managing local Discourse development instances.

## Installation

```bash
gem install discourse-systray
```

## Usage

Simply run:

```bash
discourse-systray
```

Optional flags:
- `--debug`: Enable debug mode
- `--path PATH`: Set Discourse path

### Features

- Start/Stop Discourse development environment from system tray
- Monitor Ember CLI and Unicorn server status
- View real-time logs with ANSI color support
- Status indicators for running services
- Clean process management and graceful shutdown

### System Tray Menu

- **Start Discourse**: Launches both Ember CLI and Unicorn server
- **Stop Discourse**: Gracefully stops all running processes
- **Show Status**: Opens log viewer window
- **Quit**: Exits application and cleans up processes

### Requirements

- Ruby >= 2.6.0
- GTK3
- Discourse development environment

## Development

After checking out the repo, run `bundle install` to install dependencies.

To install this gem onto your local machine, run:
```bash
gem build discourse-systray.gemspec
gem install ./discourse-systray-0.1.0.gem
```

## License

The gem is available as open source under the terms of the MIT License.
