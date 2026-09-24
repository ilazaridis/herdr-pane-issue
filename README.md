# herdr-pane-issue

[![Release](https://img.shields.io/github/v/release/ilazaridis/herdr-pane-issue)](https://github.com/ilazaridis/herdr-pane-issue/releases/latest)

[Herdr](https://herdr.dev) plugin: shows the GitHub issue and pull request each
agent pane is working on in the Agents sidebar, and opens the PR with one key.
Works with any agent.

```
 ○ my-app · 1
   claude · #769 · PR #772 ✓
```

## Install

Needs Herdr 0.9.1+, `jq`, `git`, and `gh` for pull requests.

```bash
herdr plugin install ilazaridis/herdr-pane-issue
herdr plugin action invoke ilazaridis.pane-issue.install-git-hook
```

The second command adds a push hook to your global git config. Repository hooks
are left alone, and `remove-git-hook` takes it out again.

Then in `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "prefix+i"
type = "plugin_action"
command = "ilazaridis.pane-issue.open"

[ui.sidebar.agents]
rows = [["state_icon", "machine", "workspace", "tab"], ["agent", { token = "$issue", fg = "#89b4fa" }, { token = "$pr", fg = "#cba6f7" }]]
```

## How it works

- **PR:** the open pull request of the branch the agent works on, marked
  ✓ approved, ✗ changes requested, ● pending or ◌ draft. When an agent runs
  `git push`, or `gh pr create` (which pushes first), the hook tells the plugin
  and the PR shows up within seconds. Pushed branches are also re-checked as
  agents start and finish turns. GitHub is never asked about unpushed branches.
- **Issue:** the one the PR closes. Before there is a PR, the first number in
  the worktree's name (`.worktrees/fix-488-x`), or outside a worktree, in the
  branch name (`feat/132-x`).
- `prefix+i` opens the PR, or the issue while there is no PR yet.

Tokens: `$issue`, `$issue_url`, `$pr`, `$pr_url`. It's a key rather than a
click because the Herdr sidebar can't hold links.

MIT licensed.
