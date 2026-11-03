# WindowKeeper

Drive the app with `windowkeeper` (the app binary; `windowkeeper help`). See `.claude/skills/windowkeeper/SKILL.md`. Commands live in
`Sources/WindowKeeper/Agent/AgentCommands.swift`; test them on a Debug build (`swift build`) with `APP_STORE=/tmp/<name>`,
which starts a test copy on its own profiles, settings and log that never moves windows (Release builds ignore it).
