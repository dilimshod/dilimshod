"""Gate decision logic (pure), gate orchestration, manifest shape, version retention, CLI, Colab notebook."""

import json
from pathlib import Path

import pytest

from roadvis_trainer import publish
from roadvis_trainer.gate import EvalMetrics, decide, run_gate


def m(map50=0.70, p=0.80, r=0.66, car=0.7, person=0.6, tl=0.5):
    per = {}
    if car is not None:
        per["car"] = {"precision": 0.8, "recall": car, "map50": 0.7}
    if person is not None:
        per["person"] = {"precision": 0.8, "recall": person, "map50": 0.6}
    if tl is not None:
        per["traffic_light"] = {"precision": 0.7, "recall": tl, "map50": 0.5}
    per["truck"] = {"precision": 0.5, "recall": 0.1, "map50": 0.2}
    return EvalMetrics(map50=map50, precision=p, recall=r, per_class=per, test_images=300)


# Decision ------------------------------------------------------------------------------------------------------------
def test_accepts_when_map_improves_by_0005():
    assert decide(m(map50=0.705), m(map50=0.70)).accepted
    assert decide(m(map50=0.80), m(map50=0.70)).accepted


def test_rejects_small_map_gain():
    d = decide(m(map50=0.704), m(map50=0.70))
    assert not d.accepted and d.reasons == ["map50"]
    assert not decide(m(map50=0.70), m(map50=0.70)).accepted


@pytest.mark.parametrize("cls,kw", [("car", "car"), ("person", "person"), ("traffic_light", "tl")])
def test_recall_drop_limit_per_protected_class(cls, kw):
    cur = m()
    base = cur.per_class[cls]["recall"]
    ok = m(map50=0.75, **{kw: base - 0.01})
    bad = m(map50=0.75, **{kw: base - 0.011})
    assert decide(ok, cur).accepted
    d = decide(bad, cur)
    assert not d.accepted and d.reasons == [f"recall[{cls}]"]


def test_unprotected_class_recall_may_drop():
    cand = m(map50=0.75)
    cand.per_class["truck"]["recall"] = 0.0
    assert decide(cand, m()).accepted


def test_precision_drop_limit():
    assert decide(m(map50=0.75, p=0.79), m(p=0.80)).accepted
    d = decide(m(map50=0.75, p=0.789), m(p=0.80))
    assert not d.accepted and d.reasons == ["precision"]


def test_class_without_test_instances_is_skipped_but_missing_in_candidate_counts_zero():
    assert decide(m(map50=0.75, tl=None), m(tl=None)).accepted
    d = decide(m(map50=0.75, tl=None), m())
    assert not d.accepted and d.reasons == ["recall[traffic_light]"]


def test_multiple_failures_are_all_reported():
    d = decide(m(map50=0.6, p=0.5, car=0.1), m())
    assert d.reasons == ["map50", "recall[car]", "precision"]
    assert len(d.checks) == 5


# Orchestration -------------------------------------------------------------------------------------------------------
def _candidate(settings, store, cid="c" * 32):
    cdir = settings.candidates_dir / cid
    cdir.mkdir(parents=True)
    (cdir / "best.pt").write_bytes(b"PK\x03\x04")
    store.insert_candidate(cid, str(cdir / "best.pt"), {"baseModel": "yolo11s", "epochs": 50})
    return cid


def _fill_test(settings, store, n=3):
    for i in range(n):
        store.insert_sample(sample_id=f"t{i}", device_id=1, meta={}, width=1, height=1)
        store.mark_kept(f"t{i}", "test", f"{i:016x}", 100, 100, 1)


def test_run_gate_rejects_and_deletes_candidate_keeps_report(settings, store):
    _fill_test(settings, store)
    cid = _candidate(settings, store)
    seen = []

    def evaluator(s, weights, label):
        seen.append(Path(str(weights)).name)
        return m(map50=0.70) if label.startswith("cand") else m(map50=0.70)

    report = run_gate(store, settings, cid, evaluator=evaluator, publisher=lambda *a: pytest.fail("published"))
    assert report["status"] == "rejected"
    assert seen == ["best.pt", "yolo11s.pt"]  # no current model yet → stock baseline
    assert report["current"] == {"version": None, "weights": "yolo11s.pt"}
    assert not (settings.candidates_dir / cid).exists()
    saved = json.loads((settings.reports_dir / f"{cid}.json").read_text())
    assert saved["decision"]["reasons"] == ["map50"] and saved["training"]["epochs"] == 50
    assert store.get_candidate(cid)["status"] == "rejected"


def test_run_gate_accepts_and_publishes(settings, store):
    _fill_test(settings, store)
    cid = _candidate(settings, store)
    published = {}

    def publisher(st, s, cand_id, weights, report):
        published["metrics"] = publish.manifest_metrics(report)
        published["base"] = publish.base_model_name(report)
        return "2026-12-01-1"

    report = run_gate(store, settings, cid,
                      evaluator=lambda s, w, label: m(map50=0.75) if label.startswith("cand") else m(map50=0.70),
                      publisher=publisher)
    assert report["status"] == "accepted" and report["publishedVersion"] == "2026-12-01-1"
    assert published["metrics"] == {"testImages": 3, "map50": 0.75, "precision": 0.8, "recall": 0.66,
                                    "previous": {"map50": 0.7}}
    assert published["base"] == "yolo11s"
    assert store.get_candidate(cid)["version"] == "2026-12-01-1"


def test_run_gate_uses_current_published_model(settings, store):
    _fill_test(settings, store)
    vdir = settings.models_dir / "2026-11-30-1"
    vdir.mkdir(parents=True)
    (vdir / "weights.pt").write_bytes(b"PK")
    store.insert_version("2026-11-30-1", {"createdAt": "2026-11-30T00:00:00Z", "version": "2026-11-30-1"}, None)
    cid = _candidate(settings, store)
    seen = []
    run_gate(store, settings, cid, evaluator=lambda s, w, label: seen.append(str(w)) or m(), publisher=None)
    assert seen[1] == str(vdir / "weights.pt")


def test_run_gate_requires_test_images(settings, store):
    settings.gate_min_test_images = 100
    _fill_test(settings, store, 3)
    cid = _candidate(settings, store)
    report = run_gate(store, settings, cid, evaluator=lambda *a: pytest.fail("evaluated"))
    assert report["status"] == "rejected" and report["decision"]["reasons"] == ["testSetTooSmall"]


def test_run_gate_records_errors(settings, store):
    _fill_test(settings, store)
    cid = _candidate(settings, store)

    def boom(*a):
        raise RuntimeError("val crashed")

    report = run_gate(store, settings, cid, evaluator=boom)
    assert report["status"] == "error" and "val crashed" in store.get_candidate(cid)["message"]


def test_worker_processes_pending_candidates(settings, store, monkeypatch):
    from roadvis_trainer import gate, worker

    cid = _candidate(settings, store)
    calls = []
    monkeypatch.setattr(gate, "run_gate", lambda st, s, c: calls.append(c))
    assert worker.process_candidates(store, settings) == 1 and calls == [cid]


# Publish / manifest --------------------------------------------------------------------------------------------------
def fake_coreml(weights, work, out):
    for _, name, (h, w) in publish.IOS_VARIANTS:
        pkg = out / f"{name}.mlpackage"
        (pkg / "Data" / "com.apple.CoreML" / "weights").mkdir(parents=True)
        (pkg / "Manifest.json").write_text(json.dumps({"name": name}))
        (pkg / "Data" / "com.apple.CoreML" / "model.mlmodel").write_bytes(f"{h}x{w}".encode())
        (pkg / "Data" / "com.apple.CoreML" / "weights" / "weight.bin").write_bytes(b"\1" * 1000)


def fake_onnx(weights, work, out):
    (out / publish.ONNX_NAME).write_bytes(b"onnx-model")


def broken(*a):
    raise RuntimeError("coremltools failed")


METRICS = {"testImages": 812, "map50": 0.71, "precision": 0.8, "recall": 0.66, "previous": {"map50": 0.68}}


def _publish(settings, store, **kw):
    w = settings.tmp_dir / "best.pt"
    w.write_bytes(b"PK\x03\x04weights")
    return publish.publish_weights(store, settings, w, metrics=METRICS, base_model="yolo11s",
                                   coreml_exporter=kw.get("coreml", fake_coreml),
                                   onnx_exporter=kw.get("onnx", fake_onnx))


def test_manifest_shape_matches_contract(settings, store):
    import hashlib

    version = _publish(settings, store)
    man = publish.find_latest(store, "ios")
    assert set(man) == {"version", "createdAt", "baseModel", "metrics", "ios", "android"}
    assert man["version"] == version and version.count("-") == 3 and version.endswith("-1")
    assert man["createdAt"].endswith("Z") and man["baseModel"] == "yolo11s"
    assert man["metrics"] == METRICS
    assert set(man["ios"]) == {"landscape", "portrait"}
    assert man["ios"]["landscape"]["name"] == "RoadVisDetector"
    assert man["ios"]["portrait"]["name"] == "RoadVisDetectorPortrait"
    files = man["ios"]["landscape"]["files"]
    assert [f["path"] for f in files] == ["Data/com.apple.CoreML/model.mlmodel",
                                          "Data/com.apple.CoreML/weights/weight.bin", "Manifest.json"]
    vdir = settings.models_dir / version
    for f in files:
        data = (vdir / "RoadVisDetector.mlpackage" / f["path"]).read_bytes()
        assert set(f) == {"path", "sha256", "size"}
        assert f["sha256"] == hashlib.sha256(data).hexdigest() and f["size"] == len(data)
    assert man["android"] == {"file": {"path": "yolo-roadvis.onnx", "sha256": hashlib.sha256(b"onnx-model").hexdigest(),
                                       "size": 10},
                              "inputs": [[544, 960], [960, 544], [384, 640], [640, 384]]}
    assert (vdir / "weights.pt").exists()
    assert json.loads((vdir / "manifest.json").read_text()) == man
    assert publish.served_paths(man) == {
        "RoadVisDetector.mlpackage/Manifest.json", "RoadVisDetector.mlpackage/Data/com.apple.CoreML/model.mlmodel",
        "RoadVisDetector.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
        "RoadVisDetectorPortrait.mlpackage/Manifest.json",
        "RoadVisDetectorPortrait.mlpackage/Data/com.apple.CoreML/model.mlmodel",
        "RoadVisDetectorPortrait.mlpackage/Data/com.apple.CoreML/weights/weight.bin", "yolo-roadvis.onnx"}


def test_coreml_failure_publishes_android_only(settings, store, caplog):
    version = _publish(settings, store, coreml=broken)
    man = publish.find_latest(store, "android")
    assert man["version"] == version and man["ios"] is None and man["android"]["file"]["size"] == 10
    assert publish.find_latest(store, "ios") is None
    assert "Core ML export failed" in caplog.text
    assert not list((settings.models_dir / version).glob("*.mlpackage"))


def test_both_exports_failing_publishes_nothing(settings, store):
    with pytest.raises(RuntimeError):
        _publish(settings, store, coreml=broken, onnx=broken)
    assert store.published_versions() == []
    assert not any(p.is_dir() for p in settings.models_dir.iterdir())


def test_keep_last_three_versions(settings, store):
    versions = [_publish(settings, store) for _ in range(5)]
    assert versions == [versions[0][:-1] + str(i) for i in range(1, 6)]
    published = [v["version"] for v in store.published_versions()]
    assert published == versions[:1:-1]  # newest three, newest first
    for v in versions[:2]:
        assert not (settings.models_dir / v).exists()
        assert store.get_version(v)["status"] == "deleted"
    for v in versions[2:]:
        assert (settings.models_dir / v / "yolo-roadvis.onnx").exists()


def test_published_files_are_downloadable(client, settings, store):
    from conftest import ADMIN

    _publish(settings, store)
    h = {"Authorization": f"Bearer {ADMIN}"}
    man = client.get("/api/v1/model/latest?platform=ios", headers=h).json()
    for variant in man["ios"].values():
        for f in variant["files"]:
            r = client.get(f"/api/v1/model/{man['version']}/files/{variant['name']}.mlpackage/{f['path']}", headers=h)
            assert r.status_code == 200 and len(r.content) == f["size"]


# CLI and notebook ----------------------------------------------------------------------------------------------------
def test_cli_token_lifecycle(tmp_path, monkeypatch, capsys):
    from roadvis_trainer.cli import main

    monkeypatch.setenv("ROADVIS_DATA_DIR", str(tmp_path / "d"))
    monkeypatch.chdir(tmp_path)
    assert main(["token", "create", "--name", "iphone-1"]) == 0
    token = capsys.readouterr().out.strip().splitlines()[-1]
    assert token.startswith("rvt_") and len(token) > 40
    assert main(["token", "list"]) == 0
    listing = capsys.readouterr().out
    assert "iphone-1" in listing and "active" in listing and token not in listing
    assert main(["token", "revoke", "iphone-1"]) == 0
    assert main(["token", "revoke", "iphone-1"]) == 1
    main(["token", "list"])
    assert "revoked" in capsys.readouterr().out


def test_colab_notebook_generation(tmp_path, capsys):
    from roadvis_trainer.cli import main

    out = tmp_path / "colab" / "RoadVis_train.ipynb"
    assert main(["train", "--colab", "--out", str(out)]) == 0
    nb = json.loads(out.read_text())
    assert nb["nbformat"] == 4 and nb["metadata"]["accelerator"] == "GPU"
    src = "".join("".join(c["source"]) for c in nb["cells"])
    for needle in ('SERVER_URL = "https://trafficcounter.uz/roadvis"  #@param', 'ADMIN_TOKEN = ""  #@param',
                   "/api/v1/admin/dataset/export", "/api/v1/admin/model/current", "/api/v1/admin/candidates",
                   "imgsz=IMGSZ, rect=True", "batch=-1", "EPOCHS = 50", "PATIENCE = 10", "IMGSZ = 960",
                   '"yolo11s.pt"'):
        assert needle in src, needle
    for cell in nb["cells"]:
        if cell["cell_type"] == "code":
            code = "\n".join(line for line in "".join(cell["source"]).splitlines()
                             if not line.lstrip().startswith(("!", "%")))
            compile(code, "cell", "exec")
    assert "Colab" in capsys.readouterr().out


def test_committed_notebook_is_up_to_date():
    from roadvis_trainer.training import notebook_json

    committed = Path(__file__).resolve().parents[1] / "colab" / "RoadVis_train.ipynb"
    assert json.loads(committed.read_text()) == notebook_json()
