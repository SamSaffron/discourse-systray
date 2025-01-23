# Discourse System Tray

A GTK3-based system tray application for managing local Discourse development instances.

## Features

- Start/Stop Discourse development environment from system tray
- Monitor Ember CLI and Unicorn server status
- View real-time logs with ANSI color support
- Status indicators for running services
- Clean process management and graceful shutdown

## Requirements

- Ruby
- GTK3
- Discourse development environment

## Installation

1. Install required gems:
```bash
bundle install
```

2. Run the application and select your Discourse development directory when prompted, or specify it via command line:
```bash
ruby systray.rb --path /path/to/discourse
```

## Usage

Run the application:
```bash
ruby systray.rb
```

Optional debug mode:
```bash
ruby systray.rb --debug
```

### System Tray Menu

- **Start Discourse**: Launches both Ember CLI and Unicorn server
- **Stop Discourse**: Gracefully stops all running processes
- **Show Status**: Opens log viewer window
- **Quit**: Exits application and cleans up processes

### Status Window

- Real-time log viewing for both Ember CLI and Unicorn
- Status indicators show running state of each service
- Auto-scrolling logs with ANSI color support

## Icons

- Default icon: Discourse is stopped
- Green icon: Discourse is running
