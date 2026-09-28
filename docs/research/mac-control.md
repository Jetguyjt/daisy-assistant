# Controlling the Mac and Chrome

Checked 2026-09-25 to 09-27: Chrome 154, `chrome-devtools-mcp` 1.10.1, Hermes 0.21.0, macOS 26.5.1. Nothing was run against my real browser or desktop.

The goal: "search Google for…", "check my email" → go to Chrome, use the Gmail tab if one is open, otherwise open one. More control of the laptop in general.

## Where things stand

- **Connect Chrome only feeds the local fallback.** It runs `chrome-devtools-mcp --autoConnect` and hands the tools to `LocalBackend` only. It's never saved between launches.
- **Hermes has its own browser.** It browses with a headless Chromium (`agent-browser`) that has no cookies, so it never sees signed-in tabs.
- **ACP sessions get a fixed toolset.** Every one gets `hermes-acp` plus `mcp-<server>` (`acp_adapter/session.py:390`). `hermes-acp` leaves out `computer_use` (`toolsets.py:66,183`), and `platform_toolsets` in `config.yaml` is ignored for ACP, so turning a tool on with `hermes tools` never reaches Daisy.
- **Three ways to add tools to Daisy sessions:**
  - `mcp_servers`
  - a plugin tool registered with `toolset="hermes-acp"` (`hermes_cli/plugins.py:449`). This is the clean hook, and the `hermes/daisy` plugin already exists.
  - patching Hermes
- **Google search already works.** `web_search` needs no key: with no backend set it falls back to free public endpoints (`plugins/web/keyless_mcp.py`). They're rate limited, and a Brave key is the free upgrade.

## Chrome options

| Route | Prompts | Sees my open tabs | Notes |
| --- | --- | --- | --- |
| AppleScript / JXA from plugin tools | One macOS Automation prompt, once | Yes: window, tab index, title, URL; can set the active tab | Chrome 154 still ships `scripting.sdef`. Leave "Allow JavaScript from Apple Events" off, or any app with Automation access can run JS inside Gmail |
| `chrome-devtools-mcp --autoConnect` in `mcp_servers` | Chrome asks "every time the server requests a remote debugging session" ([Chrome blog](https://developer.chrome.com/blog/chrome-devtools-mcp-debug-your-browser-session)). Hermes keeps MCP servers up for the life of `hermes-acp`, so probably once per launch (not measured) | Yes (`list_pages`, `select_page`) | Also shows the "controlled by automated software" banner. Good for clicking and filling forms |
| Playwright MCP extension mode | Per connection unless a token is set | One chosen tab | Weak for "find my Gmail tab" |
| Hermes `use_real_profile` | None | No, it's a second Chrome on a copy of my profile | Extra RAM on top of ~12 GB; the copy goes stale |
| Own MV3 extension + native messaging | None | Yes | 3–5 days of work; only if AppleScript falls short |

## Other apps

- **`computer_use` is already on this Mac** (`~/.local/bin/cua-driver`, `/Applications/CuaDriver.app`). Hermes's version is an MCP client to `cua-driver mcp`.
- **How it drives apps:** in the background through private macOS APIs, so an OS update can break it. It reads the screen as screenshots with numbered elements, or as the accessibility tree.
- **Built-in safety:** it hard-blocks logout/shutdown keys and dangerous typed text (`tools/computer_use/tool.py:36-62`).
- **Permissions:** Accessibility and Screen Recording for CuaDriver, not for Daisy.
- **Model:** it works with any model; OpenAI's computer-use model isn't needed.
- **To use it from Daisy:** wrap the built-in handler in a plugin tool, which keeps the hard-blocks. Adding `cua-driver mcp` as a raw MCP server would skip them.
- **Not checked:** how its approval prompt behaves over ACP.

## Plan

1. **Web research.** Hermes `web_search` / `web_extract` as they are.
2. **Real Chrome tabs.** Plugin tools `chrome_tabs`, `chrome_focus`, `chrome_open` over `osascript`, plus a short `daisy-chrome` skill that says to reuse a tab before opening a new one.
   - "Search Google" = `chrome_open("https://www.google.com/search?q=…")` when I want to see it.
3. **Other apps and reading pages.** `computer_use` through a plugin tool, using accessibility-tree captures.
4. **Maybe.** `chrome-devtools-mcp` in `mcp_servers` for form work, if the consent prompt turns out to be once per launch.
5. **Daisy side.** Auto-connect the old Chrome adapter at launch for the local fallback, or retire it.

### "Check my email"

1. `chrome_tabs` looks for `mail.google.com`.
2. If there's a match, `chrome_focus` switches to it. If not, `chrome_open("https://mail.google.com/")`.
3. The inbox itself comes from the Gmail API ([google.md](google.md)), not from scraping the page. Fallback: a `computer_use` accessibility capture.
4. Daisy reads a short summary aloud. Replying, archiving or deleting goes through an approval card.

## Guard gaps

`hermes/daisy/__init__.py` `classify()` only flags tool names with send/delete/pay-type words. These would pass without a card:

- chrome-devtools `click` / `fill` / `fill_form` / `press_key` / `evaluate_script` on mail, payment or account pages
- `computer_use` `type` and `key(return)` in Chrome or Mail
- `chrome_open` with a `javascript:` URL

Each needs a rule and a line in `test_daisy_guard.py`.

## Effort

| Piece | Estimate |
| --- | --- |
| Chrome tab tools + skill + guard rules + tests | about a day |
| `computer_use` in ACP, including checking approvals | half a day to a day |
| `chrome-devtools-mcp` config and measuring the prompt | about an hour |
| MV3 extension | 3–5 days, only if needed |

## Not checked yet

- How often the Chrome consent prompt shows up in practice
- Whether Chrome AppleScript works live on this Mac
- `computer_use` approvals over ACP
