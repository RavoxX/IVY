# Security Policy

IVY can control apps, files and developer tools on your Mac, so we take security reports seriously.

## Reporting a vulnerability

Please **don't open a public issue** for security problems. Use GitHub's
[private vulnerability reporting](https://github.com/RavoxX/IVY/security/advisories/new) instead, and include:

- a description and the impact
- steps to reproduce (for example the spoken or typed prompt)
- the affected version or commit

You'll get an acknowledgement as soon as possible, and a fix will be coordinated before public disclosure.

## Scope

In scope, for example:

- Ways to make IVY run shell commands, AppleScript or file operations that bypass its tool validation, allowlist or confirmation
- Prompt-injection paths (web content, file names, song titles…) that trigger actions without the user's intent
- Leaks of audio, prompts or history off the device
- Issues in the local engine bridge (`EngineProcess`, `ivy_engine.py`) or the runtime installer

## Design principles

- The model never receives a shell. Tools accept validated, structured arguments only.
- High-risk actions always require explicit confirmation in the notch.
- Microphone audio is never stored after transcription. Nothing is sent to cloud AI services.
