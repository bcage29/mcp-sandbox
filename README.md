# mcp-sandbox

Local, sandboxed MCP servers. Each server is added as a Git submodule, pinned to a specific commit, and run in Docker with `--network none` to prevent data exfiltration.

## Quick Start

```bash
# Add a server (automatically runs build + config)
make add url=https://github.com/<owner>/<repo>

# Rebuild after changes
make build server=<repo>

# See the VS Code MCP config to paste into .vscode/mcp.json
make config server=<repo> network=none
```

## Commands

| Command | Description |
|---|---|
| `make add url=<repo>` | Add a server as a submodule, then run build and config |
| `make build server=<name>` | Build Docker image |
| `make build-all` | Build all server images |
| `make run server=<name>` | Run interactively (for testing) |
| `make list` | Show all servers and pinned commits |
| `make data server=<name>` | Create persistent storage for a server |
| `make config server=<name> [network=<mode>]` | Print VS Code MCP config JSON |
| `make update server=<name>` | Fetch latest, show diff, confirm before updating |
| `make remove server=<name>` | Remove a submodule server and cleanup local artifacts |
| `make clean server=<name>` | Alias for `make remove server=<name>` |
| `make proxy-build` | Build the Squid proxy image (one-time) |
| `make proxy-start` | Start the shared proxy (generates config from all registered servers) |
| `make proxy-stop` | Stop the proxy and remove its network |

## Network Isolation

Default is `--network none` (no network access at all). Override per-command:

```bash
make run server=<repo> network=none      # default, fully isolated
make run server=<repo> network=bridge    # Docker default bridge (full internet)
make run server=<repo> network=proxy     # allowlisted domains only (via Squid proxy)
```

The `network` value is passed directly as `docker run --network <value>`. You can also use any custom Docker network name you've created.

### Proxy Mode (Domain Allowlist)

Proxy mode runs a single shared Squid forward proxy that only allows traffic to domains you've explicitly listed. Each server gets its own port on the proxy and its own allowlist, so servers are isolated from each other — one server's allowlist doesn't grant access to another.

```
┌───────────────────────────────────────────────────────────┐
│  Docker network: mcp-proxy-net                            │
│                                                           │
│  ┌──────────┐ :3128   ┌────────────────────┐              │
│  │ Server A │────────▶│                    │──▶ openai ✅  │
│  └──────────┘         │  Squid proxy       │              │
│                       │  (port-based       │              │
│  ┌──────────┐ :3129   │   allowlists)      │──▶ evil  ❌  │
│  │ Server B │────────▶│                    │              │
│  └──────────┘         └────────────────────┘              │
└───────────────────────────────────────────────────────────┘
```

**Setup:**

```bash
# 1. Build the proxy image (one-time)
make proxy-build

# 2. Add a server with proxy mode — creates allowlist + assigns a port
make add url=https://github.com/owner/repo network=proxy

# 3. Edit the allowlist to add domains
echo "api.openai.com" >> .server-config/<repo>/.allowlist

# 4. Run with proxy mode
make run server=<repo> network=proxy

# 5. Or generate VS Code config with proxy
make config server=<repo> network=proxy

# 6. Stop the proxy when done
make proxy-stop
```

When you add a server with `network=proxy`, the Makefile:
- Creates `.server-config/<server>/.allowlist` (domains this server can reach)
- Assigns a unique proxy port in `.server-config/<server>/.proxy-port`
- Adds `HTTP_PROXY`/`HTTPS_PROXY` env vars to `.server-config/<server>/.env`

The allowlist file format is one domain per line. Lines starting with `#` are comments:

```
# .server-config/my-server/.allowlist
# Domains this server is allowed to reach

# OpenAI API
api.openai.com

# Anthropic API
api.anthropic.com

# Subdomains can be matched with a leading dot
.googleapis.com
```

Requests to any domain not in this file will be blocked by the proxy.

When `make proxy-start` runs, it scans all `.proxy-port` files and generates a Squid config with per-port ACLs. Each server's traffic goes through its assigned port, and Squid checks the corresponding allowlist. Adding a new proxy server just means running `make add` with `network=proxy` again — the proxy will pick up the new port on next restart.

## Supported Server Types

`make build` auto-detects the server type by checking for indicator files:

| Priority | Indicator | Template used |
|---|---|---|
| 1 | Server has its own `Dockerfile` | Server's Dockerfile |
| 2 | `pyproject.toml`, `requirements.txt`, or `setup.py` | `Dockerfile.python` |
| 3 | `package.json` | `Dockerfile.node` |
| — | None of the above | Error with guidance |

The Python template uses `CMD ["python", "-m", "server"]` by default. Override the entrypoint by adding a `Dockerfile` to the server repo.

## Security Model

- **Pinned commits** — each submodule is pinned in the parent repository commit
- **No install scripts** — `npm ci --ignore-scripts` blocks supply chain attacks via postinstall hooks
- **Non-root container** — servers run as an unprivileged user inside Docker
- **Network isolation** — `--network none` by default prevents any outbound connections
- **Review before update** — `make update` shows the commit log diff and asks for confirmation

## Adding to VS Code

The generated config goes in `.vscode/mcp.json`:

```json
{
  "servers": {
    "example-server": {
      "command": "docker",
      "args": ["run", "-i", "--rm", "--network", "none", "mcp-example-server"]
    }
  }
}
```

## Persistent Storage

Servers that need persistent storage get a `data/<server-name>/` directory on the host, which is mounted at `/data` inside the container. Both `make run` and `make config` include this mount. You can also create it explicitly:

```bash
make data server=some-server
```

Set server-specific env vars in `.server-config/<server>/.env` to tell the server where to write (e.g., `TODO_DB_FOLDER=/data`). The `data/` directory is gitignored. The volume mount is scoped to a single directory per server — the container cannot access anything else on the host filesystem.

## File Structure

```
mcp-sandbox/
├── Makefile              # All automation
├── dockerfiles/
│   ├── Dockerfile.node   # Shared template for Node.js servers
│   ├── Dockerfile.python # Shared template for Python servers
│   └── Dockerfile.squid  # Squid forward proxy for domain allowlisting
├── .env.example          # Optional variable overrides
├── .gitmodules           # Submodule path → URL mapping (tracked in git)
├── .vscode/mcp.json      # VS Code MCP server config
├── .server-config/       # Per-server runtime config (gitignored)
│   └── <repo>/
│       ├── .env          # Environment variables
│       ├── .allowlist    # Allowed domains (proxy mode)
│       └── .proxy-port   # Assigned proxy port (proxy mode)
└── servers/
  └── <repo>/             # Git submodule pinned to a commit
```
