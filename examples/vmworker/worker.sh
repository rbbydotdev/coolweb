#!/bin/sh
# A VMWorker script. stdin: messages from the page. stdout: messages to the page. One JSON value per line.
# stderr goes to the page's devtools console.
#
# Request:  {"id":1,"cmd":"uname -a"}      (cmd must be the last key)
# Reply:    {"type":"result","id":1,"code":0,"out":"..."}

json() {
  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' -e 's/\r//g' \
    | tr -d '\000-\010\013-\037' \
    | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }'
}

echo "worker.sh started as pid $$" >&2
printf '{"type":"ready","kernel":"%s","arch":"%s","cpus":%s,"memMB":%s}\n' \
  "$(uname -r)" "$(uname -m)" "$(nproc)" "$(free -m | awk '/Mem:/ { print $2 }')"

while IFS= read -r msg; do
  id=$(printf '%s' "$msg" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
  cmd=$(printf '%s' "$msg" | sed -n 's/.*"cmd":"\(.*\)"}$/\1/p' | sed -e 's/\\"/"/g' -e 's/\\\\/\\/g')
  out=$(sh -c "$cmd" 2>&1)
  code=$?
  printf '{"type":"result","id":%s,"code":%s,"out":"%s"}\n' "${id:-null}" "$code" "$(printf '%s' "$out" | json)"
done
