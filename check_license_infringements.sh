#!/bin/bash
# Use scanoss to check for license infringements
# see https://github.com/scanoss/scanoss.py

# set-up
# conda activate scanoss
# python -m pip install scanoss

# use scanoss to search
scanoss-py scan . -o dependencies.json
# check for problems
grep -B 2 -A 3 -P '"id": "(?!none)[^"]+"' dependencies.json

echo "Search Complete"

