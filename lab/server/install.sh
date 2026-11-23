#!/bin/bash
# Установка ra-lab без root: копия в ~/.local/share/ra-lab, обёртка ~/.local/bin/ra-lab, состояние ~/.local/state/ra-lab (0700).
# sshd, authorized_keys, сеть и службы не трогает.
set -euo pipefail
src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
share="$HOME/.local/share/ra-lab"
mkdir -p "$share" "$HOME/.local/bin" "$HOME/.local/state/ra-lab"
chmod 700 "$HOME/.local/state/ra-lab"
install -m 0644 "$src/ra_lab.py" "$share/ra_lab.py"
printf '#!/bin/sh\nexec python3 "$HOME/.local/share/ra-lab/ra_lab.py" "$@"\n' > "$HOME/.local/bin/ra-lab"
chmod 755 "$HOME/.local/bin/ra-lab"
echo "ra-lab установлен: $HOME/.local/bin/ra-lab"
