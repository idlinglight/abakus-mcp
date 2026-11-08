#!/usr/bin/env zsh
# check: run a built abakus end to end, through the MCP server (both protocol eras) and through the CLI, in a
# scratch state folder that is removed afterwards. Real tallies are never touched.
# usage: [ABAKUS=<binary>] dev/check.zsh     (default: .build/debug/abakus)
# exit status: 0 all checks passed, 1 a check failed
# No `set -e`: a failing command must end up as a FAIL line with what it printed, not end the script silently.
set -uo pipefail

abakus=${ABAKUS:-${0:A:h:h}/.build/debug/abakus}
if [[ ! -x $abakus ]]; then
  print -u2 -- "no abakus binary at $abakus (build it, or set ABAKUS)"
  exit 1
fi
export ABAKUS_STATE_DIR=$(mktemp -d)
trap 'rm -rf -- $ABAKUS_STATE_DIR' EXIT
stderr_log=$ABAKUS_STATE_DIR/stderr.log  # the server's stderr, shown if a check fails

failures=0
# expect <label> <jq filter that must yield true> <json>
expect() {
  local label=$1 filter=$2 json=${3-}
  if [[ $(print -r -- "$json" | jq -r "$filter" 2>/dev/null) == true ]]; then
    print -- "ok    $label"
  else
    print -u2 -- "FAIL  $label: $filter"
    print -u2 -r -- "      got: ${json:-(nothing)}"
    failures=$(( failures + 1 ))
  fi
}

# MCP, legacy era: initialize, then the tools, as a client that negotiated 2025-11-25 sees them; a shared tally
# "requests" for calc to read, here and in the modern era
responses=$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"check","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"sum","arguments":{"numbers":[0.1,0.2]}}}' \
  '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"tally_add","arguments":{"name":"missing"}}}' \
  '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"tally_create","arguments":{"name":"requests","shared":true}}}' \
  '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"tally_add","arguments":{"name":"requests","amount":1250}}}' \
  '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"calc","arguments":{"expression":"37 / {requests} * 100"}}}' \
  | $abakus mcp 2>>$stderr_log)
expect "mcp legacy: seven responses, none for the notification" '. == null' \
  "$(print -r -- "$responses" | jq -s 'if length == 7 then null else length end')"
expect "mcp legacy: initialize negotiates 2025-11-25 and sends instructions" \
  '.result.protocolVersion == "2025-11-25" and (.result.instructions | contains("shared: true") and contains("calc") and (contains("unique") | not))' \
  "$(print -r -- "$responses" | jq -c 'select(.id == 1)')"
expect "mcp legacy: tools/list has all eight tools" \
  '[.result.tools[].name] | sort == ["calc","date_diff","sum","tally_add","tally_create","tally_drop","tally_list","tally_set"]' \
  "$(print -r -- "$responses" | jq -c 'select(.id == 2)')"
expect "mcp legacy: sum of 0.1 and 0.2 is exactly 0.3" \
  '.result.structuredContent.total == 0.3 and (.result.content[0].text | contains("\"total\":0.3"))' \
  "$(print -r -- "$responses" | jq -c 'select(.id == 3)')"
expect "mcp legacy: a tool error is a result with isError" \
  '.result.isError == true and (.result.content[0].text | test("missing"))' \
  "$(print -r -- "$responses" | jq -c 'select(.id == 4)')"
expect "mcp legacy: calc reads a tally by name" \
  '.result.structuredContent == {"result": 2.96, "read": "(37 / {requests}) * 100",
     "tallies": [{"name": "requests", "of": "value", "value": 1250}]}' \
  "$(print -r -- "$responses" | jq -c 'select(.id == 7)')"

# MCP, modern era: stateless, version and capabilities in every request's _meta
meta='"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}'
responses=$(printf '%s\n' \
  "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\",\"params\":{$meta}}" \
  "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"date_diff\",\"arguments\":{\"from\":\"2026-01-31\",\"to\":\"2026-03-01\"},$meta}}" \
  "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\",\"params\":{$meta}}" \
  "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"calc\",\"arguments\":{\"expression\":\"{requests:count} / 3\"},$meta}}" \
  "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"calc\",\"arguments\":{\"expression\":\"10 / ({requests} - 1250)\"},$meta}}" \
  | $abakus mcp 2>>$stderr_log)
expect "mcp modern: server/discover lists 2026-07-28 first" \
  '.result.supportedVersions[0] == "2026-07-28" and .result.resultType == "complete"' \
  "$(print -r -- "$responses" | jq -c 'select(.id == 1)')"
expect "mcp modern: date_diff without a handshake" \
  '.result.structuredContent.calendar.months == 1 and .result.structuredContent.calendar.days == 1' \
  "$(print -r -- "$responses" | jq -c 'select(.id == 2)')"
expect "mcp modern: tools/list has calc, read-only" \
  '.result.tools | map(select(.name == "calc")) | length == 1 and .[0].annotations.readOnlyHint == true' \
  "$(print -r -- "$responses" | jq -c 'select(.id == 3)')"
expect "mcp modern: calc rounds 1/3 once and keeps the fraction" \
  '.result.structuredContent | .result == 0.333333333333333 and .exact == false and .fraction == "1/3"
     and .tallies == [{"name": "requests", "of": "count", "value": 1}]' \
  "$(print -r -- "$responses" | jq -c 'select(.id == 4)')"
expect "mcp modern: a division by zero in calc says where" \
  '.result.isError == true and (.result.content[0].text | test("^Division by zero at character 4 of"))' \
  "$(print -r -- "$responses" | jq -c 'select(.id == 5)')"

# CLI: a tally with a checkpoint every 2 additions and a limit of 5 on the value
created=$($abakus tally create items --every-count 2 --limit 5)
name=$(print -r -- "$created" | jq -r .name)
expect "cli: tally create appends a suffix" '.name | test("^items-[a-z0-9]{4}$")' "$created"
expect "cli: tally create with an existing name makes a new tally and notes it" \
  ".name != \"$name\" and (.note | test(\"already exists\"))" "$($abakus tally create "$name")"
$abakus tally add "$name" >/dev/null
added=$($abakus tally add "$name" 4)
expect "cli: tally add reports the checkpoint and the limit" \
  '.value == 5 and .count == 2 and (.crossed | length) == 2' "$added"
expect "cli: tally set takes a negative value" '.value == -1.5' "$($abakus tally set "$name" --value -1.5)"
expect "cli: tally list shows it" ".tallies | map(.name) | index(\"$name\") != null" "$($abakus tally list items)"
expect "cli: tally drop returns the final state" '.dropped == true and .value == -1.5' "$($abakus tally drop "$name")"
message=$($abakus tally add "$name" 2>&1)
expect "cli: adding to a dropped tally fails with exit 1 and says why" \
  '.status == 1 and (.message | test("no tally named"))' \
  "$(jq -n --argjson status $? --arg message "$message" '{status: $status, message: $message}')"

# CLI: a shared tally keeps its name, and creating it twice is refused
expect "cli: tally create --shared uses the name exactly" '.name == "build-errors"' \
  "$($abakus tally create build-errors --shared)"
message=$($abakus tally create build-errors --shared 2>&1)
expect "cli: creating an existing shared tally fails with exit 1 and shows it" \
  '.status == 1 and (.message | test("already exists")) and (.message | test("coordinating"))' \
  "$(jq -n --argjson status $? --arg message "$message" '{status: $status, message: $message}')"

# CLI: calc, over this tally and the one from the MCP checks
$abakus tally add build-errors 18 >/dev/null
expect "cli: calc works out 1/3*3 exactly" '.result == 1 and (has("exact") | not)' "$($abakus calc '1/3*3')"
expect "cli: calc reads tallies in a quoted expression" \
  '.result == 1.44 and (.tallies | map(.name)) == ["build-errors", "requests"]' \
  "$($abakus calc '{build-errors} / {requests} * 100')"
expect "cli: calc takes a leading minus as part of the expression" '.result == -4 and .read == "-(2 ^ 2)"' \
  "$($abakus calc -2^2)"
message=$($abakus calc '{nope} + 1' 2>&1)
expect "cli: calc with an unknown tally fails with exit 1 and computes nothing" \
  '.status == 1 and (.message | test("no tally named \"nope\"")) and (.message | test("Nothing was computed"))' \
  "$(jq -n --argjson status $? --arg message "$message" '{status: $status, message: $message}')"
message=$($abakus calc 2>&1)
expect "cli: calc without an expression is a usage error" \
  '.status == 64 and (.message | test("quoted"))' \
  "$(jq -n --argjson status $? --arg message "$message" '{status: $status, message: $message}')"

# CLI: sum from arguments (number strings, a negative number) and from stdin
expect "cli: sum reads 410k and 1,234.5" '.total == 411234.5' "$($abakus sum 410k 1,234.5)"
expect "cli: sum takes negative numbers" '.total == 2' "$($abakus sum 1 -2 3)"
expect "cli: sum after a -- terminator" '.total == -4' "$($abakus sum 1 -- -5)"
message=$($abakus sum 1 --decmal , 2 2>&1)
expect "cli: a mistyped option is a usage error, not a number" \
  '.status == 64 and (.message | test("Unknown option"))' \
  "$(jq -n --argjson status $? --arg message "$message" '{status: $status, message: $message}')"
expect "cli: sum reads stdin" '.total == 6 and .count == 3' "$(print -l 1 2 3 | $abakus sum)"
expect "cli: sum with a decimal comma" '.total == 1234.5' "$($abakus sum --decimal , 1.234,5)"

# CLI: date-diff with an offset, and the raw call command
expect "cli: date-diff across an offset" '.totals.hours == 1738.5' \
  "$($abakus date-diff 2026-11-08T14:30:00+01:00 2027-01-20)"
expect "cli: call passes JSON arguments through" '.total == 0.3' \
  "$($abakus call sum '{"numbers": ["0.1", 0.2]}')"

if (( failures )); then
  if [[ -s $stderr_log ]]; then
    print -u2 -- "abakus mcp wrote to stderr:"
    cat $stderr_log >&2
  fi
  print -u2 -- "$failures check(s) failed"
  exit 1
fi
print -- "all checks passed"
