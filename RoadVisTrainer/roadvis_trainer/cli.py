"""Command line: ``roadvis-trainer serve | worker | token | train | gate | publish | status``."""

from __future__ import annotations

import argparse
import json
import logging
import sys
from pathlib import Path

from .config import Settings, load_env_file


def _setup_logging(verbose: bool = False) -> None:
    logging.basicConfig(level=logging.DEBUG if verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")


def cmd_serve(args, settings: Settings) -> int:
    import uvicorn

    from .api import create_app

    app = create_app(settings)
    # ROOT_PATH is applied inside the app (RootPathMiddleware); proxy_headers so X-Forwarded-* from nginx are honoured.
    uvicorn.run(app, host=args.host, port=args.port, proxy_headers=True,
                forwarded_allow_ips=args.forwarded_allow_ips, log_level="info")
    return 0


def cmd_worker(args, settings: Settings) -> int:
    from .worker import limit_cpu, run

    limit_cpu(settings.worker_threads)
    run(settings, once=args.once)
    return 0


def cmd_token(args, settings: Settings) -> int:
    from .storage import Store

    store = Store(settings.db_path)
    if args.token_cmd == "create":
        token = store.create_token(args.name)
        print(f"Device token for '{args.name}' (shown only once, store it in the app's settings):")
        print(token)
        return 0
    if args.token_cmd == "list":
        rows = store.list_tokens()
        if not rows:
            print("no tokens")
        for r in rows:
            state = f"revoked {r['revoked_at']}" if r["revoked_at"] else "active"
            print(f"{r['id']:>4}  {r['name']:<24} created {r['created_at']}  last used {r['last_used_at'] or '-':<20}"
                  f"  {state}")
        return 0
    if args.token_cmd == "revoke":
        n = store.revoke_token(args.ident)
        print(f"revoked {n} token(s)")
        return 0 if n else 1
    return 2


def cmd_train(args, settings: Settings) -> int:
    from .training import COLAB_INSTRUCTIONS, NOTEBOOK_REL, github_colab_url, train_local, write_notebook

    if args.colab:
        out = write_notebook(Path(args.out or NOTEBOOK_REL), server=args.server)
        url = github_colab_url(out)
        link = f"One-click link (after the notebook is pushed): {url}" if url else \
            "No GitHub remote found: upload the file in Colab (File → Upload notebook)."
        print(COLAB_INSTRUCTIONS.format(path=out.resolve(), link=link, server=args.server.rstrip("/")))
        return 0
    settings.ensure_dirs()
    best = train_local(settings, epochs=args.epochs, imgsz=args.imgsz, batch=args.batch, max_images=args.max_images,
                       submit=not args.no_submit, force=args.force, init=args.init)
    print(f"best.pt: {best}")
    if not args.no_submit:
        print("Submitted as a candidate; the worker gates it on its next pass (or run: roadvis-trainer worker --once).")
    return 0


def cmd_gate(args, settings: Settings) -> int:
    from .gate import run_gate
    from .storage import Store
    from .worker import limit_cpu

    limit_cpu(settings.worker_threads)
    report = run_gate(Store(settings.db_path), settings, args.candidate)
    print(json.dumps({k: report.get(k) for k in ("status", "decision", "publishedVersion")}, indent=2, default=str))
    return 0 if report.get("status") == "accepted" else 1


def cmd_status(args, settings: Settings) -> int:
    from .storage import Store

    store = Store(settings.db_path)
    out = {"samples": store.status_counts(), "candidates": store.recent_candidates(5),
           "versions": [v["version"] for v in store.published_versions()],
           "worker_heartbeat": store.get_state("worker_heartbeat")}
    print(json.dumps(out, indent=2))
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="roadvis-trainer", description="RoadVis continuous-learning server")
    p.add_argument("-v", "--verbose", action="store_true")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("serve", help="run the HTTP API (uvicorn)")
    s.add_argument("--host", default="127.0.0.1")
    s.add_argument("--port", type=int, default=8601)
    s.add_argument("--forwarded-allow-ips", default="127.0.0.1")
    s.set_defaults(func=cmd_serve)

    w = sub.add_parser("worker", help="process queued samples and pending candidates")
    w.add_argument("--once", action="store_true", help="drain the queue once and exit")
    w.set_defaults(func=cmd_worker)

    t = sub.add_parser("token", help="manage device tokens")
    tsub = t.add_subparsers(dest="token_cmd", required=True)
    tc = tsub.add_parser("create", help="create a device token (printed once)")
    tc.add_argument("--name", required=True)
    tsub.add_parser("list", help="list tokens (never shows token values)")
    tr = tsub.add_parser("revoke", help="revoke a token by id or name")
    tr.add_argument("ident")
    t.set_defaults(func=cmd_token)

    tr_ = sub.add_parser("train", help="train: Colab notebook (GPU) or a short local CPU run")
    mode = tr_.add_mutually_exclusive_group(required=True)
    mode.add_argument("--colab", action="store_true", help="write colab/RoadVis_train.ipynb and print instructions")
    mode.add_argument("--local", action="store_true", help="short CPU fine-tune on this server (small datasets)")
    tr_.add_argument("--out", help="notebook path (default colab/RoadVis_train.ipynb)")
    tr_.add_argument("--server", default="https://trafficcounter.uz/roadvis", help="server URL prefilled in the notebook")
    tr_.add_argument("--epochs", type=int, default=10)
    tr_.add_argument("--imgsz", type=int, default=640)
    tr_.add_argument("--batch", type=int, default=8)
    tr_.add_argument("--max-images", type=int, default=3000)
    tr_.add_argument("--init", help="initial weights (default: current accepted model, else yolo11s.pt)")
    tr_.add_argument("--force", action="store_true", help="train locally even on a large dataset")
    tr_.add_argument("--no-submit", action="store_true", help="do not submit best.pt as a candidate")
    tr_.set_defaults(func=cmd_train)

    g = sub.add_parser("gate", help="run the quality gate for a pending candidate now")
    g.add_argument("candidate")
    g.set_defaults(func=cmd_gate)

    st = sub.add_parser("status", help="print counts, candidates and versions")
    st.set_defaults(func=cmd_status)
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    _setup_logging(args.verbose)
    load_env_file()
    settings = Settings.from_env()
    return args.func(args, settings) or 0


if __name__ == "__main__":
    sys.exit(main())
