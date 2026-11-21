# Sentinel — agent connector (MCP server)

An [MCP](https://modelcontextprotocol.io) server that lets an AI agent inspect
the live Sentinel system and prepare a deposit into its guarded vault.

Sentinel is an AI-guarded stop-loss: a small neural network inside a Reactive
contract on the Lasna testnet watches the Chainlink ETH/USD feed and guards a
WETH position on Base Sepolia, deciding **HOLD / TRIM / EXIT** (and buying back
in, in two tranches) entirely on-chain. This server is the agent-facing door to
that system — the same live reads the
[Live Proof page](https://badutitem.github.io/sentinel-reactive/) shows in a
browser, plus unsigned deposit preparation.

**The server holds no keys and never sends a transaction.** It reads chains
and builds calldata; signing and broadcasting are always done by the agent's
own wallet.

## Tools

| Tool | What it does |
|---|---|
| `sentinel_status` | Live trio #5 state, read at call time: brain fuel (lREACT), price updates ingested, last Chainlink price, anchor, last decision; vault position / safe balance / closed / protection + re-risk counts / billing balance; swap desk reserves. |
| `sentinel_events` | Recent decision, callback and protection events across both chains, newest first, each with its explorer transaction link. Optional `limit` (default 14, max 40). |
| `sentinel_prepare_deposit` | Given a sender address and an ETH amount, returns the unsigned transactions — in order — for **wrap** (only the WETH shortfall, from the sender's live balances), **approve** (exact amount, skipped if allowance suffices) and **deposit**. Sign and broadcast them yourself, waiting for each receipt. |
| `sentinel_verify` | The five trio #5 / rehearsal contracts with Sourcify lookup and explorer links (all Sourcify exact-match). |

## Install & run

Requires Node.js ≥ 18. No build step.

```bash
cd agent
npm install
node server.mjs        # or: npm start
```

The server speaks MCP over **stdio** — it is meant to be launched by an MCP
client, not run as a web service. Diagnostics go to stderr; stdout is the
protocol channel.

If your host routes traffic through an HTTP(S) proxy (`HTTPS_PROXY` /
`ALL_PROXY` environment variables), the server honours them automatically for
its RPC calls; on a direct connection it just works.

## MCP client config

Point any MCP client at the server, e.g.:

```json
{
  "mcpServers": {
    "sentinel": {
      "command": "node",
      "args": ["/absolute/path/to/sentinel-reactive/agent/server.mjs"]
    }
  }
}
```

## Using `sentinel_prepare_deposit`

The tool returns `transactions: [{step, action, to, value, data}, …]`. Send
them **in order, unchanged**, from the sender wallet, waiting for each receipt
before the next. With Foundry's `cast`, for example:

```bash
# 1 · wrap (value is wei, data is the WETH deposit() call)
cast send <to> --data <data> --value <value> --private-key <YOUR_KEY> --rpc-url https://sepolia.base.org
# 2 · approve, then 3 · deposit — same shape, value 0
```

## Honest limits

- **Testnet only.** Lasna + Base Sepolia. Nothing here is real money.
- **One shared position.** Deposits join the single vault position — there is
  no per-user accounting in this demo.
- **Withdrawals are owner-only.** Test WETH you deposit cannot be withdrawn by
  you; only the demo operator can take WETH back out of the vault.
- **The safe asset is a mock.** The vault de-risks into MockUSDC (mint is
  owner-only; there is no public faucet).
- **No keys, no sending.** This server cannot move funds, ever — it only
  reads and prepares.

Machine-readable manifest: https://badutitem.github.io/sentinel-reactive/agent.json
