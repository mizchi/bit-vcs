#!/bin/bash
# Compare two most recent benchmark results in .bench-results/
# Usage: bash tools/bench-compare.sh [baseline] [current]
set -e

DIR=".bench-results"

if [ ! -d "$DIR" ]; then
    echo "No benchmark results found in $DIR/"
    echo "Run: just bench-save <name>"
    exit 1
fi

# Get the two most recent files, or use arguments
if [ $# -ge 2 ]; then
    BASELINE="$DIR/$1.json"
    CURRENT="$DIR/$2.json"
else
    FILES=($(ls -t "$DIR"/*.json 2>/dev/null))
    if [ ${#FILES[@]} -lt 2 ]; then
        echo "Need at least 2 benchmark results to compare."
        echo "Found: ${FILES[*]}"
        echo "Run: just bench-save <name>"
        exit 1
    fi
    CURRENT="${FILES[0]}"
    BASELINE="${FILES[1]}"
fi

if [ ! -f "$BASELINE" ] || [ ! -f "$CURRENT" ]; then
    echo "Missing files: $BASELINE or $CURRENT"
    exit 1
fi

python3 -c "
import json, sys

baseline = json.load(open('$BASELINE'))
current = json.load(open('$CURRENT'))

RED = '\033[0;31m'
GREEN = '\033[0;32m'
YELLOW = '\033[1;33m'
NC = '\033[0m'

print(f'Comparing: {baseline[\"name\"]} (baseline) vs {current[\"name\"]} (current)')
print('=' * 80)
print(f'{\"Benchmark\":<55} {\"Baseline\":>10} {\"Current\":>10} {\"Change\":>10}')
print('-' * 80)

b_results = baseline.get('results', {})
c_results = current.get('results', {})

all_keys = sorted(set(list(b_results.keys()) + list(c_results.keys())))

for key in all_keys:
    b_ns = b_results.get(key)
    c_ns = c_results.get(key)

    if b_ns is None:
        print(f'{key:<55} {\"N/A\":>10} {c_ns:>10,} {\"new\":>10}')
    elif c_ns is None:
        print(f'{key:<55} {b_ns:>10,} {\"N/A\":>10} {\"removed\":>10}')
    else:
        if b_ns == 0:
            change_str = 'N/A'
            color = NC
        else:
            pct = ((c_ns - b_ns) / b_ns) * 100
            if pct < -5:
                color = GREEN
                change_str = f'{pct:+.1f}%'
            elif pct > 5:
                color = RED
                change_str = f'{pct:+.1f}%'
            else:
                color = NC
                change_str = f'{pct:+.1f}%'
        print(f'{key:<55} {b_ns:>10,} {c_ns:>10,} {color}{change_str:>10}{NC}')

print('-' * 80)
"
