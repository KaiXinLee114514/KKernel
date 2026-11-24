#!/usr/bin/env bash
# check-docs.sh — English/Chinese documentation consistency check.
#
# Verifies:
#   1. README.md <-> README.zh-CN.md both exist and carry language switchers;
#   2. every docs/<name>.md has a docs/zh-CN/<name>.md counterpart and vice versa;
#   3. every doc starts with the right language switcher line;
#   4. every relative markdown link in all README / docs files resolves to an
#      existing file;
#   5. English docs contain no leftover Chinese paragraphs (fenced code blocks,
#      inline code and HTML comments are ignored — Chinese is expected only in
#      real console-output samples).
#
# Usage: tools/check-docs.sh   (or: make docs-check)
# Exit code: 0 = all good, 1 = problems found.

set -u
cd "$(dirname "$0")/.." || exit 1

python3 - <<'PY'
import os
import re
import sys

ROOT = os.getcwd()
FAILS = []
CJK = re.compile(r'[\u3400-\u4dbf\u4e00-\u9fff\u3000-\u303f\uff00-\uffef]')
FENCE_RE = re.compile(r'^\s*(```|~~~)')
INLINE_CODE_RE = re.compile(r'`[^`\n]*`')
HTML_COMMENT_RE = re.compile(r'<!--.*?-->', re.S)
LINK_RE = re.compile(r'\]\(([^)\n]+)\)')


def fail(msg):
    FAILS.append(msg)


def read(path):
    with open(path, 'r', encoding='utf-8') as f:
        return f.read()


def prose_lines(text):
    """Yield (lineno, line) for non-code lines with inline code stripped."""
    in_fence = False
    for lineno, line in enumerate(text.splitlines(), 1):
        if FENCE_RE.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        yield lineno, INLINE_CODE_RE.sub('', line)


def rel_links(text):
    """Yield relative link targets (skip http(s)/mailto/#anchors)."""
    for m in LINK_RE.finditer(text):
        url = m.group(1).strip()
        if not url or re.match(r'^[a-zA-Z][a-zA-Z0-9+.-]*:', url) or url.startswith('#'):
            continue
        url = url.split('#', 1)[0]
        if url:
            yield url


def strip_fences(text):
    """Drop fenced code blocks (links inside code samples are not real links)."""
    out = []
    in_fence = False
    for line in text.splitlines():
        if FENCE_RE.match(line):
            in_fence = not in_fence
            continue
        if not in_fence:
            out.append(line)
    return '\n'.join(out)


def check_links(path, base):
    n = 0
    for url in rel_links(strip_fences(read(path))):
        n += 1
        target = os.path.normpath(os.path.join(base, url))
        if not os.path.exists(target):
            fail(f'{os.path.relpath(path, ROOT)}: broken link -> {url}')
    return n


def check_switcher(path, expected):
    text = read(path)
    first = text.splitlines()[0].strip() if text.strip() else ''
    if first != expected:
        fail(f'{os.path.relpath(path, ROOT)}: first line should be {expected!r}, got {first!r}')


def leftover_chinese(path):
    hits = []
    for lineno, line in prose_lines(read(path)):
        if len(CJK.findall(line)) >= 8:
            hits.append((lineno, line.strip()))
    return hits


def main():
    readme = os.path.join(ROOT, 'README.md')
    readme_zh = os.path.join(ROOT, 'README.zh-CN.md')
    have_readme = os.path.isfile(readme)
    have_readme_zh = os.path.isfile(readme_zh)
    if not have_readme:
        fail('README.md: missing')
    if not have_readme_zh:
        fail('README.zh-CN.md: missing')

    if have_readme and have_readme_zh:
        check_switcher(readme, 'English | [简体中文](README.zh-CN.md)')
        check_switcher(readme_zh, '[English](README.md) | 简体中文')

    docs_dir = os.path.join(ROOT, 'docs')
    zh_dir = os.path.join(docs_dir, 'zh-CN')

    def md_files(d):
        if not os.path.isdir(d):
            return []
        return sorted(f for f in os.listdir(d)
                      if f.endswith('.md') and os.path.isfile(os.path.join(d, f)))

    en_docs = md_files(docs_dir)
    zh_docs = md_files(zh_dir)

    for f in en_docs:
        if f not in zh_docs:
            fail(f'docs/{f}: missing Chinese counterpart docs/zh-CN/{f}')
    for f in zh_docs:
        if f not in en_docs:
            fail(f'docs/zh-CN/{f}: missing English counterpart docs/{f}')

    link_checks = 0
    if have_readme:
        link_checks += check_links(readme, ROOT)
    if have_readme_zh:
        link_checks += check_links(readme_zh, ROOT)
    for f in en_docs:
        p = os.path.join(docs_dir, f)
        check_switcher(p, f'[简体中文](zh-CN/{f})')
        link_checks += check_links(p, docs_dir)
    for f in zh_docs:
        p = os.path.join(zh_dir, f)
        check_switcher(p, f'[English](../{f})')
        link_checks += check_links(p, zh_dir)

    en_files = ([readme] if have_readme else []) + \
               [os.path.join(docs_dir, f) for f in en_docs]
    zh_left = 0
    for p in en_files:
        hits = leftover_chinese(p)
        if not hits:
            continue
        zh_left += len(hits)
        for lineno, line in hits[:5]:
            fail(f'{os.path.relpath(p, ROOT)}:{lineno}: leftover Chinese text: {line[:80]}')
        if len(hits) > 5:
            fail(f'{os.path.relpath(p, ROOT)}: ... and {len(hits) - 5} more line(s) with Chinese text')

    print('README pair           : ' + ('OK' if have_readme and have_readme_zh else 'MISSING'))
    print(f'docs pairs            : {len(en_docs)} English / {len(zh_docs)} Chinese')
    print(f'relative links checked: {link_checks}')
    print(f'English files checked : {len(en_files)} (leftover Chinese lines: {zh_left})')

    if FAILS:
        print()
        print(f'❌ {len(FAILS)} problem(s) found:')
        for f in FAILS:
            print('  -', f)
        return 1
    print()
    print('✅ docs check passed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
PY
