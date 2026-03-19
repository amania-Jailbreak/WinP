from __future__ import annotations

import importlib
import pathlib
import sys
from typing import Tuple


def load_proto() -> Tuple[object, object]:
    base = pathlib.Path(__file__).resolve().parent
    proto = base / "window_control.proto"
    out = base / ".generated"
    out.mkdir(exist_ok=True)

    pb2 = out / "window_control_pb2.py"
    pb2_grpc = out / "window_control_pb2_grpc.py"
    if not pb2.exists() or not pb2_grpc.exists():
        try:
            from grpc_tools import protoc
        except ModuleNotFoundError as exc:
            raise RuntimeError(
                "grpc_tools is required to generate gRPC stubs. "
                "Install with: pip install grpcio-tools"
            ) from exc
        rc = protoc.main(
            [
                "grpc_tools.protoc",
                f"-I{base}",
                f"--python_out={out}",
                f"--grpc_python_out={out}",
                str(proto),
            ]
        )
        if rc != 0:
            raise RuntimeError(f"protoc failed: {rc}")

    if str(out) not in sys.path:
        sys.path.insert(0, str(out))
    return importlib.import_module("window_control_pb2"), importlib.import_module("window_control_pb2_grpc")
