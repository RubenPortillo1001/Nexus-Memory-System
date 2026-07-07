# Integrating Nexus with Claude Code and Claude Desktop

This guide sets up Nexus Memory System as a persistent, shared memory layer across
**Claude Code** (CLI, all sessions) and **Claude Desktop** (the desktop app). It is written
for the current release (`v1.3.2`) and uses the commands that the shipping `nexus` binary
actually exposes.

> **Command correction vs. older write-ups:** Nexus serves MCP over stdio with
> `nexus serve --transport stdio`. There is **no** `nexus mcp start` command — older guides
> that use it are wrong for this version and will break the MCP registration. The
> introspection command is `nexus representation` (not `nexus represent`).

> **Scope note:** Nexus is *local-first*. It attaches to apps running on your own machine via
> native hooks (Claude Code) and a local stdio MCP server (Claude Desktop / local Claude
> Code). The claude.ai web chat / "cowork" surface cannot attach to a local stdio MCP server,
> so it is out of scope — use Claude Desktop for the GUI integration.

---

## Requirements

- **Git** — to clone the repo
- **Rust stable toolchain + Cargo** — to build the `nexus` binary
- **A C/C++ linker** — on Windows this means the **MSVC / "Desktop development with C++"** Build Tools; the Rust MSVC toolchain links against them
- **Node.js** — the Claude Code hooks run through a `node` shim, so capture does not work without it
- **Claude CLI** (`claude`) — to register the MCP server (`claude mcp add ...`)
- **Claude Desktop** installed — for the GUI integration
- A machine that can run SQLite-backed Rust binaries (macOS, Linux/WSL, or Windows)

> **Do not skip Step 0.** Run the prerequisite check below *before* any build/install command,
> so you never chase a failure (like `cargo: command not found`) halfway through.

---

## Step 0 — Verify prerequisites first (do this before anything else)

Run this and confirm each line before proceeding. Fix any `[FALTA]` / `MISSING` item first.

**Windows (PowerShell):**

```powershell
Write-Host "=== Nexus prerequisite check ==="
function Check($name,$cmd){ $p=Get-Command $cmd -ErrorAction SilentlyContinue;
  if($p){Write-Host "[OK]      $name -> $($p.Source)"}else{Write-Host "[MISSING] $name ($cmd not found)"} }
Check "Git" git
Check "Rust (rustc)" rustc
Check "Cargo" cargo
Check "Node.js" node
Check "Claude CLI" claude
cargo --version 2>$null; rustc --version 2>$null; node --version 2>$null
rustup show 2>$null | Select-String "default host|msvc"
if(Test-Path "$env:APPDATA\Claude"){Write-Host "[OK]      Claude Desktop config: $env:APPDATA\Claude"}
else{Write-Host "[MISSING] Claude Desktop not installed / never opened"}
```

**macOS / Linux (bash):**

```bash
echo "=== Nexus prerequisite check ==="
for c in git rustc cargo node claude; do
  if command -v "$c" >/dev/null 2>&1; then echo "[OK]      $c -> $(command -v "$c")";
  else echo "[MISSING] $c"; fi
done
cargo --version 2>/dev/null; rustc --version 2>/dev/null; node --version 2>/dev/null
```

If Rust/Cargo is missing, install it from <https://rustup.rs> (on Windows install the
**"Desktop development with C++"** Build Tools first), then **open a new terminal** and re-run
Step 0. Only continue when every item reports `[OK]`.

---

## Windows (PowerShell) — self-contained path

`scripts/install.sh` is a **bash** script and does not run in PowerShell, so on Windows you
build the binary and place it on `PATH` yourself. There is also one important gotcha:

> **Set `NEXUS_DATABASE_PATH` to an absolute path on Windows.** Nexus's default database
> location is derived from the `HOME` environment variable, which Windows usually does not set
> — without an explicit path the DB would be created relative to the current directory, so the
> CLI and Claude Desktop could end up with *different* databases. Fixing `NEXUS_DATABASE_PATH`
> (persistently **and** in the Claude Desktop `env` block) makes all of them share one DB.

Replace `RubenPortillo1` with your own Windows username if different.

```powershell
# 1) Fixed DB path (persistent user var + current session) and its folder
[Environment]::SetEnvironmentVariable("NEXUS_DATABASE_PATH","$env:USERPROFILE\.nexus\nexus.db","User")
$env:NEXUS_DATABASE_PATH = "$env:USERPROFILE\.nexus\nexus.db"
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.nexus" | Out-Null

# 2) Clone OUTSIDE C:\Windows\System32 and build
cd $env:USERPROFILE
git clone https://github.com/scooter-lacroix/Nexus-Memory-System.git
cd Nexus-Memory-System
cargo build --release -p nexus-memory

# 3) Put nexus.exe on PATH (~/.cargo/bin is already on PATH)
Copy-Item .\target\release\nexus.exe "$env:USERPROFILE\.cargo\bin\nexus.exe" -Force
nexus --version

# 4) Initialize DB + configure embeddings (choose local ONNX in the wizard)
nexus init
nexus config
nexus config show
nexus stats

# 5) Activate in Claude Code (native hooks + user-scope MCP)
nexus hooks install --agent claude-code
nexus hooks status --verbose
claude mcp add nexus-memory --scope user -- nexus serve --transport stdio
claude mcp list
```

**6) Claude Desktop** — edit `%APPDATA%\Claude\claude_desktop_config.json` (absolute `.exe`
path + `NEXUS_DATABASE_PATH` in `env`), then fully quit and relaunch the app:

```json
{
  "mcpServers": {
    "nexus-memory": {
      "command": "C:\\Users\\RubenPortillo1\\.cargo\\bin\\nexus.exe",
      "args": ["serve", "--transport", "stdio"],
      "env": {
        "RUST_LOG": "warn",
        "NEXUS_DATABASE_PATH": "C:\\Users\\RubenPortillo1\\.nexus\\nexus.db"
      }
    }
  }
}
```

The macOS/Linux equivalents follow in sections 1–4 (they use `scripts/install.sh`).

---

## 1. Build and install

```bash
git clone https://github.com/scooter-lacroix/Nexus-Memory-System.git
cd Nexus-Memory-System
cargo build --release -p nexus-memory
./scripts/install.sh --binary ./target/release/nexus
```

The installer writes a user-level setup by default:

- binary: `~/.cargo/bin/nexus` (the default `--bin-dir` is `$CARGO_HOME/bin`)
- runtime env: `~/.config/nexus-memory-system/nexus.env`
- database: `~/.local/share/nexus-memory-system/nexus.db`

Make sure `~/.cargo/bin` (and/or `~/.local/bin`) is on your `PATH`, then restart your shell.

Initialize the database and verify:

```bash
nexus init
nexus --version
nexus stats
```

---

## 2. Configure generation and embeddings

Nexus treats text generation and embeddings as independently configurable systems. Run the
interactive wizard:

```bash
nexus config
```

Pick the scheme that fits you:

| Scheme | Pros | Requirements |
| :-- | :-- | :-- |
| **Local embeddings (ONNX)** | Full privacy, no per-call API cost | Bundled ONNX engine + local model download |
| **Remote embeddings** | Higher semantic fidelity on complex code | OpenAI / Anthropic / Gemini (or compatible) API key |
| **Hybrid** | Local indexing, remote summaries | ONNX locally + a remote model for synthesis |

Default recommendation: **local ONNX** (private, no key). Validate:

```bash
nexus config show
nexus eval
```

---

## 3. Claude Code (local) — native hooks + MCP

Install the native lifecycle hooks (Claude Code is Nexus's most complete `native-lifecycle`
integration). The installer writes correctly-shaped `matcher + hooks[]` entries into
`~/.claude/settings.json` and purges duplicate Nexus-managed entries:

```bash
nexus hooks install --agent claude-code
nexus hooks status --verbose
```

Register the MCP server at **user scope** so it is available in every Claude Code session
(run this outside a Claude session):

```bash
claude mcp add nexus-memory --scope user -- nexus serve --transport stdio
claude mcp list
```

### Manual alternative (dotfiles-managed)

Add this to your user config (`~/.claude.json` on macOS/Linux/WSL) under `mcpServers`, or to
`.mcp.json` at a repo root for project scope:

```json
{
  "mcpServers": {
    "nexus-memory": {
      "command": "nexus",
      "args": ["serve", "--transport", "stdio"],
      "env": { "RUST_LOG": "warn" }
    }
  }
}
```

> This repository already ships a project-scoped `.mcp.json` with exactly this block. When you
> open this repo in Claude Code, approve the `nexus-memory` server when prompted. It requires
> `nexus` to be on your `PATH` (step 1).

---

## 4. Claude Desktop — local stdio MCP server

Claude Desktop runs as a GUI process and does **not** inherit your shell `PATH`, so you must
use the **absolute path** to the `nexus` binary. Edit (or create) the desktop config, then
fully quit and relaunch the app:

| OS | Claude Desktop config path | Typical binary path |
| :-- | :-- | :-- |
| macOS | `~/Library/Application Support/Claude/claude_desktop_config.json` | `~/.cargo/bin/nexus` |
| Linux/WSL | `~/.config/Claude/claude_desktop_config.json` | `~/.cargo/bin/nexus` or `~/.local/bin/nexus` |
| Windows | `%APPDATA%\Claude\claude_desktop_config.json` | `%USERPROFILE%\.cargo\bin\nexus.exe` |

```json
{
  "mcpServers": {
    "nexus-memory": {
      "command": "/absolute/path/to/nexus",
      "args": ["serve", "--transport", "stdio"],
      "env": { "RUST_LOG": "warn" }
    }
  }
}
```

**Windows note:** escape backslashes and point at the `.exe`, e.g.
`"C:\\Users\\YOUR_NAME\\.cargo\\bin\\nexus.exe"`. Also set `APPDATA` in `env` if the SQLite
engine cannot locate the data directory.

After relaunching, the tools icon (🔨) should appear in the message input area; clicking it
lists the Nexus store/recall tools. If it does not appear, inspect the logs:

- macOS: `~/Library/Logs/Claude/mcp.log`

---

## 5. Everyday operation

| Command | Purpose | Example |
| :-- | :-- | :-- |
| `nexus store` | Record a decision/milestone manually | `nexus store --content "Use Postgres for audit" --agent claude-code --category decision` |
| `nexus recall` | Semantic search over consolidated records | `nexus recall --agent claude-code --query "database decisions"` |
| `nexus representation` | Structured view + detected conflicts | `nexus representation --agent claude-code --query "db timeline" --introspect` |
| `nexus digest` | Summarize a specific session | `nexus digest --agent claude-code --session-key <key>` |
| `nexus dream` | Run consolidation / de-noising | `nexus dream --agent claude-code` |

`nexus dream` is the consolidation cycle: it de-noises low-value records, resolves
contradictions, and compresses redundancy into compact summaries — improving recall quality
and reducing token usage on later interactions.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
| :-- | :-- | :-- |
| MCP `nexus-memory: … × Failed to connect` (or 🔨 missing) despite correct config | On builds before the stderr fix, `nexus` logged to **stdout**, corrupting the MCP JSON-RPC channel | Rebuild from a version that logs to stderr, **or** silence logs on the server: register with `RUST_LOG=off` in its `env` (e.g. `claude mcp add nexus-memory --scope user --env RUST_LOG=off -- nexus serve --transport stdio`) |
| 🔨 does not appear in Claude Desktop | JSON syntax error or relative binary path | Validate the JSON; use the **absolute** binary path |
| API resolution fails on a call | API env vars not propagated to the GUI process | Add the key (e.g. `ANTHROPIC_API_KEY`) under `env` in the config |
| Nexus DB is locked | Concurrent processes holding the SQLite file | Stop orphan `nexus` processes before starting a new session |
| Mismatched hooks in Claude Code | Stale/duplicate hook entries from a prior install | `nexus hooks install --agent all` re-cleans and re-writes the hooks block |
| `nexus` not found | `~/.cargo/bin` not on `PATH` | Add it to `PATH` and restart the shell, or run `./target/release/nexus` directly |

---

## Appendix — Claude Code on the web (ephemeral sessions)

Claude Code on the web runs in a fresh, ephemeral container per session. This repo ships a
best-effort bootstrap that builds + installs + initializes Nexus and registers the Claude
Code hooks: [`.claude/hooks/nexus-bootstrap.sh`](../../.claude/hooks/nexus-bootstrap.sh). It
is idempotent and guarded — a warm container with the binary already present skips the
rebuild.

> **This is genuinely limited value.** The DB (`~/.local/share/nexus-memory-system/nexus.db`)
> does **not** persist between web containers, and a cold Rust build takes several minutes.
> Web-session memory is therefore session-local. The durable deployment is your own machine
> (sections 1–4).

**Manual (recommended for web):** run once per session when you want Nexus active:

```bash
bash .claude/hooks/nexus-bootstrap.sh
```

**Automatic (opt-in):** to run it on every session start, add a `SessionStart` hook to
`.claude/settings.json`. Committing an auto-build-and-run hook affects everyone who opens the
repo, so enable it deliberately:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/nexus-bootstrap.sh\"",
            "timeout": 600
          }
        ]
      }
    ]
  }
}
```

---

## Related docs

- [Installation Guide](../../INSTALLATION.md)
- [Hooks](../../HOOKS.md)
- [Getting Started](getting-started.md)
- [Embeddings Guide](embeddings.md)
