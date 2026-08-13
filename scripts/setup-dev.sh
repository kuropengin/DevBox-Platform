#!/usr/bin/env bash
# DevBox Platform - Development Setup Script
# Sets up local development environment (non-root)

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

info "Installing dependencies..."
npm install

info "Building packages..."
npm run build:packages

if [[ ! -f .env ]]; then
  cp .env.example .env
  info "Created .env from .env.example"
fi

success "Development environment ready!"
echo ""
echo "Available commands:"
echo "  npm run build        - Build all packages"
echo "  npm test             - Run tests"
echo "  npm run test:watch   - Run tests in watch mode"
echo "  npm run lint         - Lint code"
echo "  npm run format       - Format code"
echo "  npm run typecheck    - Type check all packages"
echo ""
echo "  npm run dev -w apps/cli        - Run CLI in dev mode"
echo "  npm run dev -w apps/api        - Run API in dev mode"
echo "  npm run dev -w apps/dashboard  - Run dashboard in dev mode"
