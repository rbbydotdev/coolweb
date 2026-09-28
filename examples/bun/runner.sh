#!/bin/sh
# Job runner for the Bun demo. A VMWorker script with serialization: "json".
#
# In:   {"id":N,"run":"<base64 shell command>"}   start job N; its output streams back line by line
#       {"id":N,"kill":1}                          stop job N and every process it started
# Out:  {"type":"ready"}
#       {"type":"out","id":N,"line":"..."}         one per output line (stdout and stderr)
#       {"type":"exit","id":N,"code":C}
#
# Bun lives in the site's storage (/work/.bun), so it is installed once and kept across visits.
export HOME=/work BUN_INSTALL=/work/.bun PATH="/work/.bun/bin:$PATH" NO_COLOR=1 FORCE_COLOR=0

esc() { sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' | tr -d '\000-\010\013-\037'; }

# job <id> <command>: runs in its own process group (so kill reaches children), streams lines, reports exit.
# Inside a pipeline the caller is not a group leader, so setsid execs in place and the exit code comes through.
job() {
  { setsid sh -c 'echo $$ > "/tmp/job.$1"; exec sh -c "$2" 2>&1' _ "$1" "$2" </dev/null
    echo "__job_exit__ $?"; } |
  while IFS= read -r line; do
    case "$line" in
      "__job_exit__ "*) printf '{"type":"exit","id":%s,"code":%s}\n' "$1" "${line#__job_exit__ }" ;;
      *) printf '{"type":"out","id":%s,"line":"%s"}\n' "$1" "$(printf '%s' "$line" | esc)" ;;
    esac
  done
  rm -f "/tmp/job.$1"
}

echo '{"type":"ready"}'
while IFS= read -r msg; do
  id=$(printf '%s' "$msg" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
  case "$msg" in
    *'"kill"'*)
      [ -f "/tmp/job.$id" ] && kill -TERM "-$(cat "/tmp/job.$id")" 2>/dev/null
      ;;
    *'"run"'*)
      job "$id" "$(printf '%s' "$msg" | sed -n 's/.*"run":"\([^"]*\)".*/\1/p' | base64 -d)" &
      ;;
  esac
done
