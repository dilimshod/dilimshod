"""Split determinism and frozen test set, labelling decisions, the worker with a mocked teacher, retention."""

import hashlib
import json
import uuid

from conftest import jpeg_bytes, make_meta, textured_image, upload

from roadvis_trainer import dataset
from roadvis_trainer.labeling import COCO_TO_DATASET, DATASET_NAMES, Box, TeacherBox, decide_labels
from roadvis_trainer.worker import process_batch


# Split ---------------------------------------------------------------------------------------------------------------
def test_split_bucket_is_sha1_mod_10():
    sid = "1b4e28ba-2fa1-11d2-883f-0016d3cca427"
    assert dataset.split_bucket(sid) == int(hashlib.sha1(sid.encode()).hexdigest(), 16) % 10


def test_split_is_deterministic_and_follows_rule():
    ids = [str(uuid.UUID(int=i * 7919 + 1)) for i in range(2000)]
    for sid in ids:
        b = dataset.split_bucket(sid)
        expected = "test" if b == 0 else "val" if b == 1 else "train"
        assert dataset.choose_split(sid, test_frozen=False) == expected
        assert dataset.choose_split(sid, test_frozen=False) == dataset.choose_split(sid, test_frozen=False)
    counts = {s: sum(dataset.choose_split(i, False) == s for i in ids) for s in ("train", "val", "test")}
    assert 120 < counts["test"] < 280 and 120 < counts["val"] < 280


def test_frozen_test_set_never_receives_new_frames():
    ids = [str(uuid.UUID(int=i * 104729 + 3)) for i in range(2000)]
    frozen = [dataset.choose_split(i, test_frozen=True) for i in ids]
    assert "test" not in frozen
    # Non-bucket-0 frames keep their split when the test set freezes.
    for sid, split in zip(ids, frozen):
        if dataset.split_bucket(sid) != 0:
            assert split == dataset.choose_split(sid, test_frozen=False)


def test_test_set_freezes_at_300_and_stays_frozen(settings, store):
    settings.test_freeze_at = 3
    assert not dataset.is_test_frozen(store, settings)
    for i in range(3):
        store.insert_sample(sample_id=f"t{i}", device_id=1, meta={}, width=1, height=1)
        store.mark_kept(f"t{i}", "test", "0" * 16, 100, 100, 0)
    assert dataset.is_test_frozen(store, settings)
    store.mark_evicted("t0")  # even if the count dropped, frozen is permanent
    assert dataset.is_test_frozen(store, settings)
    assert Settings_default_freeze() == 300


def Settings_default_freeze():
    from roadvis_trainer.config import Settings

    return Settings().test_freeze_at


# Labelling -----------------------------------------------------------------------------------------------------------
def tb(coco, conf, x=0.1, y=0.2, w=0.3, h=0.2):
    return TeacherBox(coco, conf, Box(x, y, w, h))


def test_class_mapping():
    assert DATASET_NAMES == ["car", "truck", "bus", "motorcycle", "bicycle", "person", "traffic_light", "stop_sign"]
    assert COCO_TO_DATASET == {2: 0, 7: 1, 5: 2, 3: 3, 1: 4, 0: 5, 9: 6, 11: 7}


def test_confident_boxes_become_labels():
    r = decide_labels([tb(2, 0.9), tb(0, 0.55, 0.5, 0.5, 0.1, 0.3)], [])
    import pytest

    assert r.accepted and [c for c, _ in r.labels] == [0, 5]
    assert [tuple(vars(b).values()) for _, b in r.labels] == [pytest.approx((0.1, 0.2, 0.3, 0.2)),
                                                            pytest.approx((0.5, 0.5, 0.1, 0.3))]
    assert r.yolo_lines().splitlines() == ["0 0.250000 0.300000 0.300000 0.200000",
                                           "5 0.550000 0.650000 0.100000 0.300000"]


def test_ambiguous_teacher_box_rejects_frame():
    assert decide_labels([tb(2, 0.9), tb(7, 0.49)], []).reason == "ambiguousTeacher"
    assert decide_labels([tb(2, 0.25)], []).reason == "ambiguousTeacher"
    assert decide_labels([tb(2, 0.24)], []).accepted  # below 0.25: ignored
    assert decide_labels([tb(2, 0.50)], []).accepted   # 0.50 is a label


def test_non_app_classes_are_ignored():
    r = decide_labels([tb(6, 0.4), tb(16, 0.9)], [])  # train, dog
    assert r.accepted and r.labels == []


def test_consistency_with_phone_track():
    track = {"id": 1, "confirmed": True, "hits": 5, "box": [0.1, 0.2, 0.3, 0.2]}
    assert decide_labels([tb(2, 0.9)], [track]).accepted
    assert decide_labels([tb(2, 0.9, 0.6, 0.6, 0.1, 0.1)], [track]).reason == "phoneTrackUnmatched"
    assert decide_labels([], [track]).reason == "phoneTrackUnmatched"
    assert decide_labels([], [{**track, "hits": 4}]).accepted
    assert decide_labels([], [{**track, "confirmed": False}]).accepted


def test_iou():
    assert Box(0, 0, 1, 1).iou(Box(0, 0, 1, 1)) == 1
    assert abs(Box(0, 0, 0.2, 0.2).iou(Box(0.1, 0, 0.2, 0.2)) - (0.02 / 0.06)) < 1e-9
    assert Box(0, 0, 0.1, 0.1).iou(Box(0.5, 0.5, 0.1, 0.1)) == 0


def test_boxes_are_clipped():
    r = decide_labels([tb(2, 0.9, -0.1, 0.9, 0.3, 0.2)], [])
    (_, b), = r.labels
    assert b.x == 0 and abs(b.w - 0.2) < 1e-9 and abs(b.h - 0.1) < 1e-9


# Worker with a mocked teacher ----------------------------------------------------------------------------------------
class FakeTeacher:
    def __init__(self, plan=None, default=None):
        self.plan = plan or {}
        self.default = default if default is not None else [tb(2, 0.9)]
        self.calls = 0

    def predict(self, image):
        self.calls += 1
        key = image.size
        return self.plan.get(key, self.default)


def _upload(client, token, img, **meta_over):
    meta = make_meta(**meta_over)
    assert upload(client, token, meta, image=jpeg_bytes(img)).status_code == 201
    return meta["id"]


def test_worker_keeps_labels_and_deletes_incoming(client, token, settings, store):
    sid = _upload(client, token, textured_image(seed=1))
    counts = process_batch(store, settings, FakeTeacher(), limit=10)
    assert counts["kept"] == 1
    row = store.queued_samples(10)
    assert row == []
    split = dataset.choose_split(sid, False)
    assert dataset.image_path(settings, split, sid).exists()
    assert dataset.label_path(settings, split, sid).read_text() == "0 0.250000 0.300000 0.300000 0.200000\n"
    assert not list(settings.incoming_dir.iterdir())


def test_worker_rejects_and_deletes_files_immediately(client, token, settings, store):
    blurry = textured_image(seed=2).resize((40, 22)).resize((960, 540))
    ids = {
        "blurry": _upload(client, token, blurry),
        "dark": _upload(client, token, textured_image(seed=3, brightness=10)),
        "ambig": _upload(client, token, textured_image(960, 544, seed=4)),
        "unmatched": _upload(client, token, textured_image(seed=5),
                             tracks=[{"id": 1, "confirmed": True, "hits": 9, "box": [0.7, 0.7, 0.1, 0.1]}]),
    }
    teacher = FakeTeacher(plan={(960, 544): [tb(2, 0.9), tb(0, 0.3)]})
    process_batch(store, settings, teacher, limit=10)
    with store.connect() as db:
        rows = {r["id"]: dict(r) for r in db.execute("SELECT * FROM samples")}
    assert rows[ids["blurry"]]["reason"] == "blurry"
    assert rows[ids["dark"]]["reason"] == "tooDark"
    assert rows[ids["ambig"]]["reason"] == "ambiguousTeacher"
    assert rows[ids["unmatched"]]["reason"] == "phoneTrackUnmatched"
    assert all(r["status"] == "rejected" for r in rows.values())
    assert not list(settings.incoming_dir.iterdir())
    assert not list((settings.dataset_dir / "images").rglob("*.jpg"))
    assert teacher.calls == 2  # quality failures never reach the teacher


def test_worker_dedups_across_all_kept_frames(client, token, settings, store):
    img = textured_image(seed=7)
    first = _upload(client, token, img)
    process_batch(store, settings, FakeTeacher(), limit=10)
    second = _upload(client, token, img)  # same picture, new id
    process_batch(store, settings, FakeTeacher(), limit=10)
    with store.connect() as db:
        rows = {r["id"]: dict(r) for r in db.execute("SELECT id, status, reason FROM samples")}
    assert rows[first]["status"] == "kept"
    assert rows[second] == {"id": second, "status": "rejected", "reason": "duplicate"}


def test_worker_keeps_background_frames(client, token, settings, store):
    sid = _upload(client, token, textured_image(seed=8), tracks=[])
    process_batch(store, settings, FakeTeacher(default=[]), limit=10)
    split = dataset.choose_split(sid, False)
    assert dataset.label_path(settings, split, sid).read_text() == ""


def test_worker_teacher_error_retries_then_rejects(client, token, settings, store):
    class Broken:
        def predict(self, image):
            raise RuntimeError("boom")

    sid = _upload(client, token, textured_image(seed=9))
    for _ in range(settings.worker_max_attempts - 1):
        process_batch(store, settings, Broken(), limit=10)
        assert store.queued_samples(10)[0]["id"] == sid
    process_batch(store, settings, Broken(), limit=10)
    assert store.queued_samples(10) == []
    assert not list(settings.incoming_dir.iterdir())


def test_worker_run_once_with_fake_teacher(client, token, settings, store):
    from roadvis_trainer.worker import run

    _upload(client, token, textured_image(seed=10))
    _upload(client, token, textured_image(seed=11))
    run(settings, once=True, teacher=FakeTeacher())
    assert store.status_counts()["by_status"] == {"kept": 2}
    assert store.get_state("worker_last_run")


# Retention -----------------------------------------------------------------------------------------------------------
def test_retention_deletes_oldest_train_never_test(settings, store):
    settings.dataset_cap = 4
    order = [("t1", "test"), ("a", "train"), ("v1", "val"), ("b", "train"), ("t2", "test"), ("c", "train")]
    for i, (sid, split) in enumerate(order):
        store.insert_sample(sample_id=sid, device_id=1, meta={}, width=1, height=1)
        dataset.write_sample(settings, split, sid, b"jpg", "")
        store.mark_kept(sid, split, f"{i:016x}", 100, 100, 0)
        with store.connect() as db:
            db.execute("UPDATE samples SET processed_at=? WHERE id=?", (f"2026-11-26T10:00:0{i}Z", sid))
    assert dataset.apply_retention(store, settings) == 2
    with store.connect() as db:
        status = {r["id"]: r["status"] for r in db.execute("SELECT id, status FROM samples")}
    assert status == {"t1": "kept", "a": "evicted", "v1": "kept", "b": "evicted", "t2": "kept", "c": "kept"}
    assert not dataset.image_path(settings, "train", "a").exists()
    assert dataset.image_path(settings, "test", "t1").exists()
    # Only test left beyond val: test is never evicted.
    settings.dataset_cap = 1
    dataset.apply_retention(store, settings)
    with store.connect() as db:
        kept = {r["id"] for r in db.execute("SELECT id FROM samples WHERE status='kept'")}
    assert kept == {"t1", "t2"}


def test_retention_default_cap(settings):
    from roadvis_trainer.config import Settings

    assert Settings().dataset_cap == 50_000


def test_eval_view_remaps_labels_to_model_ids(settings, store):
    from roadvis_trainer.storage import Store  # noqa: F401

    dataset.write_sample(settings, "test", "x1", jpeg_bytes(textured_image(64, 36)),
                         "0 0.5 0.5 0.2 0.2\n6 0.1 0.1 0.05 0.1\n7 0.3 0.3 0.1 0.1\n")
    coco = {0: "person", 1: "bicycle", 2: "car", 3: "motorcycle", 4: "airplane", 5: "bus", 6: "train", 7: "truck",
            8: "boat", 9: "traffic light"}
    yaml_path, model_to_name, ids = dataset.build_eval_view(settings, coco, settings.tmp_dir / "view")
    lines = (settings.tmp_dir / "view" / "labels" / "test" / "x1.txt").read_text().splitlines()
    assert lines == ["2 0.5 0.5 0.2 0.2", "9 0.1 0.1 0.05 0.1"]  # stop_sign missing in this model → dropped
    assert model_to_name[9] == "traffic_light" and model_to_name[2] == "car"
    assert ids == [0, 1, 2, 3, 5, 7, 9]
    assert (settings.tmp_dir / "view" / "images" / "test" / "x1.jpg").is_symlink()
    assert json.loads(json.dumps(str(yaml_path)))


def test_cleanup_stale_receiving(settings, store):
    import os
    import time

    from roadvis_trainer.worker import cleanup_stale

    store.insert_sample(sample_id="s1", device_id=1, meta={}, width=1, height=1, status="receiving")
    store.insert_sample(sample_id="s2", device_id=1, meta={}, width=1, height=1, status="receiving")
    with store.connect() as db:
        db.execute("UPDATE samples SET received_at='2000-01-01T00:00:00Z' WHERE id='s1'")
    part = settings.incoming_dir / "s1.jpg.part-abcd"
    part.write_bytes(b"x")
    old = time.time() - 7200
    os.utime(part, (old, old))
    assert cleanup_stale(store, settings) == 1
    with store.connect() as db:
        status = {r["id"]: (r["status"], r["reason"]) for r in db.execute("SELECT id, status, reason FROM samples")}
    assert status == {"s1": ("rejected", "incompleteUpload"), "s2": ("receiving", None)}
    assert not part.exists()
