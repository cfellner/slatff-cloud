# Contributing

## Before a pull request

```sh
bash model-gateway/tests/run.sh
bash ide-bridge/tests/run.sh
```

Both must pass. CI runs them too. They need Python 3 with `aiohttp` and `PyJWT[crypto]`.

## Rules

- No secrets in commits: no `.env`, tokens, keys, passwords or real user names.
- Use `example.org` and the demo users (carol, alice, bob) in docs and tests.
- Docs: short, plain facts. Enough to reproduce and understand the intent.
- A feature counts as working when it is ticked in [docs/TESTING.md](docs/TESTING.md) with a date.
- One topic per pull request.

## Testing on Windows or Linux

The IDE bridge is tested on macOS only. Reports for Visual Studio, Qt Creator and other IDEs
are welcome: open an issue with the "IDE test report" template. Steps: [docs/IDES.md](docs/IDES.md).

## Bugs

Open an issue with what you ran, what you expected, and what happened (log lines, tokens removed).
