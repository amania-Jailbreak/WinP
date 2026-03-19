from __future__ import annotations

import argparse
import logging
import pathlib
import sys
import time
from concurrent import futures
from typing import Optional
import traceback

import grpc

if __package__ is None or __package__ == "":
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))
    from windows.proto_loader import load_proto  # type: ignore
    from windows.window_service import close, diff_events, enumerate_windows, focus, move_resize  # type: ignore
else:
    from .proto_loader import load_proto
    from .window_service import close, diff_events, enumerate_windows, focus, move_resize

pb2, pb2_grpc = load_proto()
logger = logging.getLogger("winp.agent")


def _require_auth(context: grpc.ServicerContext, expected_token: str) -> bool:
    md = dict(context.invocation_metadata())
    value = md.get("authorization", "")
    expected = f"Bearer {expected_token}"
    if value != expected:
        logger.warning("auth failed peer=%s", context.peer())
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
        logger.info("Health peer=%s", context.peer())
        return pb2.HealthResponse(ok=True, message="ok", timestamp=int(time.time() * 1000))

    def StreamWindows(self, request, context):  # noqa: N802
        _require_auth(context, self._token)
        interval_ms = max(50, int(request.interval_ms or 250))
        logger.info("StreamWindows start peer=%s interval_ms=%d", context.peer(), interval_ms)
        prev = {}
        tick = 0
        while context.is_active():
            try:
                tick += 1
                cur = enumerate_windows()
                emitted = 0
                for kind, snapshot, removed_id in diff_events(prev, cur):
                    if kind == "upsert" and snapshot is not None:
                        emitted += 1
                        yield pb2.WindowEvent(type=pb2.WindowEvent.UPSERT, window=_window_info(snapshot))
                    elif kind == "remove" and removed_id is not None:
                        emitted += 1
                        yield pb2.WindowEvent(type=pb2.WindowEvent.REMOVE, window_id=int(removed_id))
                prev = cur
                if tick == 1 or emitted > 0 or tick % 20 == 0:
                    logger.info(
                        "StreamWindows tick=%d windows=%d emitted=%d peer=%s",
                        tick,
                        len(cur),
                        emitted,
                        context.peer(),
                    )
            except Exception:  # noqa: BLE001
                traceback.print_exc()
                logger.exception("StreamWindows loop error")
            time.sleep(interval_ms / 1000.0)
        logger.info("StreamWindows end peer=%s", context.peer())

    def MoveResize(self, request, context):  # noqa: N802
        _require_auth(context, self._token)
        ok, msg = move_resize(request.window_id, request.x, request.y, request.width, request.height)
        logger.info(
            "MoveResize peer=%s id=0x%08X x=%d y=%d w=%d h=%d ok=%s msg=%s",
            context.peer(),
            int(request.window_id),
            int(request.x),
            int(request.y),
            int(request.width),
            int(request.height),
            ok,
            msg,
        )
        return pb2.ControlResponse(ok=ok, message=msg)

    def Focus(self, request, context):  # noqa: N802
        _require_auth(context, self._token)
        ok, msg = focus(request.window_id)
        logger.info("Focus peer=%s id=0x%08X ok=%s msg=%s", context.peer(), int(request.window_id), ok, msg)
        return pb2.ControlResponse(ok=ok, message=msg)

    def Close(self, request, context):  # noqa: N802
        _require_auth(context, self._token)
        ok, msg = close(request.window_id)
        logger.info("Close peer=%s id=0x%08X ok=%s msg=%s", context.peer(), int(request.window_id), ok, msg)
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
    parser.add_argument("--cert")
    parser.add_argument("--key")
    parser.add_argument("--insecure", action="store_true", help="Allow non-TLS gRPC (development only)")
    parser.add_argument("--log-level", default="INFO", choices=["DEBUG", "INFO", "WARNING", "ERROR"])
    args = parser.parse_args(argv)
    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    if bool(args.cert) ^ bool(args.key):
        raise SystemExit("--cert and --key must be provided together")

    server = grpc.server(futures.ThreadPoolExecutor(max_workers=8))
    pb2_grpc.add_WindowControlServiceServicer_to_server(WindowControlService(args.token), server)
    bind = f"{args.host}:{args.port}"
    use_tls = bool(args.cert and args.key and not args.insecure)
    if use_tls:
        server.add_secure_port(bind, _server_credentials(args.cert, args.key))
    else:
        server.add_insecure_port(bind)
    server.start()
    mode = "tls" if use_tls else "insecure"
    logger.info("window-control-agent listening %s (%s)", bind, mode)
    try:
        server.wait_for_termination()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
