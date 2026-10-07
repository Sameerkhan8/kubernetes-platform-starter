# Used by "make lint-sh" (scripts/lint.sh sh).
# Flags scripts that call kubectl or helm directly instead of kubectl_kps / helm_kps from lib.sh.
# Heuristic: strip quoted strings and comments, then look for kubectl/helm in a command position
# (line start, after ; | & ( $( ! or a keyword like then/do/if, or after VAR=value).
# Arguments such as "command -v helm" or "have kubectl" are fine.
{
  line = $0
  gsub(/"([^"\\]|\\.)*"/, "", line)
  gsub(/\047[^\047]*\047/, "", line)
  sub(/(^|[ \t])#.*$/, "", line)
  if (line ~ /(^|[;&|({!`]|(^|[^[:alnum:]_])(then|do|else|elif|if|while|until|exec|command|time|xargs|sudo|env)|(^|[ \t])[A-Za-z_][A-Za-z0-9_]*=[^ \t]*)[ \t]*([^ \t;&|()]*\/)?(kubectl|helm)([ \t;|&]|$)/) {
    printf "  %s:%d: %s\n", FILENAME, FNR, $0
    bad = 1
  }
}
END { exit bad }
