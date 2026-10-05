# Drops the tests that need Apple-only code from the Linux copy of the test file.
import re, sys
p = sys.argv[1]
lines = open(p).read().split('\n')
out, i = [], 0
while i < len(lines):
    line = lines[i]
    if re.match(r'    @Test( |\()', line) or re.match(r'    @Test$', line):
        j = i
        while lines[j] != '    }': j += 1
        body = '\n'.join(lines[i:j + 1])
        if re.search(r'PKCE|TraewellingClient|SlowExtraGeocodeProtocol', body):
            i = j + 1
            continue
    out.append(line)
    i += 1
s = '\n'.join(out)
start = s.index('private final class SlowExtraGeocodeProtocol')
end = s.index('\n}\n', start) + 3
s = s[:start] + s[end:]
open(p, 'w').write(s)
