#!/usr/bin/env bash
# IDE bridge on the server's own Mac (docs/IDE-BRIDGE.md), addresses taken from .env.
# On another computer (Windows, Linux, another Mac) copy ide-bridge/bridge.py and run
#   python3 bridge.py configure --issuer https://<ID_HOST>/realms/slatff --gateway https://<AI_HOST>/gateway/v1 --ide <name>
#   bash scripts/ide-bridge.sh login [private] | serve | logout | key [new] | agent install|uninstall|status
#   [IDE=xcode|visualstudio|qtcreator]
cd "$(dirname "$0")/.."
val() { grep "^$1=" .env | cut -d= -f2-; }
export SLATFF_ISSUER="https://$(val ID_HOST)/realms/slatff"
export SLATFF_GATEWAY="https://$(val AI_HOST)/gateway/v1"
export SLATFF_IDE="${IDE:-xcode}"
exec /usr/bin/python3 ide-bridge/bridge.py "${@:-serve}"
