#!/usr/bin/env python3
import hashlib
import os
import sqlite3
import sys

MAX_SHOWN = 3


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for block in iter(lambda: fh.read(65536), b''):
            h.update(block)
    return h.hexdigest()


def main():
    if len(sys.argv) < 3:
        return 0
    collection, wiki = sys.argv[1], os.path.abspath(sys.argv[2])
    if not collection or not os.path.isdir(wiki):
        return 0
    cache_home = os.environ.get('XDG_CACHE_HOME') or os.path.expanduser('~/.cache')
    index = os.path.join(cache_home, 'qmd', 'index.sqlite')
    if not os.path.isfile(index):
        return 0

    try:
        con = sqlite3.connect(f'file:{index}?mode=ro', uri=True)
        rows = con.execute(
            'select path, hash from documents where collection = ? and active = 1',
            (collection,)).fetchall()
        con.close()
    except sqlite3.Error:
        return 0

    indexed = {p: (h or '') for p, h in rows}
    on_disk = set()
    stale = []
    for root, _dirs, files in os.walk(wiki):
        for name in files:
            if not name.endswith('.md'):
                continue
            path = os.path.relpath(os.path.join(root, name), wiki)
            on_disk.add(path)
            if path not in indexed:
                continue
            try:
                if sha256_of(os.path.join(wiki, path)) != indexed[path]:
                    stale.append(path)
            except OSError:
                continue

    missing = sorted(on_disk - set(indexed))
    removed = sorted(set(indexed) - on_disk)
    hint = "corre 'qmd update' antes de fiarte del recall"
    for label, items in (('modificados sin reindexar', sorted(stale)),
                         ('sin indexar', missing),
                         ('indexados pero ausentes del disco', removed)):
        if items:
            shown = ', '.join(items[:MAX_SHOWN])
            more = f' (+{len(items) - MAX_SHOWN} más)' if len(items) > MAX_SHOWN else ''
            print(f'index-freshness: aviso — {label}: {shown}{more} — {hint}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
