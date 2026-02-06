#!/bin/bash
# Save benchmark results from stdin (moon bench output) to .bench-results/<name>.json
# Usage: moon bench --target native 2>&1 | bash tools/bench-save.sh <name>
set -e

NAME="${1:?Usage: bench-save.sh <name>}"
DIR=".bench-results"
mkdir -p "$DIR"
OUTPUT="$DIR/$NAME.json"

# Parse moon bench output into JSON
# Expected format: "bench <name> ... <N> ns/iter"
python3 -c "
import sys, json, re

results = {}
for line in sys.stdin:
    line = line.strip()
    # Match: bench <name> ... <number> ns/iter
    m = re.match(r'^bench\s+(.+?)\s+\.\.\.\s+([\d,]+)\s+ns/iter', line)
    if m:
        name = m.group(1)
        ns = int(m.group(2).replace(',', ''))
        results[name] = ns

json.dump({'name': '$NAME', 'results': results}, open('$OUTPUT', 'w'), indent=2)
print(f'Saved {len(results)} benchmarks to $OUTPUT')
"
