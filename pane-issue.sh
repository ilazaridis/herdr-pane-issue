#!/usr/bin/env bash
# Publishes, for each agent pane, the GitHub issue and pull request it works on:
#   $issue  "#123"        $issue_url  the issue's page
#   $pr     "PR #45 ✓"    $pr_url     the pull request's page
# The PR is the open pull request of the branch checked out where the agent
# works, marked ✓ approved, ✗ changes requested, ● review pending or ◌ draft.
# The issue is the one that PR closes. Before there is one, it is the first
# number in the name of the linked worktree (.worktrees/fix-123-x), or outside
# a linked worktree, of the branch (feat/123-x, 123-x, fix/issue-123, fix/#123).
#
# GitHub is only asked about a branch that has been pushed. A push from any
# agent in a Herdr pane asks at once, through the git hook that install-git-hook
# sets up; otherwise a branch is asked about at most once a minute while it has
# no PR, and every 10 minutes once it has one.
#
#   pane-issue.sh sync              label the event's pane, or every agent pane
#   pane-issue.sh refresh           forget cached PRs, then label every agent pane
#   pane-issue.sh open              open the focused pane's PR, or its issue if it has none
#   pane-issue.sh install-git-hook  add the push hook to the global git config
#   pane-issue.sh remove-git-hook   remove it again
#   pane-issue.sh git-hook STATE    run by git's reference-transaction hook
set -uo pipefail

herdr=${HERDR_BIN_PATH:-herdr}
source_id="plugin:${HERDR_PLUGIN_ID:-ilazaridis.pane-issue}"
# The git hook runs outside Herdr, so default to where Herdr keeps plugin state.
state=${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr/plugins/ilazaridis.pane-issue}
self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
US=$'\x1f'

# Herdr starts plugins with a minimal PATH.
PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:$HOME/.local/bin"

command -v jq >/dev/null || { echo "pane-issue: jq not found" >&2; exit 0; }
mkdir -p "$state/pr"

# pane_id, cwd, Claude session id, and the current $issue, $issue_url, $pr and
# $pr_url of a pane or agent object, joined by \x1f so empty fields survive `read`.
fields='[.pane_id, (.foreground_cwd // .cwd // ""),
  (if .agent_session.agent == "claude" then .agent_session.value else "" end),
  (.tokens.issue // ""), (.tokens.issue_url // ""), (.tokens.pr // ""), (.tokens.pr_url // "")]
  | join("\u001f")'

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

pr_cache() { # repo branch
  printf '%s/pr/%s\n' "$state" "$(printf '%s\n%s' "$1" "$2" | cksum | cut -d' ' -f1)"
}

# Open pull request of the branch checked out in dir, as
# "number \x1f url \x1f review mark \x1f closed issue number \x1f its url",
# or nothing. A branch that was never pushed can't have one, so GitHub is not
# asked. Answers are cached with the pushed commit: a new push asks again at
# once, otherwise a miss is kept for a minute and a hit for 10 minutes.
pr_for() { # dir branch repo
  local dir=$1 branch=$2 repo=$3 sha cache line= ttl
  case $branch in main | master | develop | trunk) return 1 ;; esac
  command -v gh >/dev/null || return 1
  sha=$(git -C "$dir" rev-parse -q --verify '@{upstream}' 2>/dev/null ||
    git -C "$dir" rev-parse -q --verify "refs/remotes/origin/$branch" 2>/dev/null) || return 1
  cache=$(pr_cache "$repo" "$branch")
  [[ -f $cache ]] && IFS= read -r line <"$cache"
  ttl=10
  [[ $line == "$sha$US" ]] && ttl=1
  if [[ ${line%%"$US"*} != "$sha" || -z $(find "$cache" -mmin -"$ttl" 2>/dev/null) ]]; then
    line="$sha$US$( (cd "$dir" && with_timeout 20 gh pr view \
      --json number,url,state,isDraft,reviewDecision,closingIssuesReferences \
      --jq 'select(.state == "OPEN") | [.number, .url,
        (if .isDraft then "◌" elif .reviewDecision == "APPROVED" then "✓"
         elif .reviewDecision == "CHANGES_REQUESTED" then "✗" else "●" end),
        (.closingIssuesReferences[0].number // ""), (.closingIssuesReferences[0].url // "")]
        | map(tostring) | join("\u001f")') 2>/dev/null </dev/null)"
    printf '%s\n' "$line" >"$cache.tmp" && mv -f "$cache.tmp" "$cache"
  fi
  [[ -n ${line#*"$US"} ]] && printf '%s\n' "${line#*"$US"}"
}

# Drops the cached pull request of the branch checked out in dir.
forget_pr() {
  local branch repo
  branch=$(git -C "$1" symbolic-ref --short -q HEAD 2>/dev/null) || return 0
  repo=$(repo_url "$1") || return 0
  rm -f "$(pr_cache "$repo" "$branch")"
}

# Issue and pull request of a directory, as
# "issue number \x1f issue url \x1f PR label \x1f PR url"; any may be empty.
resolve() {
  local dir=$1 top git_dir common_dir branch repo name
  local pr_num= pr_url= mark= num= url=
  [[ -n $dir && -d $dir ]] || return 1
  { read -r top; read -r git_dir; read -r common_dir; } < <(git -C "$dir" rev-parse \
    --path-format=absolute --show-toplevel --absolute-git-dir --git-common-dir 2>/dev/null)
  [[ -n $top ]] || return 1
  branch=$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null)
  repo=$(repo_url "$dir")
  if [[ -n $branch && -n $repo ]]; then
    IFS=$US read -r pr_num pr_url mark num url < <(pr_for "$dir" "$branch" "$repo")
  fi
  if [[ -z $num ]]; then
    # A linked worktree is named for its issue, so there the branch is not looked at.
    name=$branch
    [[ $git_dir != "$common_dir" ]] && name=${top##*/}
    num=$(issue_in_name "$name") && [[ -n $repo ]] && url="$repo/issues/$num"
  fi
  printf '%s\n' "$num$US$url$US${pr_num:+PR #$pr_num $mark}$US$pr_url"
}

# Pane named by the event that started this run, if any.
event_pane() {
  [[ -n ${HERDR_PLUGIN_EVENT_JSON:-} ]] || return 0
  jq -r '[.. | objects | .pane_id? | strings][0] // empty' <<<"$HERDR_PLUGIN_EVENT_JSON" 2>/dev/null
}

sync_panes() { # [pane_id]
  local only=${1:-} pane cwd sid issue issue_url pr pr_url num url label link args token
  while IFS=$US read -r -u 3 pane cwd sid issue issue_url pr pr_url; do
    num= url= label= link=
    IFS=$US read -r num url label link < <(resolve "$(work_dir "$cwd" "$sid")")
    [[ ${num:+#$num}$US$url$US$label$US$link == "$issue$US$issue_url$US$pr$US$pr_url" ]] && continue
    args=()
    for token in "issue=${num:+#$num}" "issue_url=$url" "pr=$label" "pr_url=$link"; do
      if [[ -n ${token#*=} ]]; then args+=(--token "$token"); else args+=(--clear-token "${token%%=*}"); fi
    done
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
  exec 9>&-
}

# Opens the focused pane's pull request, or its issue when there is no PR yet.
# The PR is looked up afresh, since it may have been opened a moment ago.
open_pr() {
  local pane=${HERDR_PANE_ID:-} cwd sid dir num url label link opener=xdg-open
  [[ -n $pane ]] || pane=$("$herdr" pane current </dev/null | jq -r '.result.pane.pane_id // empty')
  [[ -n $pane ]] || { notify "No focused pane."; return 0; }
  IFS=$US read -r _ cwd sid _ < <("$herdr" pane get "$pane" </dev/null | jq -r ".result.pane | $fields")
  dir=$(work_dir "${cwd:-}" "${sid:-}")
  [[ -n $dir && -d $dir ]] && forget_pr "$dir"
  IFS=$US read -r num url label link < <(resolve "$dir")
  url=${link:-$url}
  if [[ -z $url ]]; then
    notify "No pull request or GitHub issue found for this pane."
    return 0
  fi
  [[ $(uname) == Darwin ]] && opener=open
  nohup "$opener" "$url" >/dev/null 2>&1 </dev/null &
  locked sync_panes "$pane"
}

# Run by git after every ref update, in the repository that made it, with the
# updates on stdin. A push moves the pushed branch's remote-tracking ref; when
# that is the checked-out branch of an agent in a Herdr pane, look for its pull
# request in the background, a few times, since `gh pr create` pushes before
# it opens the PR.
git_hook() { # state
  local branch old new ref pushed=
  [[ $1 == committed && -n ${HERDR_PANE_ID:-} ]] || return 0
  branch=$(git symbolic-ref --short -q HEAD 2>/dev/null) || return 0
  while read -r old new ref; do
    # Not a deletion: the new id is not all zeros.
    [[ $ref == refs/remotes/*/"$branch" && $new == *[!0]* ]] && pushed=1
  done
  [[ -n $pushed ]] || return 0
  if command -v setsid >/dev/null; then
    setsid -f "$self" watch-pr "$HERDR_PANE_ID" "$PWD" </dev/null >/dev/null 2>&1
  else
    nohup "$self" watch-pr "$HERDR_PANE_ID" "$PWD" </dev/null >/dev/null 2>&1 &
  fi
}

watch_pr() { # pane dir
  local pane=$1 dir=$2 delay branch repo
  branch=$(git -C "$dir" symbolic-ref --short -q HEAD 2>/dev/null) || return 0
  repo=$(repo_url "$dir") || return 0
  if command -v flock >/dev/null; then
    exec 8>"$state/watch-${pane//[^A-Za-z0-9]/_}.lock"
    flock -n 8 || return 0
  fi
  for delay in 3 10 30 60; do
    sleep "$delay"
    forget_pr "$dir"
    if [[ -n $(pr_for "$dir" "$branch" "$repo") ]]; then
      locked sync_panes "$pane"
      return 0
    fi
  done
}

# git appends the hook's arguments to the command, so the command is a function
# call. It must succeed whatever happens: a failing reference-transaction hook
# aborts the ref update.
hook_command() {
  printf "h() { [ \"\$1\" = committed ] && [ -n \"\$HERDR_PANE_ID\" ] && [ -x '%s' ] && HERDR_PLUGIN_STATE_DIR='%s' exec '%s' git-hook \"\$1\"; return 0; }; h" \
    "$self" "$state" "$self"
}

install_git_hook() {
  git config --global --replace-all hook.herdr-pane-issue.event reference-transaction &&
    git config --global hook.herdr-pane-issue.command "$(hook_command)" &&
    notify "Git push hook added to your global git config."
}

remove_git_hook() {
  git config --global --remove-section hook.herdr-pane-issue 2>/dev/null
  notify "Git push hook removed."
}

case ${1:-sync} in
  sync) locked sync_panes "$(event_pane)" ;;
  refresh) rm -f "$state"/pr/* && locked sync_panes ;;
  open) open_pr ;;
  install-git-hook) install_git_hook ;;
  remove-git-hook) remove_git_hook ;;
  git-hook) git_hook "${2:-}"; exit 0 ;;
  watch-pr) watch_pr "$2" "$3" ;;
  *) echo "usage: $0 [sync|refresh|open|install-git-hook|remove-git-hook]" >&2; exit 2 ;;
esac
