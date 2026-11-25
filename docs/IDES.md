# IDEs: support matrix (plan)

The backend does not depend on OS or IDE. Client side: [IDE-BRIDGE.md](IDE-BRIDGE.md).

| IDE | Connection | Status |
|---|---|---|
| Xcode 27 (macOS) | Internet Hosted chat provider, `http://127.0.0.1:11435`, header `x-api-key` | Works (25 Nov 2026) |
| Visual Studio 2026 (Windows) | Copilot Bring Your Own Model (preview): custom OpenAI or Ollama endpoint; works without GitHub sign-in | Testers wanted |
| Qt Creator | Qt AI Assistant (commercial): custom / Ollama LLM. QodeAssist (open source, OpenAI-compatible) is being wound down | Testers wanted |
| PyCharm | AI Assistant: provider "OpenAI-compatible", URL + key; no custom headers | Not tested |
| VS Code | Copilot Chat: Custom Endpoint (1.122+), no GitHub sign-in needed; admins can disable via Copilot BYOK policy | Not tested |
| Cursor | Requests go through Cursor's servers; endpoint must be public | Not suitable |
| Qoder | Custom OpenAI / Anthropic-compatible provider; Repo Wiki always uses Qoder cloud | Not tested |

## Test per IDE

1. Provider added, models listed (note whether there is an API key field).
2. Prompt answered; audit shows user, `ide-bridge`, IDE label.
3. BOARD-ONLY prompt refused for an ai-user.
4. Session ended in Keycloak: next request fails, bridge asks for sign-in.
5. Note which features still use the vendor cloud.

## Testers wanted

Windows and Linux are not tested by the maintainer. If you run Visual Studio, Qt Creator or
another IDE from the table, please open an issue with:

- OS, IDE and version
- `python bridge.py selftest-store` output
- provider settings used (screenshot of the dialog, key blanked)
- result of the four tests above
- relevant `bridge:` log lines and gateway audit lines (no tokens)
