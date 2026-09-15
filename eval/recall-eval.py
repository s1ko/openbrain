#!/usr/bin/env python3
import json
import os
import subprocess
import sys


def timeout_for(backend):
    default = 180 if backend == 'query' else 30
    try:
        return max(1, int(os.environ.get('QMD_EVAL_TIMEOUT', default)))
    except ValueError:
        sys.exit("error: QMD_EVAL_TIMEOUT must be an integer number of seconds")


def norm(p):
    if p.startswith('qmd://'):
        w = p[len('qmd://'):]
        i = w.find('/')
        p = w[i + 1:] if i >= 0 else w
    return p.lower().strip('/')


def match(result_path, expected):
    nr, ne = norm(result_path), norm(expected)
    return nr == ne or os.path.basename(nr) == os.path.basename(ne)


def qmd_run(query, limit, collection, backend, timeout):
    cmd = ['qmd', backend, query, '--json', '-n', str(limit), '-c', collection]
    try:
        out = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError:
        sys.exit("error: `qmd` not found on PATH — cannot measure recall")
    except subprocess.TimeoutExpired:
        sys.exit(f"error: `qmd {backend}` timed out (>{timeout}s) for query: {query!r}"
                 " — raise QMD_EVAL_TIMEOUT if the host is merely loaded")
    if out.returncode != 0:
        sys.exit(f"error: `qmd {backend}` exited {out.returncode}: {out.stderr.strip()}")
    try:
        res = json.loads(out.stdout or '[]')
    except json.JSONDecodeError as exc:
        sys.exit(f"error: `qmd {backend}` returned non-JSON for {query!r}: {exc}")
    if not isinstance(res, list):
        sys.exit(f"error: `qmd {backend}` returned {type(res).__name__}, expected a JSON array")
    return [r.get('file', '') for r in res if isinstance(r, dict)]


def load_golden(path):
    with open(path, encoding='utf-8') as fh:
        try:
            data = json.load(fh)
        except json.JSONDecodeError as exc:
            sys.exit(f"error: {path} is not valid JSON: {exc}")
    collection = data.get('collection') if isinstance(data, dict) else None
    queries = data.get('queries') if isinstance(data, dict) else data
    if not isinstance(collection, str) or not collection.strip():
        sys.exit(f"error: {path} missing or empty 'collection' — refusing to search without an explicit scope")
    if not isinstance(queries, list) or not queries:
        sys.exit(f"error: {path} has no queries")
    for e in queries:
        for req in ('query', 'expected_files', 'expected_in_top_k'):
            if req not in e:
                sys.exit(f"error: golden entry missing '{req}': {e!r}")
        if not isinstance(e['query'], str) or not e['query'].strip():
            sys.exit(f"error: 'query' must be a non-empty string: {e!r}")
        ef = e['expected_files']
        if not isinstance(ef, list) or not ef or not all(isinstance(f, str) and f for f in ef):
            sys.exit(f"error: expected_files must be a non-empty list of strings: {e.get('query')!r}")
        if not isinstance(e['expected_in_top_k'], int) or e['expected_in_top_k'] < 1:
            sys.exit(f"error: expected_in_top_k must be a positive int: {e.get('query')!r}")
    return collection, queries


def main():
    backend = 'search'
    if '--backend' in sys.argv:
        i = sys.argv.index('--backend')
        if i + 1 >= len(sys.argv) or sys.argv[i + 1] not in ('search', 'query'):
            sys.exit("error: --backend must be 'search' or 'query'")
        backend = sys.argv[i + 1]
    positional = [a for i, a in enumerate(sys.argv[1:], 1)
                  if not a.startswith('--') and not (i >= 2 and sys.argv[i - 1] == '--backend')]
    tmo = timeout_for(backend)
    if not positional:
        sys.exit("usage: recall-eval.py <golden.json> [--backend search|query] [--verbose]")
    golden = positional[0]
    verbose = '--verbose' in sys.argv

    collection, queries = load_golden(golden)
    rr = 0.0
    hit10 = 0
    hitk = 0
    misses = []
    for e in queries:
        exp = e['expected_files']
        k = e['expected_in_top_k']
        limit = max(k, 10)
        files = qmd_run(e['query'], limit, collection, backend, tmo)
        rank = next((i for i, f in enumerate(files) if any(match(f, x) for x in exp)), None)
        rr += 1.0 / (rank + 1) if rank is not None else 0.0
        hit10 += 1 if (rank is not None and rank < 10) else 0
        hitk += 1 if (rank is not None and rank < k) else 0
        if rank is None or rank >= 10:
            misses.append(e['query'])
    n = len(queries)
    summary = {
        'backend': 'hybrid' if backend == 'query' else 'bm25',
        'n': n,
        'recall_at_10': round(hit10 / n, 3),
        'recall_at_k': round(hitk / n, 3),
        'mrr': round(rr / n, 3),
        'mismatch_pct': round(100 * len(misses) / n, 1),
    }
    print(json.dumps(summary))
    if verbose:
        for q in misses:
            print('MISS ' + q, file=sys.stderr)


if __name__ == '__main__':
    main()
