# herdr-pane-issue

A [Herdr](https://herdr.dev) plugin that shows, on each agent's row in the
Agents sidebar, the GitHub issue that agent is working on — and opens it in the
browser with one key.

```
 ○ my-app · 1
   claude · #488
 ○ my-app · 2
   codex · #42
```

Useful when several agents work on different issues in worktrees of the same
repository, inside one space.

## Where the number comes from

1. The directory the agent works in. For Claude Code that is the last `cwd` in
   its session transcript, because the `claude` process itself stays in the
   directory it was started in even after the agent moves into a worktree.
   For other agents it is the pane's foreground cwd.
2. The branch checked out there. The first number in the branch name is the
   issue: `feat/132-x`, `390-x`, `chore/issue-549-x`, `fix/#12`. Not taken:
   numbers after `pr` (`pr-729-x`, `review/pr-758`) and numbers next to another
   number (`node-5-3`, `2026-4-25`).
3. If the branch names no issue, the issue its pull request closes
   (`gh pr view <branch> --json closingIssuesReferences`). Answers are cached
   for 60 minutes, misses for 10. `main`, `master`, `develop` and `trunk` are
   never looked up.

The link is `<origin remote>/issues/<n>`, or the closing reference's own URL.

A pane is re-checked when its agent is detected or changes state and when the
pane is focused; every agent is checked at server start. Herdr has no
cwd-changed event.

## Install

Needs Herdr 0.9.1 or newer, `bash`, `jq` and `git`; `gh`, signed in, for the
pull-request fallback. Tested on Linux.

```bash
herdr plugin install ilazaridis/herdr-pane-issue
```

Herdr renders a token only where the sidebar row config names it. Add `$issue`
to the agent rows, and bind the open action, in `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "prefix+i"
type = "plugin_action"
command = "ilazaridis.pane-issue.open"
description = "open this pane's GitHub issue"

[ui.sidebar.agents]
rows = [["state_icon", "machine", "workspace", "tab"], ["agent", { token = "$issue", fg = "#89b4fa", bold = true }]]
```

Reload the config (`prefix+shift+r`). Startup hooks run only when the server
starts, so labels appear with the next agent event, or run the
`Pane issue: refresh` action.

## Tokens

| Token        | Value                                      |
| ------------ | ------------------------------------------ |
| `$issue`     | `#123`                                     |
| `$issue_url` | `https://github.com/owner/repo/issues/123` |

## Actions

| Action                          | Does                                                     |
| ------------------------------- | -------------------------------------------------------- |
| `ilazaridis.pane-issue.open`    | Open the focused pane's issue in the browser.            |
| `ilazaridis.pane-issue.refresh` | Forget cached PR lookups and label every agent pane again. |

`open` works in any pane on an issue branch, agent or plain shell, and shows a
notification when there is none.

## Why a key and not a click

Herdr 0.9.1 draws the sidebar and the tab bar as plain text: token values have
their escape characters stripped, so an OSC 8 hyperlink can't get through, and
clicking an agent row only focuses its pane.

## Limitations

- Agents running on another machine (remote panes) are not labelled; their
  directory and transcript are over there.
- A detached HEAD, such as a checkout for reviewing a pull request, has no
  branch and gets no label.

## Troubleshooting

```bash
herdr plugin log list --plugin ilazaridis.pane-issue
```

## License

MIT
