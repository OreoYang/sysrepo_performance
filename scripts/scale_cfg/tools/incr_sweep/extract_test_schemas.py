#!/usr/bin/env python3
"""Write the YANG modules embedded in the libyang incremental-validation test as files, plus modules.txt.

usage: extract_test_schemas.py TEST_C OUT_DIR
"""
import os
import re
import sys

src = open(sys.argv[1]).read()
out = sys.argv[2]
os.makedirs(out, exist_ok=True)
mods = []
for m in re.finditer(r'static const char \*(schema_\w+) =\n((?:\s*(?:/\*.*?\*/\s*)*"(?:[^"\\]|\\.)*"\s*\n?)+);', src, re.S):
    text = ''.join(x.encode().decode('unicode_escape') for x in re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(2)))
    mm = re.search(r'module\s+([\w-]+)', text)
    if not mm:
        continue
    open(os.path.join(out, mm.group(1) + '.yang'), 'w').write(text)
    mods.append(mm.group(1))
with open(os.path.join(out, 'modules.txt'), 'w') as f:
    for m in mods:
        f.write('%s - -\n' % m)
print('%d modules: %s' % (len(mods), ' '.join(mods)))
