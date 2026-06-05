#!/usr/bin/env python3
"""Fix sqld's broken JSON: sqld doesn't escape backslashes in text values.
   \X becomes \\X for X that's not a valid JSON escape char."""
import sys, json, re

text = sys.stdin.read()

# Match a backslash followed by a char that is NOT a valid JSON escape
# Valid JSON escapes: \" \\ \/ \b \f \n \r \t \u
fixed = re.sub(r'\\(?=[^"\\/bfnrtu])', r'\\\\', text)

try:
    data = json.loads(fixed)
    print(json.dumps(data))
except json.JSONDecodeError as e:
    print(f"FIX FAILED at pos {e.pos}: {e.msg}", file=sys.stderr)
    st = max(0, e.pos - 60)
    print(f"CONTEXT: {repr(fixed[st:e.pos+40])}", file=sys.stderr)
    sys.exit(1)
