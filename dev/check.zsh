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
# outcome <command> [<argument>...]: the command's exit status and what it printed, as JSON {status, stdout,
# stderr}. Results and help go to stdout; errors and usage mistakes to stderr, with nothing on stdout.
outcome() {
  local stdout exit_status errors=$ABAKUS_STATE_DIR/outcome-stderr
  stdout=$("$@" 2>$errors)
  exit_status=$?
  jq -n --argjson status $exit_status --arg stdout "$stdout" --arg stderr "$(<$errors)" \
    '{status: $status, stdout: $stdout, stderr: $stderr}'
}

# MCP, legacy era: initialize, then the tools, as a client that negotiated 2025-11-25 sees them; a shared tally
# "requests" for calc to read, here, in the modern era and on the command line; a shared tally "amounts" with marks,
# added to with a JSON number, the common case for MCP clients; tallies_info, which counts the two, and its old
# name; calc's note for a leading minus before a power
responses=$(printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"check","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"sum","arguments":{"numbers":["0.1",0.2]}}}' \
  '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"tally_add","arguments":{"name":"missing"}}}' \
  '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"tally_create","arguments":{"name":"requests","shared":true}}}' \
  '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"tally_add","arguments":{"name":"requests","amount":"1250"}}}' \
  '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"calc","arguments":{"expression":"37 / {requests} * 100"}}}' \
  '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"tally_create","arguments":{"name":"amounts","shared":true,"thresholds":[{"at":[10,20,30,40,50,60,70]}]}}}' \
  '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"tally_add","arguments":{"name":"amounts","amount":12.50}}}' \
  '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"tallies_info","arguments":{}}}' \
  '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"tally_list","arguments":{}}}' \
  '{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"calc","arguments":{"expression":"-2^2"}}}' \
  | $abakus mcp 2>>$stderr_log)
expect "mcp legacy: twelve responses, none for the notification" '. == null' \
  "$(print -r -- "$responses" | jq -s 'if length == 12 then null else length end')"
expect "mcp legacy: initialize negotiates 2025-11-25 and sends instructions" \
  '.result.protocolVersion == "2025-11-25" and (.result.instructions | contains("shared: true") and contains("calc") and (contains("unique") | not))' \
  "$(print -r -- "$responses" | jq -c 'select(.id == 1)')"
expect "mcp legacy: tools/list has all eight tools" \
  '[.result.tools[].name] | sort == ["calc","date_diff","sum","tallies_info","tally_add","tally_create","tally_drop","tally_set"]' \
  "$(print -r -- "$responses" | jq -c 'select(.id == 2)')"
expect "mcp legacy: sum of 0.1 and 0.2 is exactly 0.3, without read (a detail, ADR-0008)" \
  '.result.structuredContent == {"total": 0.3, "count": 2, "mean": 0.15}
     and (.result.content[0].text | contains("\"total\":0.3") and (contains("read") | not))' \
  "$(print -r -- "$responses" | jq -c 'select(.id == 3)')"
mcp_sum_text=$(print -r -- "$responses" | jq -r 'select(.id == 3) | .result.content[0].text')  # for call --without-details
expect "mcp legacy: tally_add takes a number string and leaves out read (a detail, ADR-0008)" \
  '.result.structuredContent | .value == 1250 and .added == 1250 and (has("read") | not) and (has("notes") | not)' \
  "$(print -r -- "$responses" | jq -c 'select(.id == 6)')"
expect "mcp legacy: tally_add takes a JSON number exactly, and shows the crossing and the marks ahead" \
  '.result.structuredContent | .value == 12.5 and .added == 12.5 and .count == 1 and .crossed == [{"marks_total": 7, "of": "value", "at": [10]}]
     and .thresholds == [{"marks_total": 7, "of": "value", "passed": 1, "ahead": [20, 30, 40, 50, 60]}]
     and (has("read") | not) and (has("notes") | not)' \
  "$(print -r -- "$responses" | jq -c 'select(.id == 9)')"
expect "mcp legacy: a tool error is a result with isError" \
  '.result.isError == true and (.result.content[0].text | test("missing"))' \
  "$(print -r -- "$responses" | jq -c 'select(.id == 4)')"
expect "mcp legacy: calc reads a tally by name, without read (a detail, ADR-0008)" \
  '.result.structuredContent == {"result": 2.96, "tallies": [{"name": "requests", "of": "value", "value": 1250}]}
     and (.result.content[0].text | contains("read") | not)' \
  "$(print -r -- "$responses" | jq -c 'select(.id == 7)')"
expect "mcp legacy: calc notes how it read a leading minus before a power" \
  '.result.structuredContent | .result == -4 and (has("read") | not) and (.notes | length) == 1
     and (.notes[0] | startswith("\"-2^2\" at character 1 was read as -(2^2):") and contains("write (-2)^2."))' \
  "$(print -r -- "$responses" | jq -c 'select(.id == 12)')"
expect "mcp legacy: tallies_info gives the folder and the count, without the list (a detail, ADR-0008)" \
  ".result.structuredContent == {\"folder\": \"$ABAKUS_STATE_DIR/tallies\", \"tallies_found\": 2}
     and (.result.content[0].text | contains(\"\\\"tallies\\\"\") | not)" \
  "$(print -r -- "$responses" | jq -c 'select(.id == 10)')"
expect "mcp legacy: the old name tally_list is an unknown tool whose error gives the new name" \
  '.error.code == -32602 and (.error.message | test("^Unknown tool: tally_list\\. It was renamed to tallies_info in abakus 0\\.5\\.1\\."))' \
  "$(print -r -- "$responses" | jq -c 'select(.id == 11)')"

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
expect "cli: tally add takes a negative amount after a -- terminator" '.value == 2 and .added == -3' \
  "$($abakus tally add "$name" -- -3)"
expect "cli: tally add with two amounts is a usage error, with tally add's usage" \
  '.status == 64 and .stdout == "" and (.stderr | test("Give one amount, not 2") and test("Usage: abakus tally add "))' \
  "$(outcome $abakus tally add "$name" 1 2)"
expect "cli: tally set takes a negative value" '.value == -1.5' "$($abakus tally set "$name" --value -1.5)"
expect "cli: tally set replaces the thresholds, from repeated --at and --at-count, each at with the marks ahead" \
  '.thresholds == [{"marks_total": 2, "of": "value", "passed": 0, "ahead": [1, 2]},
                   {"marks_total": 1, "of": "count", "passed": 0, "ahead": [5]}]' \
  "$($abakus tally set "$name" --at 1 --at 2 --at-count 5)"
expect "cli: tally set refuses --clear-thresholds with threshold options, with tally set's usage" \
  '.status == 64 and .stdout == "" and (.stderr | test("either --clear-thresholds or threshold options") and test("Usage: abakus tally set "))' \
  "$(outcome $abakus tally set "$name" --clear-thresholds --limit 3)"
expect "cli: tally set --clear-thresholds removes them" '.thresholds == []' \
  "$($abakus tally set "$name" --clear-thresholds)"
expect "cli: tallies info shows it" ".tallies | map(.name) | index(\"$name\") != null" "$($abakus tallies info items)"
expect "cli: tally drop returns the final state" '.dropped == true and .value == -1.5' "$($abakus tally drop "$name")"
expect "cli: adding to a dropped tally fails with exit 1 and says why" \
  '.status == 1 and .stdout == "" and (.stderr | test("no tally named"))' "$(outcome $abakus tally add "$name")"

# Tallies within ADR-0008: an at threshold of 200 marks, given as strings that also read with a decimal comma.
# call --without-details prints exactly the MCP text (checked for sum below); over MCP, tally_create and tally_add
# stay within a budget of 700 characters each: marks counted, at most 5 of those ahead listed, one note for all the
# strings. The command line prints read.
marks_args=$(jq -nc '{name: "bytes", thresholds: [{at: [range(1; 201) | "\(.),000"]}]}')
mcp_text=$($abakus call --without-details tally_create "$marks_args")
marks_name=$(print -r -- "$mcp_text" | jq -r .name)
expect "mcp text: tally_create with 200 marks as strings stays within 700 characters: 5 marks ahead, one note, no read" \
  '.length <= 700 and (.json | .thresholds == [{"marks_total": 200, "of": "value", "passed": 0, "ahead": [1000, 2000, 3000, 4000, 5000]}]
     and (has("read") | not) and (.notes | length == 1) and (.notes[0] | startswith("200 strings read differently")
     and contains("tally_set")))' \
  "$(jq -n --arg text "$mcp_text" '{length: ($text | length), json: ($text | fromjson)}')"
mcp_text=$($abakus call --without-details tally_add "{\"name\": \"$marks_name\", \"amount\": \"150,500\"}")
expect "mcp text: tally_add crossing 150 of the marks stays within 700 characters: a count with the first and the last" \
  '.length <= 700 and (.json | .crossed == [{"marks_total": 200, "of": "value", "times": 150, "first": 1000, "last": 150000}]
     and .thresholds == [{"marks_total": 200, "of": "value", "passed": 150, "ahead": [151000, 152000, 153000, 154000, 155000]}]
     and (has("read") | not)
     and (.notes[0] | contains("crossed above follows 150500") and contains("\"value\": 150.5")))' \
  "$(jq -n --arg text "$mcp_text" '{length: ($text | length), json: ($text | fromjson)}')"
expect "cli: tally create prints read, one entry per string" '.read | length == 200 and .[0] == {"input": "1,000", "value": 1000}' \
  "$($abakus call tally_create "$marks_args")"
expect "cli: tally add prints read and the note" '.read == [{"input": "2,000", "value": 2000}] and (.notes | length == 1)' \
  "$($abakus tally add "$marks_name" 2,000)"
expect "cli: tally create's and tally set's help say that the six threshold options cannot all be given" \
  'map(gsub("\\s+"; " ") | contains("At most 5 thresholds in all, so not all six threshold options at once")) | all' \
  "$(jq -n --arg create "$($abakus tally create --help)" --arg set "$($abakus tally set --help)" '[$create, $set]')"
expect "cli: a sixth threshold is an error that says to pass fewer or use a second tally" \
  '.status == 1 and .stdout == "" and (.stderr | test("thresholds has 6 items, and a tally takes at most 5") and test("second tally"))' \
  "$(outcome $abakus tally create six --limit 1 --limit-count 2 --at 3 --at-count 4 --every 5 --every-count 6)"

# CLI: a shared tally keeps its name, and creating it twice is refused
expect "cli: tally create --shared uses the name exactly" '.name == "build-errors"' \
  "$($abakus tally create build-errors --shared)"
expect "cli: creating an existing shared tally fails with exit 1 and shows it" \
  '.status == 1 and .stdout == "" and (.stderr | test("already exists") and test("coordinating"))' \
  "$(outcome $abakus tally create build-errors --shared)"

# CLI: calc, over this tally and the one from the MCP checks
$abakus tally add build-errors 18 >/dev/null
expect "cli: calc works out 1/3*3 exactly" '.result == 1 and (has("exact") | not)' "$($abakus calc '1/3*3')"
expect "cli: calc reads tallies in a quoted expression" \
  '.result == 1.44 and (.tallies | map(.name)) == ["build-errors", "requests"]' \
  "$($abakus calc '{build-errors} / {requests} * 100')"
expect "cli: calc takes a leading minus as part of the expression, prints read and notes the reading" \
  '.result == -4 and .read == "-(2 ^ 2)" and (.notes | length) == 1 and (.notes[0] | startswith("\"-2^2\" at"))' \
  "$($abakus calc -2^2)"
expect "cli: calc writes no note where the parentheses settle the reading" \
  '.result == 4 and (has("notes") | not)' "$($abakus calc '(-2)^2')"
expect "cli: calc drops a leading -- terminator" '.result == 3 and .read == "1 + 2"' "$($abakus calc -- 1 + 2)"
expect "cli: calc with an unknown tally fails with exit 1 and computes nothing" \
  '.status == 1 and .stdout == "" and (.stderr | test("no tally named \"nope\"") and test("Nothing was computed"))' \
  "$(outcome $abakus calc '{nope} + 1')"
expect "cli: calc without an expression is a usage error, with calc's usage" \
  '.status == 64 and .stdout == "" and (.stderr | test("quoted") and test("Usage: abakus calc "))' "$(outcome $abakus calc)"

# calc over 7 tallies, and calc's MCP result for it and for a 500-term chain. The command line prints read and every
# tally; an MCP result has no read, at most 5 tallies, then tallies_total (ADR-0008). Budget for an MCP result: 400
# characters, measured on exactly the text an MCP client gets (call --without-details), with jq -Rs length.
for tally in files lines words pages tests; do $abakus tally create $tally --shared >/dev/null; done
many='{requests} + {build-errors} + {files} + {lines} + {words} + {pages} + {tests}'
many_json=$(jq -nc --arg expression "$many" '{expression: $expression}')
expect "cli: calc prints read and all 7 tallies" \
  '.result == 1268 and (.read | length) > 0 and (.tallies | length) == 7 and (has("tallies_total") | not)' \
  "$($abakus calc "$many")"
expect "cli: call calc prints read and all 7 tallies too" '(.tallies | length) == 7 and has("read")' \
  "$($abakus call calc "$many_json")"
mcp_many=$(print -r -- "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"calc\",\"arguments\":$many_json}}" \
  | $abakus mcp 2>>$stderr_log | jq -r '.result.content[0].text')
expect "mcp: calc lists the first 5 of 7 tallies, then tallies_total, and no read" \
  '(.tallies | map(.name)) == ["requests", "build-errors", "files", "lines", "words"] and .tallies_total == 7
     and (has("read") | not)' "$mcp_many"
expect "cli: call calc --without-details prints the text of the MCP result above, character for character" \
  '.cli == .mcp' "$(jq -n --arg cli "$($abakus call calc --without-details "$many_json")" --arg mcp "$mcp_many" \
     '{cli: $cli, mcp: $mcp}')"
expect "size: calc's MCP result for 7 tallies stays within 400 characters" '. <= 400' \
  "$($abakus call calc --without-details "$many_json" | jq -Rs length)"
chain=1
repeat 499 chain+=+1
chain_json=$(jq -nc --arg expression "$chain" '{expression: $expression}')
expect "size: calc's MCP result for a chain of 500 terms (999 characters) stays within 400 characters" \
  '.size <= 400 and .text == "{\"result\":500}"' \
  "$(jq -n --arg text "$($abakus call calc --without-details "$chain_json")" \
     --argjson size "$($abakus call calc --without-details "$chain_json" | jq -Rs length)" '{text: $text, size: $size}')"
# One character can carry any number of combining marks: a space carrying 20,000 of them is not whitespace, so
# -2^2 written with one is refused, and the error, the text an agent reads, stays within the budget too.
marks_json=$(jq -nc '{expression: ("-2^ " + ([range(20000)] | map("\u0301") | join("")) + "2")}')
expect "size: calc refuses -2^2 with 20,000 combining marks in a space, in an error within 400 characters" \
  '.status == 1 and .stdout == "" and (.stderr | test("^Error: Unexpected ") and length <= 400)' \
  "$(outcome $abakus call calc --without-details "$marks_json")"
braces_json=$(jq -nc '{expression: ("{a:x" + ([range(20000)] | map("́") | join("")) + "}")}')
expect "size: calc's error for a tally reference with 20,000 combining marks in its braces stays within 400 characters" \
  '.status == 1 and .stdout == "" and (.stderr | test("^Error: The tally reference ") and length <= 400)' \
  "$(outcome $abakus call calc "$braces_json")"

# tallies_info in a state folder of its own, so that its counts do not depend on the checks above: 30 tallies with
# thresholds, one more, and a file that cannot be read. Over MCP (measured with call --without-details, exactly the
# text an MCP client gets) the result is the folder and the counts: 30 tallies add one digit to an empty folder's
# result and no names, and it stays within 200 characters (ADR-0008). The command line lists them all. The folder
# is below the scratch folder, so the EXIT trap removes it in any case.
scratch_state=$ABAKUS_STATE_DIR
export ABAKUS_STATE_DIR=$scratch_state/tally-list
list_folder=$ABAKUS_STATE_DIR/tallies
mcp_list_empty=$($abakus call --without-details tallies_info '{}')
for i in {1..30}; do
  $abakus tally create bulk --limit 20 --at 5 --at 10 --at 15 --every-count 5 >/dev/null
done
mcp_list=$($abakus call --without-details tallies_info '{}')
expect "tallies_info over MCP: 30 tallies add one digit to an empty folder's result, and no names" \
  ".empty == {\"folder\": \"$list_folder\", \"tallies_found\": 0} and .full == {\"folder\": \"$list_folder\", \"tallies_found\": 30}
     and (.full_text | length) == (.empty_text | length) + 1 and (.full_text | contains(\"bulk\") | not)" \
  "$(jq -n --arg empty_text "$mcp_list_empty" --arg full_text "$mcp_list" \
     '{empty_text: $empty_text, full_text: $full_text, empty: ($empty_text | fromjson), full: ($full_text | fromjson)}')"
$abakus tally create other --shared >/dev/null
print -r -- '{ not json' > $list_folder/broken.json
mcp_list=$($abakus call --without-details tallies_info '{}')
expect "tallies_info over MCP: the folder and the counts, unreadable_found for the broken file" \
  "keys_unsorted == [\"folder\", \"tallies_found\", \"unreadable_found\"]
     and . == {\"folder\": \"$list_folder\", \"tallies_found\": 31, \"unreadable_found\": 1}" "$mcp_list"
expect "tallies_info over MCP stays within 200 characters with 31 tallies" \
  '. <= 200' "$(print -rn -- "$mcp_list" | jq -Rs length)"
expect "tallies_info over MCP with a prefix counts only the tallies whose names start with it" \
  ". == {\"folder\": \"$list_folder\", \"tallies_found\": 30}" \
  "$($abakus call --without-details tallies_info '{"prefix": "bulk"}')"
expect "tallies_info over MCP with a prefix counts only the unreadable files whose names start with it" \
  ". == {\"folder\": \"$list_folder\", \"tallies_found\": 0, \"unreadable_found\": 1}" \
  "$($abakus call --without-details tallies_info '{"prefix": "br"}')"
expect "cli: tallies info prints every tally with its state, and the unreadable file with what is wrong" \
  '.tallies_found == 31 and (.tallies | length) == 31 and .unreadable_found == 1
     and ([.tallies[] | select(.name | test("^bulk-[a-z0-9]{4}$"))] | length) == 30
     and all(.tallies[]; has("value") and has("count") and has("thresholds") and has("created") and has("updated"))
     and ([.tallies[] | select(.name | startswith("bulk-")) | .thresholds | length] | unique) == [3]
     and (.unreadable | length == 1 and .[0].name == "broken" and (.[0].problem | length) > 0)' \
  "$($abakus tallies info)"
expect "cli: tallies info with a prefix lists only those, sorted by name" \
  '.tallies_found == 30 and (.tallies | map(.name)) == (.tallies | map(.name) | sort) and (has("unreadable") | not)' \
  "$($abakus tallies info bulk)"
expect "cli: tally list, the old name of tallies info, still prints the same" '.old == .new and (.new | length) > 0' \
  "$(jq -n --arg old "$($abakus tally list bulk)" --arg new "$($abakus tallies info bulk)" '{old: $old, new: $new}')"
expect "cli: tally drop removes the file that cannot be read" '.dropped == true and .name == "broken"' \
  "$($abakus tally drop broken)"
export ABAKUS_STATE_DIR=$scratch_state

# CLI: sum from arguments (number strings, a negative number) and from stdin
expect "cli: sum reads 410k and 1,234.5, and prints read" \
  '.total == 411234.5 and .read == [{"index": 0, "input": "410k", "value": 410000}, {"index": 1, "input": "1,234.5", "value": 1234.5}]' \
  "$($abakus sum 410k 1,234.5)"
expect "cli: sum notes a string the other decimal mark reads differently" \
  '.total == 1239 and (.notes | length == 1) and (.notes[0] | contains("\"1,234\" (numbers[0]) was read as 1234"))' \
  "$($abakus sum 1,234 5)"
expect "cli: sum takes negative numbers" '.total == 2' "$($abakus sum 1 -2 3)"
expect "cli: sum after a -- terminator" '.total == -4' "$($abakus sum 1 -- -5)"
expect "cli: a mistyped option is a usage error, not a number, with sum's usage" \
  '.status == 64 and .stdout == "" and (.stderr | test("Unknown option") and test("Usage: abakus sum "))' \
  "$(outcome $abakus sum 1 --decmal , 2)"
expect "cli: sum reads stdin" '.total == 6 and .count == 3' "$(print -l 1 2 3 | $abakus sum)"
expect "cli: sum with a decimal comma" '.total == 1234.5' "$($abakus sum --decimal , 1.234,5)"
# Numbers typed into a terminal, through a pseudo-terminal: once sum says it is waiting, type "1 2", then
# ctrl-D until it ends. The loop never blocks on reading and gives up after about 5 s, so a broken sum fails the
# check instead of hanging it. zpty runs the command in a fork of this shell: `trap - EXIT` keeps that fork
# from removing the state folder when it ends.
zmodload zsh/zpty
zpty terminal "trap - EXIT; ${(q)abakus} sum 2>&1; print -r -- \"exit status \$?\""
terminal_output= typed=
for attempt in {1..50}; do
  while zpty -r -t terminal line; do terminal_output+=${line//$'\r'/}; done
  [[ $terminal_output == *"exit status "* ]] && break
  if [[ -z $typed && $terminal_output == *ctrl-D* ]]; then
    zpty -w terminal '1 2'
    typed=yes
  fi
  [[ -n $typed ]] && zpty -w -n terminal $'\x04' 2>/dev/null
  sleep 0.1
done
zpty -d terminal
expect "cli: sum in a terminal says what it waits for, then adds the numbers typed until ctrl-D" \
  '.output | test("Type or paste the numbers") and test("\"total\":3,") and test("exit status 0")' \
  "$(jq -n --arg output "$terminal_output" '{output: $output}')"

# CLI: date-diff, and the raw call command
expect "cli: date-diff across an offset" '.totals.hours == 1738.5' \
  "$($abakus date-diff 2026-11-08T14:30:00+01:00 2027-01-20)"
expect "cli: date-diff without a second date measures to now" '.to_is_now == true' "$($abakus date-diff 2026-01-01)"
expect "cli: call passes JSON arguments through" '.total == 0.3' \
  "$($abakus call sum '{"numbers": ["0.1", 0.2]}')"
expect "cli: call - reads the arguments from stdin" '.total == 3' \
  "$(print -r -- '{"numbers": [1, 2]}' | $abakus call sum -)"
expect "cli: call with invalid JSON fails with exit 1 and says so" \
  '.status == 1 and .stdout == "" and (.stderr | test("not valid JSON"))' "$(outcome $abakus call sum '{"numbers":')"
expect "cli: call with arguments that are not an object fails with exit 1" \
  '.status == 1 and .stdout == "" and (.stderr | test("must be a JSON object"))' "$(outcome $abakus call sum '[1, 2]')"
expect "cli: call with an unknown tool fails with exit 1 and points to abakus tools" \
  '.status == 1 and .stdout == "" and (.stderr | test("no tool named nosuch") and test("abakus tools"))' "$(outcome $abakus call nosuch)"
expect "cli: call with the old name tally_list fails with exit 1 and gives the new name" \
  '.status == 1 and .stdout == "" and (.stderr | test("no tool named tally_list\\. It was renamed to tallies_info in abakus 0\\.5\\.1\\."))' \
  "$(outcome $abakus call tally_list)"
expect "cli: call prints the details an MCP result leaves out" '.read == [{"index": 0, "input": "0.1", "value": 0.1}]' \
  "$($abakus call sum '{"numbers": ["0.1", 0.2]}')"
expect "cli: call --without-details prints the text of the MCP result above, character for character" '.cli == .mcp' \
  "$(jq -n --arg cli "$($abakus call --without-details sum '{"numbers": ["0.1", 0.2]}')" \
     --arg mcp "$mcp_sum_text" '{cli: $cli, mcp: $mcp}')"

# CLI: the tool list, help and version
expect "cli: tools lists the eight tools by name and title, a short line each and nothing else" \
  '.status == 0 and (.stdout | split("\n") | all(length <= 80 and test("^[a-z_]+ +[A-Z]")) and any(test("^sum +Exact sum$"))
     and ([.[] | split(" ")[0]] | sort)
       == ["calc","date_diff","sum","tallies_info","tally_add","tally_create","tally_drop","tally_set"])' \
  "$(outcome $abakus tools)"
expect "cli: tools --show prints a tool's description and input schema" \
  '.status == 0 and (.stdout | test("Adds numbers exactly") and test("\"numbers\""))' "$(outcome $abakus tools --show sum)"
expect "cli: --version prints the version" '.status == 0 and (.stdout | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' \
  "$(outcome $abakus --version)"
expect "cli: --help lists the commands" '.status == 0 and (.stdout | test("SUBCOMMANDS:") and test("date-diff"))' \
  "$(outcome $abakus --help)"
expect "cli: a command's --help shows its usage" '.status == 0 and (.stdout | test("USAGE: abakus sum "))' \
  "$(outcome $abakus sum --help)"

if (( failures )); then
  if [[ -s $stderr_log ]]; then
    print -u2 -- "abakus mcp wrote to stderr:"
    cat $stderr_log >&2
  fi
  print -u2 -- "$failures check(s) failed"
  exit 1
fi
print -- "all checks passed"
