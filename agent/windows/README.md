# WinP Windows Agent (gRPC/TLS)

## Setup
```powershell
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

## Run server
### TLS (recommended)
```powershell
python -m windows.server --host 0.0.0.0 --port 50051 --token YOUR_TOKEN --cert server.crt --key server.key
# or
python windows\server.py --host 0.0.0.0 --port 50051 --token YOUR_TOKEN --cert server.crt --key server.key
```

### No cert/key (insecure, development)
```powershell
python -m windows.server --host 0.0.0.0 --port 50051 --token YOUR_TOKEN --insecure
# or
python windows\server.py --host 0.0.0.0 --port 50051 --token YOUR_TOKEN --insecure
```

## Swift bridge command behavior
- Swift client executes `client_bridge.py` as a subprocess.
- Bridge connects to the Windows agent over gRPC/TLS.
- Common args:
  - `--host`
  - `--port`
  - `--token`
  - `--tls`
  - `--ca-cert` (optional)

Examples:
```powershell
python windows\client_bridge.py --host 127.0.0.1 --port 50051 --token YOUR_TOKEN --tls health
python windows\client_bridge.py --host 127.0.0.1 --port 50051 --token YOUR_TOKEN --tls stream
python windows\client_bridge.py --host 127.0.0.1 --port 50051 --token YOUR_TOKEN --tls focus --window-id 12345
python windows\client_bridge.py --host 127.0.0.1 --port 50051 --token YOUR_TOKEN health
```
