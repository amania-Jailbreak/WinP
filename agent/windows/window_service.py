from __future__ import annotations

import dataclasses
import time
from typing import Dict, Iterable, List, Optional, Tuple

import win32con
import win32gui
import win32process
import win32service


@dataclasses.dataclass
class WindowSnapshot:
    window_id: int
    title: str
    pid: int
    x: int
    y: int
    width: int
    height: int
    visible: bool
    minimized: bool
    maximized: bool
    z_order: int
    monitor_id: int
    timestamp: int


def _rect(hwnd: int) -> Tuple[int, int, int, int]:
    left, top, right, bottom = win32gui.GetWindowRect(hwnd)
    return left, top, max(1, right - left), max(1, bottom - top)


def _monitor_index(hwnd: int) -> int:
    monitor = win32gui.MonitorFromWindow(hwnd, win32con.MONITOR_DEFAULTTONEAREST)
    return int(monitor) & 0x7FFFFFFF


def _is_manageable(hwnd: int) -> bool:
    if not win32gui.IsWindow(hwnd):
        return False
    # Debug-first: do not over-filter here.
    return True


def enumerate_windows() -> Dict[int, WindowSnapshot]:
    handles: List[int] = []

    def _cb(hwnd: int, _: int) -> bool:
        handles.append(hwnd)
        return True

    win32gui.EnumWindows(_cb, 0)
    if not handles:
        # Fallback: if agent is not on the default interactive desktop context,
        # try input desktop enumeration explicitly.
        try:
            hdesk = win32service.OpenInputDesktop(0, False, win32con.MAXIMUM_ALLOWED)
            try:
                win32gui.EnumDesktopWindows(hdesk, _cb, 0)
            finally:
                win32service.CloseDesktop(hdesk)
        except Exception:  # noqa: BLE001
            pass
    now = int(time.time() * 1000)
    result: Dict[int, WindowSnapshot] = {}
    z = len(handles)
    for hwnd in handles:
        z -= 1
        if not _is_manageable(hwnd):
            continue

        title = ""
        pid = 0
        x, y, w, h = 0, 0, 1, 1
        visible = False
        minimized = False
        maximized = False
        monitor_id = 0

        try:
            title = win32gui.GetWindowText(hwnd) or ""
        except Exception:  # noqa: BLE001
            pass
        try:
            _, pid = win32process.GetWindowThreadProcessId(hwnd)
        except Exception:  # noqa: BLE001
            pass
        try:
            x, y, w, h = _rect(hwnd)
        except Exception:  # noqa: BLE001
            pass
        try:
            visible = bool(win32gui.IsWindowVisible(hwnd))
        except Exception:  # noqa: BLE001
            pass
        try:
            minimized = bool(win32gui.IsIconic(hwnd))
        except Exception:  # noqa: BLE001
            pass
        try:
            maximized = bool(win32gui.IsZoomed(hwnd))
        except Exception:  # noqa: BLE001
            pass
        try:
            monitor_id = _monitor_index(hwnd)
        except Exception:  # noqa: BLE001
            pass

        result[hwnd] = WindowSnapshot(
            window_id=hwnd,
            title=title,
            pid=pid,
            x=x,
            y=y,
            width=w,
            height=h,
            visible=visible,
            minimized=minimized,
            maximized=maximized,
            z_order=z,
            monitor_id=monitor_id,
            timestamp=now,
        )
    return result


def move_resize(hwnd: int, x: int, y: int, width: int, height: int) -> Tuple[bool, str]:
    if not win32gui.IsWindow(hwnd):
        return False, "window not found"
    try:
        win32gui.SetWindowPos(
            hwnd,
            0,
            int(x),
            int(y),
            max(1, int(width)),
            max(1, int(height)),
            win32con.SWP_NOZORDER | win32con.SWP_NOACTIVATE,
        )
        return True, "ok"
    except Exception as exc:  # noqa: BLE001
        return False, str(exc)


def focus(hwnd: int) -> Tuple[bool, str]:
    if not win32gui.IsWindow(hwnd):
        return False, "window not found"
    try:
        win32gui.ShowWindow(hwnd, win32con.SW_RESTORE)
        win32gui.SetForegroundWindow(hwnd)
        return True, "ok"
    except Exception as exc:  # noqa: BLE001
        return False, str(exc)


def close(hwnd: int) -> Tuple[bool, str]:
    if not win32gui.IsWindow(hwnd):
        return False, "window not found"
    try:
        win32gui.PostMessage(hwnd, win32con.WM_CLOSE, 0, 0)
        return True, "ok"
    except Exception as exc:  # noqa: BLE001
        return False, str(exc)


def diff_events(prev: Dict[int, WindowSnapshot], cur: Dict[int, WindowSnapshot]) -> Iterable[Tuple[str, Optional[WindowSnapshot], Optional[int]]]:
    for wid, snapshot in cur.items():
        before = prev.get(wid)
        if before != snapshot:
            yield "upsert", snapshot, None
    for wid in prev.keys():
        if wid not in cur:
            yield "remove", None, wid
