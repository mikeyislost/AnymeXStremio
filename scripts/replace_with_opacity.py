"""Replace Color.withOpacity(x) with Color.withValues(alpha: x) in Dart files.

Finds each `.withOpacity(` and its balanced closing parenthesis (skipping
strings), so nested calls like `.withOpacity(foo(0.5) * 2)` work.
"""
import sys, pathlib

def convert(src: str):
    out, i, n = [], 0, 0
    needle = '.withOpacity('
    while True:
        j = src.find(needle, i)
        if j < 0:
            out.append(src[i:]); break
        out.append(src[i:j])
        k = j + len(needle); depth = 1; q = None; start = k
        while k < len(src) and depth:
            c = src[k]
            if q:
                if c == '\\': k += 2; continue
                if c == q: q = None
            elif c in '\'"': q = c
            elif c == '(': depth += 1
            elif c == ')': depth -= 1
            k += 1
        if depth:  # unbalanced: leave untouched
            out.append(src[j:]); break
        arg = src[start:k-1].strip()
        if arg.endswith(','): arg = arg[:-1].rstrip()
        out.append(f'.withValues(alpha: {arg})')
        n += 1; i = k
    return ''.join(out), n

total = 0
for path in sys.argv[1:]:
    p = pathlib.Path(path)
    s = p.read_text()
    new, n = convert(s)
    if n:
        p.write_text(new); total += n
print('replaced', total)
