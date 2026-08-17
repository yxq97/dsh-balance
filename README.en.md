# DSH Balance — DeepSeek Balance Monitor & Token Consumption Charts (macOS Menu Bar)

A lightweight macOS menu bar app that shows your real-time DeepSeek (or other compatible providers) balance at the top of your screen, with consumption line charts, API key management, one-click top-up, and configurable refresh intervals.

Pure native Swift / AppKit. **Zero third-party dependencies** — fully auditable source code.

## Features

- **Real-time balance in the menu bar**: refreshes every 60s by default (configurable: 5/10/30/60s), updates instantly on change
- **Consumption line charts**: click the icon → "Consumption Chart", four views:
  - **15 min**: last hour, one point every 15 minutes
  - **Daily**: last 14 days
  - **Weekly**: last 8 weeks
  - **Monthly**: last 6 months
- **Y-axis in million tokens (M)**: amount → tokens converted using a price per million tokens (default ¥2.5, matching deepseek-v4-flash blended pricing; configurable)
- **Multi-provider support**: built-in provider list matching DSH (anthropic, google, groq, mistral…); selecting a provider auto-fills its official Base URL. Custom third-party relays supported (DeepSeek style / OpenAI style / custom balance API path)
- **API key management**: configure keys in-app (stored locally, file permissions 600); official DeepSeek mode can fall back to the DSH credentials file `~/.dsh/.credentials.yaml`
- **One-click top-up**: menu item opens the DeepSeek platform recharge page
- **Auto-launch**: LaunchAgent keeps it running at login, auto-restarts on crash

## Installation

### Option 1: Build from source (recommended, auditable)

```bash
git clone https://github.com/yxq97/dsh-balance.git
cd dsh-balance
swiftc -parse-as-library -swift-version 5 -framework Cocoa -o DSHBalance DSHBalance.swift
# Package as .app
mkdir -p "DSH Balance.app/Contents/MacOS"
cp DSHBalance "DSH Balance.app/Contents/MacOS/DSHBalance"
cp Info.plist "DSH Balance.app/Contents/Info.plist"
codesign -s - --force "DSH Balance.app"
cp -R "DSH Balance.app" /Applications/
```

### Option 2: Run the binary directly

```bash
swiftc -parse-as-library -swift-version 5 -framework Cocoa -o DSHBalance DSHBalance.swift
./DSHBalance
```

### Launch at login (optional)

```bash
mkdir -p ~/Library/LaunchAgents
cat > ~/Library/LaunchAgents/com.local.DSHBalance.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.local.DSHBalance</string>
    <key>ProgramArguments</key>
    <array><string>/Applications/DSH Balance.app/Contents/MacOS/DSHBalance</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
</dict>
</plist>
EOF
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.local.DSHBalance.plist
```

## Usage

1. On first launch: click the balance icon in the menu bar → **Configure API Key…**
2. Pick a provider (official DeepSeek or a third-party relay) and enter the API key; the Base URL is auto-filled from the provider preset
3. Choose the balance API style that matches: DeepSeek style `/user/balance`, OpenAI style `/v1/dashboard/billing/credit_grants`, or a custom path
4. For accurate token estimates, adjust the "price per million tokens" in the config dialog

## Data & Privacy

- API key is stored only locally: `~/Library/Application Support/DSH Balance/config.json` (permissions 600)
- Balance history (change points only): `~/Library/Application Support/DSH Balance/history.jsonl` (local, powers the charts)
- Logs: `~/Library/Logs/dshbalance.log`
- No data is uploaded anywhere; the app only calls the balance endpoint

## CLI

```bash
./DSHBalance --check        # query balance once using the DSH credentials file key
./DSHBalance --check-chart  # print aggregated consumption for the current data source
```

## Notes

- Token consumption is an **estimate** derived from balance deltas; accuracy depends on how well the configured price matches your actual models/usage
- Most model providers (anthropic, google, groq, etc.) do not expose an official balance API — a failed query is expected. If you use a relay that supports balance queries, point the Base URL at the relay
- This is a personal tool, not an official DeepSeek product

## License

MIT
