#!/bin/bash
# Creates the Python environment of the control SoC generator: litex_soc/.venv with
# migen and LiteX as pinned in requirements.txt. build.sh uses it by default
# (LITEX_PYTHON overrides it).
#
# Usage: litex_soc/setup_venv.sh [python3]

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${1:-python3}"

[ -x "$HERE/.venv/bin/python" ] || "$PYTHON" -m venv "$HERE/.venv"
"$HERE/.venv/bin/python" -m pip install --upgrade pip
"$HERE/.venv/bin/python" -m pip install -r "$HERE/requirements.txt"
"$HERE/.venv/bin/python" -c "import migen, litex; print('litex_soc/.venv ready')"
