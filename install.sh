#!/bin/bash

# Server Storage Installation Script
# Usage: curl -fsSL https://raw.githubusercontent.com/vdohide-core/server-storage/main/install.sh | sudo -E bash -s -- [OPTIONS]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
PORT="8888"
MONGODB_URI=""
STORAGE_ID=""
STORAGE_PATH="/home/files"
UNINSTALL=false

APP_NAME="server-storage"
APP_DIR="/opt/$APP_NAME"
SERVICE_NAME="server-storage"
GITHUB_REPO="vdohide-core/server-storage"
RELEASES_URL="https://github.com/$GITHUB_REPO/releases/latest/download"

# Functions
print_status()  { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --uninstall)
            UNINSTALL=true
            shift
            ;;
        -p|--port)
            PORT="$2"
            shift 2
            ;;
        --mongodb-uri)
            MONGODB_URI="$2"
            shift 2
            ;;
        --storage-id)
            STORAGE_ID="$2"
            shift 2
            ;;
        --storage-path)
            STORAGE_PATH="$2"
            shift 2
            ;;
        -h|--help)
            echo "Server Storage Installer"
            echo ""
            echo "Usage: curl -fsSL https://raw.githubusercontent.com/$GITHUB_REPO/main/install.sh | sudo -E bash -s -- [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --uninstall          Uninstall completely"
            echo "  -p, --port PORT      HTTP port (default: 8888)"
            echo "  --mongodb-uri URI    MongoDB connection string"
            echo "  --storage-id ID      Storage server identifier (required)"
            echo "  --storage-path DIR   Storage path (default: /home/files)"
            echo "  -h, --help           Show this help message"
            echo ""
            echo "Examples:"
            echo "  # Full install"
            echo "  curl -fsSL https://raw.githubusercontent.com/$GITHUB_REPO/main/install.sh | sudo -E bash -s -- \\"
            echo "      --port 8888 \\"
            echo "      --mongodb-uri \"mongodb+srv://user:pass@host/dbname\" \\"
            echo "      --storage-id \"your-storage-uuid\" \\"
            echo "      --storage-path \"/home/files\""
            echo ""
            echo "  # Uninstall entirely"
            echo "  curl -fsSL https://raw.githubusercontent.com/$GITHUB_REPO/main/install.sh | sudo bash -s -- --uninstall"
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ==========================================
# Uninstallation
# ==========================================
if [ "$UNINSTALL" = true ]; then
    print_warning "⚠️  Starting Uninstallation..."

    print_status "Stopping and disabling service..."
    systemctl stop $SERVICE_NAME 2>/dev/null || true
    systemctl disable $SERVICE_NAME 2>/dev/null || true

    if [ -f "/etc/systemd/system/$SERVICE_NAME.service" ]; then
        print_status "Removing systemd service file..."
        rm "/etc/systemd/system/$SERVICE_NAME.service"
        systemctl daemon-reload
    fi

    if [ -d "$APP_DIR" ]; then
        print_status "Removing application directory..."
        rm -rf "$APP_DIR"
    fi

    print_status "✅ Uninstallation completed successfully!"
    exit 0
fi

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    print_error "This script must be run as root (use sudo)"
    exit 1
fi

print_status "🚀 Starting Installation..."
print_status "Configuration: Port=$PORT, StoragePath=$STORAGE_PATH"

# ==========================================
# Install System Dependencies
# ==========================================
print_status "Updating system packages..."
if command -v apt-get &> /dev/null; then
    apt-get update -qq
    print_status "Installing dependencies (curl, jq)..."
    apt-get install -y -qq curl jq
elif command -v yum &> /dev/null; then
    yum install -y curl jq
elif command -v dnf &> /dev/null; then
    dnf install -y curl jq
fi

# Check required commands
print_status "Checking required commands..."
for cmd in curl jq; do
    if ! command -v $cmd &> /dev/null; then
        print_error "$cmd is not installed. Please install it and try again."
        exit 1
    fi
done
print_status "All required system commands are installed."

# ==========================================
# Application Installation
# ==========================================
print_status "📦 Installing Application..."

SERVICE_USER="root"

# Stop service if running
print_status "Stopping existing service (if running)..."
systemctl stop $SERVICE_NAME 2>/dev/null || true

# Create directory structure
print_status "Creating directory structure..."
mkdir -p "$APP_DIR"
mkdir -p "$STORAGE_PATH"
cd "$APP_DIR"

# Determine architecture
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    BINARY="linux"
elif [ "$ARCH" = "aarch64" ]; then
    BINARY="linux-arm64"
else
    print_error "Unsupported architecture: $ARCH"
    exit 1
fi

# Download binary
print_status "Downloading binary ($BINARY) from latest release..."
curl -fsSL "$RELEASES_URL/$BINARY" -o "$APP_DIR/$APP_NAME"
chmod +x "$APP_DIR/$APP_NAME"
print_status "Binary downloaded successfully."

# Create .env file
print_status "Creating .env file..."
cat > "$APP_DIR/.env" <<EOF
MONGODB_URI=$MONGODB_URI
PORT=$PORT
STORAGE_ID=$STORAGE_ID
STORAGE_PATH=$STORAGE_PATH
EOF
print_status ".env file created."
if [ -z "$MONGODB_URI" ] || [ -z "$STORAGE_ID" ]; then
    print_warning "⚠️  Please edit $APP_DIR/.env and set MONGODB_URI and STORAGE_ID before starting"
fi

# Create systemd service
print_status "Creating systemd service..."
cat > /etc/systemd/system/$SERVICE_NAME.service <<EOF
[Unit]
Description=Server Storage
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/$APP_NAME
Restart=always
RestartSec=5
EnvironmentFile=$APP_DIR/.env
Environment=PATH=/usr/bin:/bin

[Install]
WantedBy=multi-user.target
EOF
print_status "Systemd service created."

# Reload systemd and enable service
print_status "Reloading systemd daemon..."
systemctl daemon-reload
systemctl enable $SERVICE_NAME

# Start service
print_status "Starting service..."
systemctl start $SERVICE_NAME

# Verify service
sleep 2
print_status "Verifying service..."
if systemctl is-active --quiet $SERVICE_NAME; then
    echo ""
    echo "============================================"
    print_status "✅ Installation completed successfully!"
    echo "============================================"
    echo ""
    echo "  Service:      $SERVICE_NAME"
    echo "  Directory:    $APP_DIR"
    echo "  Binary:       $APP_DIR/$APP_NAME"
    echo "  Port:         $PORT"
    echo "  Storage Path: $STORAGE_PATH"
    echo ""
    echo "  Health:       http://localhost:$PORT/api/health"
    echo ""
    echo "  Commands:"
    echo "    View logs:  journalctl -u $SERVICE_NAME -f"
    echo "    Status:     systemctl status $SERVICE_NAME"
    echo "    Stop:       systemctl stop $SERVICE_NAME"
    echo "    Restart:    systemctl restart $SERVICE_NAME"
    echo "    Uninstall:  curl -fsSL https://raw.githubusercontent.com/$GITHUB_REPO/main/install.sh | sudo bash -s -- --uninstall"
    echo "============================================"
else
    print_error "❌ Application failed to start. Check logs: journalctl -u $SERVICE_NAME -e"
    exit 1
fi
