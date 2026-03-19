from __future__ import annotations

import argparse
import time
from concurrent import futures
from typing import Optional

import grpc

from .proto_loader import load_proto
from .window_service import close, diff_events, enumerate_windows, focus, move_resize

pb2, pb2_grpc = load_proto()


def _require_auth(context: grpc.ServicerContext, expected_token: str) -> bool:
    md = dict(context.invocation_metadata())
    value = md.get("authorization", "")
    expected = f"Bearer {expected_token}"
    if value != expected:
        context.abort(grpc.StatusCode.UNAUTHENTICATED, "invalid token")
    return True


def _window_info(snapshot):
    return pb2.WindowInfo(
        window_id=int(snapshot.window_id),
        title=snapshot.title,
        pid=int(snapshot.pid),
        rect=pb2.WindowRect(x=snapshot.x, y=snapshot.y, width=snapshot.width, height=snapshot.height),
        visible=snapshot.visible,
        minimized=snapshot.minimized,
        maximized=snapshot.maximized,
        z_order=snapshot.z_order,
        monitor_id=snapshot.monitor_id,
        timestamp=snapshot.timestamp,
    )


class WindowControlService(pb2_grpc.WindowControlServiceServicer):
    def __init__(self, token: str):
        self._token = token

    def Health(self, request, context):  # noqa: N802
        _require_auth(context, self._token)
        return pb2.HealthResponse(ok=True, message="ok", timestamp=int(time.time() * 1000))

    def StreamWindows(self, request, context):  # noqa: N802
        _require_auth(context, self._token)
        interval_ms = max(50, int(request.interval_ms or 250))
        prev = {}
        while context.is_active():
            cur = enumerate_windows()
            for kind, snapshot, removed_id in diff_events(prev, cur):
                if kind == "upsert" and snapshot is not None:
                    yield pb2.WindowEvent(type=pb2.WindowEvent.UPSERT, window=_window_info(snapshot))
                elif kind == "remove" and removed_id is not None:
                    yield pb2.WindowEvent(type=pb2.WindowEvent.REMOVE, window_id=int(removed_id))
            prev = cur
            time.sleep(interval_ms / 1000.0)

    def MoveResize(self, request, context):  # noqa: N802
        _require_auth(context, self._token)
        ok, msg = move_resize(request.window_id, request.x, request.y, request.width, request.height)
        return pb2.ControlResponse(ok=ok, message=msg)

    def Focus(self, request, context):  # noqa: N802
        _require_auth(context, self._token)
        ok, msg = focus(request.window_id)
        return pb2.ControlResponse(ok=ok, message=msg)

    def Close(self, request, context):  # noqa: N802
        _require_auth(context, self._token)
        ok, msg = close(request.window_id)
        return pb2.ControlResponse(ok=ok, message=msg)


def _server_credentials(cert_path: str, key_path: str):
    cert = open(cert_path, "rb").read()
    key = open(key_path, "rb").read()
    return grpc.ssl_server_credentials(((key, cert),))


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=50051)
    parser.add_argument("--token", required=True)
    parser.add_argument("--cert", required=True)
    parser.add_argument("--key", required=True)
    args = parser.parse_args(argv)

    server = grpc.server(futures.ThreadPoolExecutor(max_workers=8))
    pb2_grpc.add_WindowControlServiceServicer_to_server(WindowControlService(args.token), server)
    server.add_secure_port(f"{args.host}:{args.port}", _server_credentials(args.cert, args.key))
    server.start()
    print(f"window-control-agent listening {args.host}:{args.port}", flush=True)
    try:
        server.wait_for_termination()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
