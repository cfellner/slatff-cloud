#!/usr/bin/env python3
"""One-off: wire step 6 (IDE bridge) into CI, TESTING.md, README, DELEGATION.md and XCODE links.
Safe to re-run. Run from the repo root: python3 scripts/apply-ide-docs.py"""
from pathlib import Path
def edit(path, fn):
    p = Path(path); s = p.read_text(); n = fn(s)
    print(("updated " if n != s else "unchanged ") + path)
    if n != s: p.write_text(n)
def ci(s):
    if "ide-bridge/tests/run.sh" in s: return s
    a = "          bash model-gateway/tests/run.sh\n"
    s = s.replace(a, a + "      - name: IDE bridge tests (fake Keycloak device flow, both API styles, refresh, revocation)\n"
                         "        run: bash ide-bridge/tests/run.sh\n", 1)
    return s.rstrip("\n") + """

  bridge-secret-store:
    name: IDE bridge secret store (${{ matrix.os }})
    strategy:
      matrix:
        os: [windows-latest, ubuntu-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: "3.12"
      - name: save, load and delete a token in the OS secret store
        run: python ide-bridge/bridge.py selftest-store
"""
def testing(s):
    if "IDE bridge (docs/IDE-BRIDGE.md" in s: return s
    return s.rstrip("\n") + """

IDE bridge (docs/IDE-BRIDGE.md, step 6):

- [x] Offline: `bash ide-bridge/tests/run.sh` passes 28 checks (25 Nov 2026, fake Keycloak)
- [ ] CI: `bridge.py selftest-store` passes on Windows (DPAPI) and Linux
- [ ] `bash scripts/mac-step6-ide-bridge.sh`: all checks PASS
- [ ] `bridge.py login` signs in with the device code on macOS (Keychain)
- [ ] Xcode: provider added, models listed, answer received, audit shows user, client ide-bridge, ide xcode
- [ ] Visual Studio 2026 (Windows): OpenAI or Ollama custom endpoint works the same way
- [ ] Qt Creator (Qt AI Assistant): Ollama-style URL works the same way
- [ ] bob (no ai-user role) gets no models in any IDE
- [ ] Session ended in Keycloak: next refresh fails, bridge tells the user to sign in again
"""
def readme(s):
    if "docs/IDE-BRIDGE.md" in s: return s
    return s.rstrip("\n") + "\n- IDEs as governed clients: Xcode, Visual Studio, Qt Creator (step 6, offline-tested, live run pending): [docs/IDE-BRIDGE.md](docs/IDE-BRIDGE.md); other IDEs: [docs/IDES.md](docs/IDES.md)\n"
def deleg(s):
    return s.replace("## Next: step 6, RFC 8693 delegation semantics", "## Next: step 7, RFC 8693 delegation semantics")
edit(".github/workflows/check.yml", ci)
edit("docs/TESTING.md", testing)
edit("README.md", readme)
edit("docs/DELEGATION.md", deleg)
