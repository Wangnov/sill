#!/bin/bash
# One shared store, two window readers/editors; Foundation and Combine, no simulator or real defaults.
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
python3 "$here/../module.py" "$name" "$root" "$out/check"
