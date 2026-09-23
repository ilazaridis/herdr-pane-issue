#!/usr/bin/env bash
# Publishes the GitHub issue each agent pane is working on as pane tokens:
#   $issue      "#123", for the Agents sidebar
#   $issue_url  the issue's page, for the open action
# Where the agent works in a linked git worktree, the number comes from the
# worktree's name (.worktrees/fix-123-x). Anywhere else it comes from the
# branch (feat/123-x, 123-x, fix/issue-123, fix/#123), and when the branch names
# none, from the issue that the branch's pull request closes (needs gh).
#
#   pane-issue.sh sync      label the event's pane, or every agent pane
#   pane-issue.sh refresh   forget cached PR lookups, then label every agent pane
#   pane-issue.sh open      open the focused pane's issue in the browser
set -uo pipefail

herdr=${HERDR_BIN_PATH:-herdr}
source_id="plugin:${HERDR_PLUGIN_ID:-ilazaridis.pane-issue}"
state=${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr-pane-issue}

# Herdr starts plugins with a minimal PATH.
PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:$HOME/.local/bin"

command -v jq >/dev/null || { echo "pane-issue: jq not found" >&2; exit 0; }
mkdir -p "$state/pr"

# pane_id, cwd, Claude session id, and the current $issue and $issue_url of a
# pane or agent object, joined by \x1f so that empty fields survive `read`.
fields='[.pane_id, (.foreground_cwd // .cwd // ""),
  (if .agent_session.agent == "claude" then .agent_session.value else "" end),
  (.tokens.issue // ""), (.tokens.issue_url // "")] | join("\u001f")'

with_timeout() { if command -v timeout >/dev/null; then timeout "$@"; else shift; "$@"; fi; }

notify() {
  "$herdr" notification show "Pane issue" --body "$1" >/dev/null 2>&1 || echo "pane-issue: $1" >&2
}

# Claude's own process stays in the directory it was started in; its transcript
# records the directory it is actually working in, e.g. after cd-ing into a worktree.
work_dir() { # cwd claude_session_id
  local dir=$1 sid=$2 transcript cwd
  if [[ -n $sid ]]; then
    for transcript in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/projects/*/"$sid.jsonl"; do
      [[ -f $transcript ]] || continue
      cwd=$(tail -n 200 "$transcript" | jq -Rr 'fromjson? | .cwd? // empty' | tail -n 1)
      [[ -n $cwd && -d $cwd ]] && dir=$cwd
      break
    done
  fi
  printf '%s\n' "$dir"
}

# First 1-6 digit part of a worktree or branch name split on / _ - #. Skipped:
# a part after "pr" (pr-729, review/pr-758 name a pull request), a part next to
# another number (node-5-3, 2026-4-25 are versions or dates; 2026.4.5 is never a
# whole part), and Herdr's generated names, whose last part is a random hex id
# (worktree/rapid-river-4821, worktree-rapid-river-4821).
issue_in_name() {
  local parts i n
  [[ $1 =~ ^worktree[/-][a-z]+-[a-z]+-[0-9a-f]{4}$ ]] && return 1
  IFS='/_#-' read -ra parts <<<"$1"
  n=${#parts[@]}
  for ((i = 0; i < n; i++)); do
    [[ ${parts[i]} =~ ^[0-9]{1,6}$ ]] || continue
    ((i > 0)) && [[ ${parts[i - 1]} == [Pp][Rr] || ${parts[i - 1]} =~ ^[0-9]+$ ]] && continue
    ((i + 1 < n)) && [[ ${parts[i + 1]} =~ ^[0-9]+$ ]] && continue
    printf '%s\n' "${parts[i]}"
    return 0
  done
  return 1
}

# https://github.com/owner/repo for the origin remote of a directory.
repo_url() {
  local url
  url=$(git -C "$1" remote get-url origin 2>/dev/null) || return 1
  url=${url%.git}
  case $url in
    https://*) ;;
    git@*) url=${url#git@}; url="https://${url/://}" ;;
    ssh://*) url=${url#ssh://}; url="https://${url#*@}" ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$url"
}

# "number url" of the issue the branch's pull request closes. Answers are
# cached, misses too, so that a burst of events asks GitHub once.
issue_from_pr() { # dir branch
  local dir=$1 branch=$2 repo cache ttl
  command -v gh >/dev/null || return 1
  repo=$(repo_url "$dir") || return 1
  cache="$state/pr/$(printf '%s\n%s' "$repo" "$branch" | cksum | cut -d' ' -f1)"
  ttl=10
  [[ -s $cache ]] && ttl=60
  if [[ -z $(find "$cache" -mmin -"$ttl" 2>/dev/null) ]]; then
    (cd "$dir" && with_timeout 20 gh pr view "$branch" --json closingIssuesReferences \
      --jq '.closingIssuesReferences[0] // empty | "\(.number) \(.url)"') \
      >"$cache.tmp" 2>/dev/null </dev/null
    mv -f "$cache.tmp" "$cache"
  fi
  [[ -s $cache ]] && cat "$cache"
}

# "number url" of the issue a directory is for; url may be missing. A linked
# worktree is named for its issue, so there the branch is not looked at.
issue_for_dir() {
  local dir=$1 top git_dir common_dir branch num url=
  [[ -n $dir && -d $dir ]] || return 1
  { read -r top; read -r git_dir; read -r common_dir; } < <(git -C "$dir" rev-parse \
    --path-format=absolute --show-toplevel --absolute-git-dir --git-common-dir 2>/dev/null)
  [[ -n $top ]] || return 1
  if [[ $git_dir != "$common_dir" ]]; then
    num=$(issue_in_name "${top##*/}") || return 1
  else
    branch=$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null) || return 1
    if ! num=$(issue_in_name "$branch"); then
      case $branch in main | master | develop | trunk) return 1 ;; esac
      issue_from_pr "$dir" "$branch"
      return
    fi
  fi
  url=$(repo_url "$dir") && url="$url/issues/$num"
  printf '%s %s\n' "$num" "$url"
}

# Pane named by the event that started this run, if any.
event_pane() {
  [[ -n ${HERDR_PLUGIN_EVENT_JSON:-} ]] || return 0
  jq -r '[.. | objects | .pane_id? | strings][0] // empty' <<<"$HERDR_PLUGIN_EVENT_JSON" 2>/dev/null
}

sync_panes() { # [pane_id]
  local only=${1:-} pane cwd sid have have_url num url want args
  while IFS=$'\x1f' read -r -u 3 pane cwd sid have have_url; do
    num= url=
    read -r num url < <(issue_for_dir "$(work_dir "$cwd" "$sid")")
    want=${num:+#$num}
    [[ $want == "$have" && $url == "$have_url" ]] && continue
    if [[ -z $want ]]; then
      args=(--clear-token issue --clear-token issue_url)
    elif [[ -z $url ]]; then
      args=(--token "issue=$want" --clear-token issue_url)
    else
      args=(--token "issue=$want" --token "issue_url=$url")
    fi
    "$herdr" pane report-metadata "$pane" --source "$source_id" "${args[@]}" >/dev/null </dev/null ||
      echo "pane-issue: could not label $pane" >&2
  done 3< <("$herdr" agent list </dev/null |
    jq -r --arg only "$only" ".result.agents[] | select(\$only == \"\" or .pane_id == \$only) | $fields")
}

# Runs one at a time: events arrive in bursts, and each run reads before it writes.
locked() {
  if command -v flock >/dev/null; then
    exec 9>"$state/lock"
    flock -w 30 9 || return 0
  fi
  "$@"
}

open_issue() {
  local pane=${HERDR_PANE_ID:-} cwd sid num url opener=xdg-open
  [[ -n $pane ]] || pane=$("$herdr" pane current </dev/null | jq -r '.result.pane.pane_id // empty')
  [[ -n $pane ]] || { notify "No focused pane."; return 0; }
  IFS=$'\x1f' read -r _ cwd sid _ _ < <("$herdr" pane get "$pane" </dev/null | jq -r ".result.pane | $fields")
  read -r num url < <(issue_for_dir "$(work_dir "${cwd:-}" "${sid:-}")")
  if [[ -z ${url:-} ]]; then
    notify "No GitHub issue found for this pane's branch."
    return 0
  fi
  [[ $(uname) == Darwin ]] && opener=open
  nohup "$opener" "$url" >/dev/null 2>&1 </dev/null &
}

case ${1:-sync} in
  sync) locked sync_panes "$(event_pane)" ;;
  refresh) rm -f "$state"/pr/* && locked sync_panes ;;
  open) open_issue ;;
  *) echo "usage: $0 [sync|refresh|open]" >&2; exit 2 ;;
esac
