import json, os, subprocess, sys, pathlib

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent
SCORER = REPO / "eval" / "recall-eval.py"
FAKE_BIN = REPO / "tests" / "fixtures" / "fake-qmd"

GOLDEN = {
    "collection": "c",
    "queries": [
        {"query": "alpha cosa", "expected_files": ["alpha-uno.md"], "expected_in_top_k": 10},
        {"query": "beta cosa",  "expected_files": ["beta-dos.md"],  "expected_in_top_k": 1},
        {"query": "gamma",      "expected_files": ["gamma.md"],     "expected_in_top_k": 10},
    ],
}

def run(tmp_path, golden=GOLDEN, args=(), env_extra=None):
    g = tmp_path / "golden.json"; g.write_text(json.dumps(golden))
    log = tmp_path / "qmd.log"
    env = dict(os.environ, PATH=f"{FAKE_BIN}:{os.environ['PATH']}", FAKE_QMD_LOG=str(log))
    if env_extra: env.update(env_extra)
    p = subprocess.run([sys.executable, str(SCORER), str(g), *args], capture_output=True, text=True, env=env)
    return p, (log.read_text().splitlines() if log.exists() else [])

def test_default_backend_is_search_and_passes_collection(tmp_path):
    p, calls = run(tmp_path)
    assert p.returncode == 0, p.stderr
    assert all(c.startswith("search ") for c in calls)
    assert all(" -c c" in c for c in calls)
    out = json.loads(p.stdout)
    assert out["backend"] == "bm25"

def test_query_backend_labels_hybrid(tmp_path):
    p, calls = run(tmp_path, args=("--backend", "query"))
    assert p.returncode == 0, p.stderr
    assert all(c.startswith("query ") for c in calls)
    assert json.loads(p.stdout)["backend"] == "hybrid"

def test_metrics_are_computed_correctly(tmp_path):
    p, _ = run(tmp_path)
    out = json.loads(p.stdout)
    # alpha: rank 1 (hit10, hitk); beta: rank 2 (hit10, NO hitk con k=1); gamma: miss
    assert out["n"] == 3
    assert out["recall_at_10"] == round(2/3, 3)
    assert out["recall_at_k"] == round(1/3, 3)
    assert out["mrr"] == round((1 + 0.5 + 0) / 3, 3)
    assert out["mismatch_pct"] == round(100/3, 1)

def test_basename_match_is_not_symmetric_endswith(tmp_path):
    golden = {"collection": "c", "queries": [{"query": "alpha", "expected_files": ["uno.md"], "expected_in_top_k": 10}]}
    p, _ = run(tmp_path, golden)
    assert json.loads(p.stdout)["recall_at_10"] == 0.0   # 'alpha-uno.md' NO acredita 'uno.md'

def test_refuses_golden_without_collection(tmp_path):
    golden = {"queries": GOLDEN["queries"]}
    p, calls = run(tmp_path, golden)
    assert p.returncode != 0 and "collection" in p.stderr and calls == []

def test_fails_loud_on_nonjson_and_on_qmd_error(tmp_path):
    p, _ = run(tmp_path, env_extra={"FAKE_QMD_MODE": "nonjson"}); assert p.returncode != 0 and "non-JSON" in p.stderr
    p, _ = run(tmp_path, env_extra={"FAKE_QMD_MODE": "fail"});    assert p.returncode != 0 and "exited 3" in p.stderr

def test_missing_qmd_binary_fails_loud(tmp_path):
    g = tmp_path / "golden.json"; g.write_text(json.dumps(GOLDEN))
    env = dict(os.environ, PATH=str(tmp_path))  # sin qmd
    p = subprocess.run([sys.executable, str(SCORER), str(g)], capture_output=True, text=True, env=env)
    assert p.returncode != 0 and "not found" in p.stderr

def test_timeout_fails_loud_and_mentions_env_var(tmp_path):
    p, _ = run(tmp_path, env_extra={"FAKE_QMD_MODE": "slow", "QMD_EVAL_TIMEOUT": "1"})
    assert p.returncode != 0 and "timed out" in p.stderr and "QMD_EVAL_TIMEOUT" in p.stderr

def test_timeout_env_var_must_be_integer(tmp_path):
    p, _ = run(tmp_path, env_extra={"QMD_EVAL_TIMEOUT": "mucho"})
    assert p.returncode != 0 and "QMD_EVAL_TIMEOUT" in p.stderr
