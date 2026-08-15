# AI assistant trust boundary

The Orion sidebar assistant can run commands on the machine it is displayed on.
This document states what that means, so the boundary is a decision rather than
an accident.

## What the model can reach

`AiAssistant.qml` parses `<tool_call>` blocks out of the model's response and
dispatches them. The tools that touch the system are:

| Tool | Effect |
| --- | --- |
| `web_search`, `read_url` | `orion_search.py` fetches over the network |
| `open_app` | `shell/scripts/open_app.py` launches a desktop application |
| `caelestia_command` | runs `caelestia <subcommand> <args>` |
| `set_timer` | schedules a `notify-send` |
| screenshot tools | capture and encode a screen image |

`runAgentCommand` builds each command as an argument vector and hands it to a
`Process`. Arguments are JSON-encoded into the generated QML, so model output
cannot break out of the string and become QML. What model output *can* do is
choose which of the above tools runs, and with what arguments.

## Why this needs stating

The assistant reads web pages, and a page can contain text addressed to the
model. That makes prompt injection a live path: content fetched by `read_url`
influences the next tool call. The mitigations are:

* `orion_search.py` accepts only `http` and `https`, and refuses loopback,
  link-local, private and reserved addresses -- on the initial URL and on every
  redirect hop. Without this, a `file:///` URL would return local file contents
  into the conversation, and an `http://127.0.0.1` URL would probe local
  services. See `assert_safe_url` and `_SafeRedirectHandler`.
* `caelestia_command` can only invoke the `caelestia` CLI, not an arbitrary
  binary. Its subcommand and arguments still come from the model.
* API keys live in the system keyring via `secret-tool`, passed on stdin, and
  never appear in the process list or in `shell.json`.

## What is deliberately not mitigated

There is no per-command confirmation prompt. The assistant is a local tool
acting for the user who opened it, and confirming every tool call would make it
unusable. Treat the assistant as running with your user's privileges, because
it does.

If you point the assistant at an untrusted model endpoint, that endpoint can
run any of the tools above as you.

## When adding a tool

Adding a branch to the tool dispatcher in `AiAssistant.qml` extends this
boundary. Before doing so:

1. Pass every model-supplied value as a positional argument. Never concatenate
   one into a shell string.
2. If the tool reaches the network, route it through `fetch_url` in
   `orion_search.py` so the scheme and address checks apply.
3. If the tool writes files, confine it to a path the shell already owns.
4. Update the table above.
