# herdr-pane-issue

[Herdr](https://herdr.dev) plugin: shows the GitHub issue each agent pane is
working on in the Agents sidebar, and opens it with one key.

```
 ○ my-app · 1
   claude · #488
```

## Install

Needs Herdr 0.9.1+, `jq`, `git`, and optionally `gh`.

```bash
herdr plugin install ilazaridis/herdr-pane-issue
```

Then in `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "prefix+i"
type = "plugin_action"
command = "ilazaridis.pane-issue.open"

[ui.sidebar.agents]
rows = [["state_icon", "machine", "workspace", "tab"], ["agent", { token = "$issue", fg = "#89b4fa" }]]
```

## How it works

If the agent works in a linked git worktree, the issue is the first number in
the worktree's name (`.worktrees/fix-488-x`). Otherwise it is the first number
in the branch (`feat/132-x`, `fix/issue-549-x`). If the branch has none, the
plugin uses the issue that the branch's PR closes, looked up with `gh`. For
Claude Code, the working directory is read from its session transcript, so it
follows the agent into worktrees.

- Tokens: `$issue` (`#123`) and `$issue_url`.
- Actions: `open` opens the focused pane's issue; `refresh` relabels every pane.

It's a key rather than a click because the Herdr sidebar can't hold links.

MIT licensed.
