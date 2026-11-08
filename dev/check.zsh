#!/usr/bin/env zsh
# check: run a built abakus end to end, through the MCP server (both protocol eras) and through the CLI, in a
# scratch state folder that is removed afterwards. Real tallies are never touched.
# usage: [ABAKUS=<binary>] dev/check.zsh     (default: .build/debug/abakus)
# exit status: 0 all checks passed, 1 a check failed
set -euo pipefail

abakus=${ABAKUS:-${0:A:h:h}/.build/debug/abakus}
export ABAKUS_STATE_DIR=$(mktemp -d)
trap 'rm -rf -- $ABAKUS_STATE_DIR' EXIT

failures=0
# expect <label> <jq filter that must yield true> <json>
expect() {
  local label=$1 filter=$2 json=$3
  if [[ $(print -r -- $json | jq -r $filter 2>/dev/null) == true ]]; then
    print -- "ok    $label"
  else
    print -u2 -- "FAIL  $label: $filter"
    print -u2 -r -- "      got: $json"
    failures=$(( failures + 1 ))
  fi
}

# MCP, legacy era: initialize, then the tools, as a client that negotiated 2025-11-25 sees them
responses=$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"check","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"sum","arguments":{"numbers":[0.1,0.2]}}}' \
  '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"tally_add","arguments":{"name":"missing"}}}' \
  | $abakus mcp 2>/dev/null)
expect "mcp legacy: four responses, none for the notification" '. == null' \
  "$(print -r -- $responses | jq -s 'if length == 4 then null else length end')"
expect "mcp legacy: initialize negotiates 2025-11-25 and sends instructions" \
  '.result.protocolVersion == "2025-11-25" and (.result.instructions | contains("unique: true"))' \
  "$(print -r -- $responses | jq -c 'select(.id == 1)')"
expect "mcp legacy: tools/list has all seven tools" \
  '[.result.tools[].name] | sort == ["date_diff","sum","tally_add","tally_create","tally_drop","tally_list","tally_set"]' \
  "$(print -r -- $responses | jq -c 'select(.id == 2)')"
expect "mcp legacy: sum of 0.1 and 0.2 is exactly 0.3" \
  '.result.structuredContent.total == 0.3 and (.result.content[0].text | contains("\"total\":0.3"))' \
  "$(print -r -- $responses | jq -c 'select(.id == 3)')"
expect "mcp legacy: a tool error is a result with isError" \
  '.result.isError == true and (.result.content[0].text | test("missing"))' \
  "$(print -r -- $responses | jq -c 'select(.id == 4)')"

# MCP, modern era: stateless, version and capabilities in every request's _meta
meta='"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}'
responses=$(printf '%s\n' \
  "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\",\"params\":{$meta}}" \
  "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"date_diff\",\"arguments\":{\"from\":\"2026-01-31\",\"to\":\"2026-03-01\"},$meta}}" \
  | $abakus mcp 2>/dev/null)
expect "mcp modern: server/discover lists 2026-07-28 first" \
  '.result.supportedVersions[0] == "2026-07-28" and .result.resultType == "complete"' \
  "$(print -r -- $responses | jq -c 'select(.id == 1)')"
expect "mcp modern: date_diff without a handshake" \
  '.result.structuredContent.calendar.months == 1 and .result.structuredContent.calendar.days == 1' \
  "$(print -r -- $responses | jq -c 'select(.id == 2)')"

# CLI: a tally with a checkpoint every 2 additions and a limit of 5 on the value
created=$($abakus tally create items --unique --every-count 2 --limit 5)
name=$(print -r -- $created | jq -r .name)
expect "cli: tally create --unique appends a suffix" '.name | test("^items-[a-z0-9]{4}$")' $created
$abakus tally add $name >/dev/null
added=$($abakus tally add $name 4)
expect "cli: tally add reports the checkpoint and the limit" \
  '.value == 5 and .count == 2 and (.crossed | length) == 2' $added
expect "cli: tally list shows it" ".tallies | map(.name) | index(\"$name\") != null" "$($abakus tally list items)"
expect "cli: tally drop returns the final state" '.dropped == true and .value == 5' "$($abakus tally drop $name)"
if message=$($abakus tally add $name 2>&1); then
  expect "cli: adding to a dropped tally fails" 'false' $message
else
  print -- "ok    cli: adding to a dropped tally fails (exit $?)"
fi

# CLI: sum from arguments (number strings, a negative number) and from stdin
expect "cli: sum reads 410k and 1,234.5" '.total == 411234.5' "$($abakus sum 410k 1,234.5)"
expect "cli: sum takes negative numbers" '.total == 2' "$($abakus sum 1 -2 3)"
expect "cli: sum reads stdin" '.total == 6 and .count == 3' "$(print -l 1 2 3 | $abakus sum)"
expect "cli: sum with a decimal comma" '.total == 1234.5' "$($abakus sum --decimal , 1.234,5)"

# CLI: date-diff with an offset, and the raw call command
expect "cli: date-diff across an offset" '.totals.hours == 1738.5' \
  "$($abakus date-diff 2026-11-08T14:30:00+01:00 2027-01-20)"
expect "cli: call passes JSON arguments through" '.total == 0.3' \
  "$($abakus call sum '{"numbers": ["0.1", 0.2]}')"

if (( failures )); then
  print -u2 -- "$failures check(s) failed"
  exit 1
fi
print -- "all checks passed"
