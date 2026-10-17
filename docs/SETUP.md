# Set up Nova

Install Nova on the Mac and iPhone, pair them, choose what the AI may use, connect a key, and start.

## On the Mac

1. Install [Tailscale](https://tailscale.com/download/mac) and sign in.
2. From this checkout: `npm test`, then `npm run service:install`.
3. Build and install the menu-bar app: `NOVA_MAC_SIGN_IDENTITY=… npm run operator:build` then `npm run operator:install`.
4. Open **Set Up Nova…** from the Nova Operator menu (or it opens itself when nothing is paired).
5. If private access is off, tap **Turn On Private Access**. Core stays on loopback; Tailscale Serve publishes it only to your tailnet. Do not turn on Funnel.
6. Tap **Show Pairing Code**. Scan the QR with the iPhone app, or type the eight-character code. Codes last 10 minutes and work once. Turn **This iPhone controls the Mac** on for your own phone.

Existing installs keep whole-Mac control and the Claude key. A key in `.env.local` still works; **Move Claude Key to the Keychain** (or `node core/cli.mjs key import`) copies it into the login Keychain without printing it. You can delete `.env.local` afterward.

## On the iPhone

1. Install Tailscale with the **same account** and open Nova.
2. Meet Nova, then scan the Mac's QR (or type the short code and the `https://…ts.net` address).
3. Confirm the computer name and address before pairing.
4. Choose a range: Just chat, Chosen apps & folders, or Whole Mac. Whole Mac asks for Face ID (or device passcode).
5. If the range needs the Mac, tap **Ask on my Mac** so Accessibility and Screen Recording prompts appear there. Granting stays your choice in System Settings.
6. Connect a Claude or OpenAI API key. OpenAI API use is billed separately from ChatGPT Plus or Pro. The key is stored on the Mac, not on the phone.
7. The Ready screen shows the computer, range, provider and connection. Tap **Start using Nova**.

A USB cable does not pair the app. Pairing is wireless.

## After setup

- Tap Nova's face to talk. Press and hold for Home: status, a typed task, a schedule or monitor, take control, stop, range, AI and devices.
- **Take control** pauses a running Nova task. **Hand back** lets it continue from a fresh screenshot. If you never hand back, the task ends when the five-minute takeover window lapses.
- **Emergency stop** on the phone or Control-Option-S on the Mac still stops everything. Resume only from the Mac (`npm run resume` or the button in Set Up Nova).
- Change or revoke range, keys and devices any time from Home or the Mac window.

## Commands

`node core/cli.mjs pair [--owner] [--json]` · `setup --json` · `serve on` · `key set|remove|test anthropic|openai` (key on stdin) · `key import` · `provider anthropic|openai` · `access chat|full` · `resume` · `devices` · `revoke DEVICE_ID` · `imessage [+NUMBER|EMAIL|off]`

## Current users

Matthew's Mac already has an owner iPhone, range `full`, and the Claude key in the Keychain. Open Nova on the phone; the first launch after this update shows Ready once, then the face.
