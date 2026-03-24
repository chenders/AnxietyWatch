# AGENTS.md

- If using XcodeBuildMCP, use the installed XcodeBuildMCP skill before calling XcodeBuildMCP tools.
- After writing or modifying code, run the relevant tests to verify your changes:
  - iOS: `xcodebuild test -scheme AnxietyWatch -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:AnxietyWatchTests`
  - Server: `cd server && python -m pytest tests/`
- All new or changed code must include tests. Use Swift Testing (`@Test`, `#expect()`) for iOS tests.
