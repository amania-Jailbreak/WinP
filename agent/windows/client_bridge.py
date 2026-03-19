from __future__ import annotations

import argparse
import json
import os
import pathlib
import sys
from typing import Optional

import grpc

if __package__ is None or __package__ == "":
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
    from windows.proto_loader import load_proto  # type: ignore
else:
    from .proto_loader import load_proto

pb2, pb2_grpc = load_proto()


def _metadata(token: str):
    return [("authorization", f"Bearer {token}")]


def _channel(host: str, port: int, tls: bool, ca_cert: Optional[str]):
    target = f"{host}:{port}"
    if tls:
        root = open(ca_cert, "rb").read() if ca_cert else None
        creds = grpc.ssl_channel_credentials(root_certificates=root)
        return grpc.secure_channel(target, creds)
    return grpc.insecure_channel(target)


def _base_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser()
    p.add_argument("--host", required=True)
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--token", required=True)
    p.add_argument("--tls", action="store_true")
    p.add_argument("--ca-cert")
    return p


def _json_print(payload):
    print(json.dumps(payload, ensure_ascii=False), flush=True)


def _health(args):
    with _channel(args.host, args.port, args.tls, args.ca_cert) as ch:
        stub = pb2_grpc.WindowControlServiceStub(ch)
        resp = stub.Health(pb2.Empty(), metadata=_metadata(args.token), timeout=5)
        _json_print({"ok": bool(resp.ok), "message": resp.message, "timestamp": int(resp.timestamp)})
        return 0 if resp.ok else 1


def _stream(args):
    with _channel(args.host, args.port, args.tls, args.ca_cert) as ch:
        stub = pb2_grpc.WindowControlServiceStub(ch)
        for ev in stub.StreamWindows(pb2.StreamWindowsRequest(interval_ms=250), metadata=_metadata(args.token)):
            if ev.type == pb2.WindowEvent.UPSERT and ev.window is not None:
                w = ev.window
                _json_print(
                    {
                        "event": "upsert",
                        "window": {
                            "window_id": int(w.window_id),
                            "title": w.title,
                            "pid": int(w.pid),
                            "x": int(w.rect.x),
                            "y": int(w.rect.y),
                            "width": int(w.rect.width),
                            "height": int(w.rect.height),
                            "visible": bool(w.visible),
                            "minimized": bool(w.minimized),
                            "maximized": bool(w.maximized),
                            "z_order": int(w.z_order),
                            "monitor_id": int(w.monitor_id),
                            "timestamp": int(w.timestamp),
                        },
                    }
                )
            elif ev.type == pb2.WindowEvent.REMOVE:
                _json_print({"event": "remove", "window_id": int(ev.window_id)})
    return 0


def _move_resize(args):
    with _channel(args.host, args.port, args.tls, args.ca_cert) as ch:
        stub = pb2_grpc.WindowControlServiceStub(ch)
        resp = stub.MoveResize(
            pb2.MoveResizeRequest(
                window_id=int(args.window_id),
                x=int(args.x),
                y=int(args.y),
                width=int(args.width),
                height=int(args.height),
            ),
            metadata=_metadata(args.token),
            timeout=5,
        )
        _json_print({"ok": bool(resp.ok), "message": resp.message})
        return 0 if resp.ok else 2


def _focus(args):
    with _channel(args.host, args.port, args.tls, args.ca_cert) as ch:
        stub = pb2_grpc.WindowControlServiceStub(ch)
        resp = stub.Focus(pb2.FocusRequest(window_id=int(args.window_id)), metadata=_metadata(args.token), timeout=5)
        _json_print({"ok": bool(resp.ok), "message": resp.message})
        return 0 if resp.ok else 2


def _close(args):
    with _channel(args.host, args.port, args.tls, args.ca_cert) as ch:
        stub = pb2_grpc.WindowControlServiceStub(ch)
        resp = stub.Close(pb2.CloseRequest(window_id=int(args.window_id)), metadata=_metadata(args.token), timeout=5)
        _json_print({"ok": bool(resp.ok), "message": resp.message})
        return 0 if resp.ok else 2


def main(argv: Optional[list[str]] = None) -> int:
    parser = _base_parser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("health")
    sub.add_parser("stream")

    p_mr = sub.add_parser("move-resize")
    p_mr.add_argument("--window-id", type=int, required=True)
    p_mr.add_argument("--x", type=int, required=True)
    p_mr.add_argument("--y", type=int, required=True)
    p_mr.add_argument("--width", type=int, required=True)
    p_mr.add_argument("--height", type=int, required=True)

    p_focus = sub.add_parser("focus")
    p_focus.add_argument("--window-id", type=int, required=True)

    p_close = sub.add_parser("close")
    p_close.add_argument("--window-id", type=int, required=True)

    args = parser.parse_args(argv)
    try:
        if args.cmd == "health":
            return _health(args)
        if args.cmd == "stream":
            return _stream(args)
        if args.cmd == "move-resize":
            return _move_resize(args)
        if args.cmd == "focus":
            return _focus(args)
        if args.cmd == "close":
            return _close(args)
        _json_print({"ok": False, "message": "unknown command"})
        return 3
    except grpc.RpcError as exc:
        _json_print({"ok": False, "message": f"grpc error: {exc.code().name}: {exc.details()}"})
        return 10
    except Exception as exc:  # noqa: BLE001
        _json_print({"ok": False, "message": str(exc)})
        return 11


if __name__ == "__main__":
    raise SystemExit(main())
