# DynamicNotch shell integration.
# Reports commands to the notch so long-running ones show up while they run and
# pop a banner when they finish. Talks to the app's socket directly with
# zsh/net/socket, so it costs no extra process per command.
#
# Commands that take over the terminal are ignored; add your own with
#   NOTCH_IGNORE+=(mytool)

zmodload zsh/net/socket 2>/dev/null || return 0

typeset -g _notch_sock="$HOME/Library/Application Support/DynamicNotch/notch.sock"
typeset -g _notch_id=""
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

_notch_preexec() {
  _notch_id=""
  local -a words=(${(z)1})
  local first=${words[1]}
  [[ $first == (sudo|time|nice|caffeinate) && -n ${words[2]} ]] && first=${words[2]}
  (( ${NOTCH_IGNORE[(Ie)${first:t}]} )) && return
  _notch_id="$$-$RANDOM$RANDOM"
  local cmd cwd
  _notch_escape "$1"; cmd=$REPLY
  _notch_escape "$PWD"; cwd=$REPLY
  _notch_send "{\"kind\":\"terminal\",\"event\":\"start\",\"id\":\"$_notch_id\",\"pid\":$$,\"command\":\"$cmd\",\"cwd\":\"$cwd\",\"hostBundle\":\"${__CFBundleIdentifier}\"}"
}

_notch_precmd() {
  local code=$?
  [[ -n $_notch_id ]] || return 0
  _notch_send "{\"kind\":\"terminal\",\"event\":\"end\",\"id\":\"$_notch_id\",\"exit\":$code}"
  _notch_id=""
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _notch_preexec
# Run first so $? is still the command's exit code.
precmd_functions=(_notch_precmd ${precmd_functions:#_notch_precmd})
