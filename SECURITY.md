# Security policy

UndoTurn reads and writes files in your projects and edits agent configuration files. Treat bugs that can lose or expose data as security issues.

## Report a vulnerability

Do not open a public issue.
Use GitHub private vulnerability reporting: **Security** tab, then **Report a vulnerability**.

You get a first answer within 7 days.

## Supported versions

Only the latest release receives fixes. Fixes go to the `main` branch first.

## In scope

- Data loss caused by undo, redo, goto, revert, restore or garbage collection.
- Stored file contents or prompts readable by other local users.
- Hook installation that breaks or weakens an agent's configuration.
