# Per-function block balance for Lua.
#
# Order matters: strings must be removed BEFORE comments. Doing it the other way
# round means a "--" inside a string literal is mistaken for a comment marker and
# truncates the rest of the line, swallowing any end/then on it.
/^function |^local function / {
  if (inf && d != 0) printf "UNBALANCED %-48s %+d  [%s]\n", substr(name,1,48), d, FILENAME
  inf = 1; d = 0; name = $0
}
inf {
  line = $0
  gsub(/\\"/, "", line)                # escaped quotes are not delimiters
  gsub(/"[^"]*"/, "", line)            # strings first
  gsub(/\047[^\047]*\047/, "", line)
  sub(/--.*/, "", line)                # then comments
  gsub(/[^A-Za-z0-9_]/, " ", line)     # tokenise
  n = split(line, w, " ")
  for (i = 1; i <= n; i++) {
    if (w[i] == "function" || w[i] == "then" || w[i] == "do") d++
    else if (w[i] == "elseif") d--
    else if (w[i] == "end") d--
  }
}
END { if (inf && d != 0) printf "UNBALANCED %-48s %+d  [%s]\n", substr(name,1,48), d, FILENAME }
