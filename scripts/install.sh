#!/bin/bash
# pg-aje installation script
# Version: v0.1.0
# Author: Haiwen Yin

set -euo pipefail

VERSION="v0.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."

echo "========================================"
echo "pg-aje Installer ${VERSION}"
echo "========================================"

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: root privileges required. Run: sudo bash scripts/install.sh"
    exit 1
fi

PG_BIN=""
for candidate in /usr/local/pgsql/bin/pg_config; do
    if [ -x "$candidate" ]; then
        PG_BIN="$candidate"
        break
    fi
done

if [ -z "$PG_BIN" ]; then
    if command -v pg_config >/dev/null 2>&1; then
        PG_BIN="$(command -v pg_config)"
    else
        echo "Error: pg_config not found. Ensure PostgreSQL 18+ is installed."
        exit 1
    fi
fi

PG_VERSION=$("$PG_BIN" --version | awk '{print $2}' | cut -d. -f1)
if [ "$PG_VERSION" -lt 18 ]; then
    echo "Error: PostgreSQL ${PG_VERSION} detected. Version 18+ required."
    exit 1
fi

echo "PostgreSQL version: $("$PG_BIN" --version)"

echo ""
echo "PostgreSQL environment verified."
echo ""
echo "Next steps:"
echo ""
echo "1. Create database functions in your database:"
echo "   psql -d YOUR_DB -f ${SCRIPT_DIR}/sql/install.sql"
echo ""
echo "2. Create an AJE view:"
echo "   psql -d YOUR_DB -c \"SELECT aje.create_view('my_dv', 'my_table');\""
echo ""
echo "3. Test:"
echo "   psql -d YOUR_DB -f ${SCRIPT_DIR}/scripts/test/test_aje.sql"
echo ""
echo "4. List views:"
echo "   psql -d YOUR_DB -c \"SELECT * FROM aje.list_views();\""
echo ""
