# Window Control API Docs

## 概要

この API は Windows 上のトップレベルウィンドウ情報を取得し、指定ウィンドウをアクティブ化します。

- ベース URL: http://127.0.0.1:8000
- 実装: FastAPI
- 対象 OS: Windows

## 起動方法

1. 依存パッケージをインストール
    - pip install fastapi uvicorn
2. サーバー起動
    - python main.py

環境変数:

- HOST (省略時: 0.0.0.0)
- PORT (省略時: 8000)

## 自動生成ドキュメント

FastAPI 標準のドキュメント UI:

- Swagger UI: http://127.0.0.1:8000/docs
- ReDoc: http://127.0.0.1:8000/redoc
- OpenAPI JSON: http://127.0.0.1:8000/openapi.json

## エンドポイント

### 0) WebSocket /ws

WebSocket で同等操作を実行できます。

- URL: ws://127.0.0.1:8000/ws
- 送受信形式: JSON

サポート action:

- list_windows
- activate
- ping

リクエスト例 (list_windows):
{
"action": "list_windows",
"taskbar_only": true,
"include_icon": false,
"include_exe": true
}

レスポンス例 (list_windows):
{
"action": "list_windows",
"ok": true,
"windows": [
{
"hwnd": 123456,
"title": "メモ帳",
"class_name": "Notepad",
"pid": 4321,
"visible": true,
"minimized": false,
"active": false,
"taskbar": true,
"exe_path": "C:\\Windows\\System32\\notepad.exe"
}
]
}

リクエスト例 (activate):
{
"action": "activate",
"hwnd": 123456
}

または:
{
"action": "activate",
"title": "メモ帳"
}

レスポンス例 (activate):
{
"action": "activate",
"ok": true,
"message": "activated",
"hwnd": 123456
}

エラーレスポンス例:
{
"action": "activate",
"ok": false,
"error": "window not found"
}

ping/pong 例:

送信:
{
"action": "ping"
}

受信:
{
"action": "pong",
"ok": true
}

### 1) GET /windows

ウィンドウ一覧を返します。

クエリパラメータ:

- taskbar_only: boolean (任意, 既定: true)
    - true: タスクバー相当のウィンドウのみ
    - false: 条件に合うトップレベルウィンドウを広く取得
- include_icon: boolean (任意, 既定: false)
    - true: icon_bmp_base64 を返す
    - false: アイコン情報なし
- include_exe: boolean (任意, 既定: false)
    - true: exe_path を返す
    - false: 実行ファイルパスなし

レスポンス 200:

- windows: 配列
    - hwnd: number
    - title: string
    - class_name: string
    - pid: number
    - visible: boolean
    - minimized: boolean
    - active: boolean
    - taskbar: boolean
    - icon_bmp_base64: string | null (include_icon=true の時のみ)
    - exe_path: string | null (include_exe=true の時のみ)

例:
{
"windows": [
{
"hwnd": 123456,
"title": "メモ帳",
"class_name": "Notepad",
"pid": 4321,
"visible": true,
"minimized": false,
"active": false,
"taskbar": true,
"icon_bmp_base64": "Qk0...",
"exe_path": "C:\\Windows\\System32\\notepad.exe"
}
]
}

呼び出し例:

- GET http://127.0.0.1:8000/windows
- GET http://127.0.0.1:8000/windows?taskbar_only=true&include_icon=true
- GET http://127.0.0.1:8000/windows?taskbar_only=true&include_exe=true

### 2) POST /activate

指定ウィンドウをアクティブ化します。

リクエストボディ (JSON):

- hwnd: number | null
- title: string | null

ルール:

- hwnd または title のどちらかが必要
- hwnd が指定される場合はそれを優先
- title 指定時は
    1. 完全一致検索
    2. 見つからなければ部分一致検索

リクエスト例 1 (hwnd 指定):
{
"hwnd": 123456
}

リクエスト例 2 (title 指定):
{
"title": "メモ帳"
}

成功レスポンス 200:
{
"ok": true,
"message": "activated",
"hwnd": 123456
}

エラーレスポンス:

- 400
    - detail: "provide hwnd or title"
- 404
    - detail: "window not found"
- 409
    - detail:
      {
      "ok": false,
      "message": "failed to activate window due to foreground restrictions",
      "hwnd": 123456
      }

呼び出し例:

- POST http://127.0.0.1:8000/activate

PowerShell 例:
Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:8000/activate" -ContentType "application/json" -Body '{"hwnd":123456}'

## 注意事項

- Windows の前面化制約により、条件によってはアクティブ化が失敗する場合があります。
- include_icon=true はレスポンスサイズが大きくなるため、必要時のみ利用してください。
- include_exe=true は権限不足などで exe_path が null になる場合があります。
- 一部アプリではアイコンが取得できず icon_bmp_base64 が null になる場合があります。
