# DynamicNotch shell integration.
# Reports this shell as a session to the notch (so it can be listed and quit
# from there), and its commands so long-running ones show up while they run and
# pop a banner when they finish. Talks to the app's socket directly with
# zsh/net/socket, so it costs no extra process per command.
#
# Commands that take over the terminal are ignored; add your own with
#   NOTCH_IGNORE+=(mytool)

zmodload zsh/net/socket 2>/dev/null || return 0
zmodload zsh/datetime 2>/dev/null

[[ -o interactive ]] || return 0

typeset -g _notch_sock="$HOME/Library/Application Support/DynamicNotch/notch.sock"
typeset -g _notch_running=""
typeset -g _notch_born=${EPOCHSECONDS:-0}
typeset -ga NOTCH_IGNORE
NOTCH_IGNORE+=(vim nvim vi nano emacs micro hx less more man top htop btop ssh mosh tmux screen
               claude watch tail fzf lazygit tig python python3 node irb ipython psql mysql sqlite3)

_notch_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/}
  REPLY=$s
}

_notch_send() {
  [[ -S $_notch_sock ]] || return 0
  zsocket "$_notch_sock" 2>/dev/null || return 0
  local fd=$REPLY
  print -r -u $fd -- "$1" 2>/dev/null
  exec {fd}>&-
}

# Fields every message carries, so the app can pick up shells it hasn't seen.
_notch_base() {
  local cwd
  _notch_escape "$PWD"; cwd=$REPLY
  REPLY="\"kind\":\"terminal\",\"pid\":$$,\"born\":$_notch_born,\"quit\":\"usr1\",\"cwd\":\"$cwd\",\"hostBundle\":\"${__CFBundleIdentifier}\""
}

_notch_preexec() {
  _notch_running=""
  local -a words=(${(z)1})
  local first=${words[1]}
  [[ $first == (sudo|time|nice|caffeinate) && -n ${words[2]} ]] && first=${words[2]}
  (( ${NOTCH_IGNORE[(Ie)${first:t}]} )) && return
  _notch_running=1
  local cmd base
  _notch_escape "$1"; cmd=$REPLY
  _notch_base; base=$REPLY
  _notch_send "{$base,\"event\":\"start\",\"command\":\"$cmd\"}"
}

_notch_precmd() {
  local code=$?
  [[ -n $_notch_running ]] || return 0
  _notch_running=""
  _notch_base
  _notch_send "{$REPLY,\"event\":\"end\",\"exit\":$code}"
}

_notch_chpwd() {
  _notch_base
  _notch_send "{$REPLY,\"event\":\"session\"}"
}

_notch_zshexit() {
  _notch_send "{\"kind\":\"terminal\",\"event\":\"exit\",\"pid\":$$}"
}

# "Quit" in the notch sends USR1 (after hanging up whatever is running). Leave
# with status 0 so the terminal closes the tab. `exit` would wait for the line
# editor to return, so save history and replace the shell instead.
TRAPUSR1() {
  [[ -n $HISTFILE ]] && fc -AI 2>/dev/null
  _notch_zshexit
  exec /usr/bin/true
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _notch_preexec
add-zsh-hook chpwd _notch_chpwd
add-zsh-hook zshexit _notch_zshexit
# Run first so $? is still the command's exit code.
precmd_functions=(_notch_precmd ${precmd_functions:#_notch_precmd})

_notch_chpwd  # announce this session
