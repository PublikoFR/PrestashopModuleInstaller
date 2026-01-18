# Prestashop Docker Toolbox

A bash script to manage PrestaShop modules and themes in Docker environments.

## Features

- Support for both **modules** and **themes**
- Interactive menu with keyboard navigation (vim keys supported)
- Automatic backup before each operation (keeps last 5)
- Restore from backup
- Clear PrestaShop cache
- Restart Docker containers
- Build production-ready ZIP archives
- Auto-update from GitHub releases
- CLI flags for automation/scripting

## Requirements

- Docker with a running PrestaShop container
- Bash shell
- `rsync` (for theme sync)
- `zip` (for building archives)

## Setup

1. Copy the configuration example:
   ```bash
   cp .env.install.example .env.install
   ```

2. Edit `.env.install` with your settings:
   ```bash
   TYPE="module"  # or "theme"
   PRESTASHOP_PATH="/path/to/your/prestashop"
   DOCKER_CONTAINER="your_container_name"
   NAME="yourmoduleorthemename"
   ```

3. Place your module/theme folder next to `install.sh`:
   ```
   project/
   ├── install.sh
   ├── .env.install
   └── yourmodulename/
       └── yourmodulename.php   # for modules
       └── config/theme.yml     # for themes
   ```

4. Make executable:
   ```bash
   chmod +x install.sh
   ```

## Usage

### Interactive Mode

```bash
./install.sh
```

Use arrow keys (or `j`/`k`) to navigate, Enter to select, `q` or Esc to quit.

### CLI Mode (Module)

```bash
./install.sh --install      # Install / Reinstall
./install.sh --uninstall    # Uninstall
./install.sh --reinstall    # Uninstall then Reinstall
./install.sh --delete       # Delete files
./install.sh --reset        # Delete then Reinstall
```

### CLI Mode (Theme)

```bash
./install.sh --sync         # Sync files (rsync)
./install.sh --install      # Sync + Enable theme
./install.sh --delete       # Delete theme
./install.sh --reset        # Delete + Reinstall
```

### Common Options

```bash
./install.sh --restore      # Restore from backup
./install.sh --cache        # Clear cache
./install.sh --restart      # Restart Docker containers
./install.sh --zip          # Build ZIP archive
./install.sh --update-script # Check for script updates
./install.sh --help         # Show help
```

## License

MIT
