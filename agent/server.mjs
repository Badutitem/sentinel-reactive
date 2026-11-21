#!/usr/bin/env node
"use strict";
/*
 * Sentinel — agent connector (MCP server, stdio transport)
 *
 * Sentinel is an AI-guarded stop-loss: a small neural network inside a
 * Reactive contract (Lasna) watches the Chainlink ETH/USD feed and guards a
 * WETH position in a vault on Base Sepolia, deciding HOLD / TRIM / EXIT and
 * buying back in (re-risk) entirely on-chain.
 *
 * This server lets an AI agent inspect that live system and prepare — never
 * sign, never send — a deposit into the guarded vault. The server holds no
 * keys. All chain reads are hand-rolled JSON-RPC against public endpoints,
 * using the exact selectors, event topics and failover pattern of the
 * Sentinel Live Proof page (docs/index.html).
 *
 * Tools:
 *   sentinel_status           live trio #5 state, read at call time
 *   sentinel_events           recent decisions / callbacks / protections
 *   sentinel_prepare_deposit  unsigned wrap/approve/deposit txs for YOUR wallet
 *   sentinel_verify           the five contracts + Sourcify/explorer links
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

/* If the host environment routes traffic through an HTTP(S) proxy
 * (HTTPS_PROXY / https_proxy / ALL_PROXY …), honour it for the RPC calls —
 * Node's fetch ignores proxy variables unless a dispatcher is installed.
 * On a normal direct connection this is a no-op (NO_PROXY is respected). */
if (process.env.HTTPS_PROXY || process.env.https_proxy || process.env.ALL_PROXY || process.env.all_proxy) {
  try {
    const { EnvHttpProxyAgent, setGlobalDispatcher } = await import("undici");
    setGlobalDispatcher(new EnvHttpProxyAgent());
  } catch (e) {
    console.error("sentinel-mcp: proxy env present but undici dispatcher failed:", e.message);
  }
}

/* ---------------- config (mirrors docs/index.html) ---------------- */
const LASNA_RPCS = ["https://lasna-rpc.rnk.dev"]; // Lasna has one public RPC; retries still apply
const BASE_RPCS_CALL = ["https://sepolia.base.org", "https://base-sepolia-rpc.publicnode.com", "https://base-sepolia.gateway.tenderly.co", "https://base-sepolia.drpc.org"];
const BASE_RPCS_LOGS = ["https://base-sepolia-rpc.publicnode.com", "https://base-sepolia.gateway.tenderly.co", "https://sepolia.base.org", "https://base-sepolia.drpc.org"];
const REACTSCAN = "https://lasna.reactscan.net";
const BASESCAN = "https://sepolia.basescan.org";
const BASE_CHAIN_ID = 84532;

const R5 = "0x0Fdab4F59e877B2f9f695Bd285b72831336caCd4"; // SentinelReactiveV5, Lasna
const R5_DEPLOY = 8726755;
const V5 = "0xb13BF7Ff153e7f6304735EC4199B006Fd4857Ac9"; // SentinelVaultV4, Base Sepolia
const V5_DEPLOY = 60811963;
const S5 = "0x80c3BF688b08ac03D3aE7396cDd96770F7ce572a"; // SentinelSwapV2, Base Sepolia
const R5R = "0x1123b38e933D0a87D5846456c1ed6E94c936e3e1"; // rehearsal reactive, Lasna
const V5R = "0x242719F815141ad08286f29a23025b9244efd60e"; // rehearsal vault, Base Sepolia
const WETH = "0x4200000000000000000000000000000000000006"; // canonical Base WETH
const MUSDC = "0x96E467Ff7958851d307D28118EBAAD333CAb85B2"; // MockUSDC (trio #5 safe asset)

const SEL = {
  updates: "0x68a82ef6", anchorPeak: "0x4e801ffc", lastAction: "0x89f71d53",
  duplicatesIgnored: "0x58aec1ac", episodeActive: "0xccecbdaf", episodeAnchor: "0x8b169dac",
  tranche1Fired: "0x7862b6ee", tranche2Fired: "0x99157f7d", reriskCount: "0x8beaf925",
  positionSize: "0x84f523ad", safeBalance: "0x88780b8e", closed: "0x597e1fb5",
  protectionCount: "0x9b02c402", reserve: "0xcd3293de", riskReserve: "0x44c5999e",
  balanceOf: "0x70a08231", allowance: "0xdd62ed3e", approve: "0x095ea7b3",
  wethDeposit: "0xd0e30db0", vaultDeposit: "0xb6b55f25"
};
const TOPIC = {
  PriceSeen: "0xd835ba2bc227150e613ee209169441eaa417f430d04632345983d855a95ba9a6",
  Decision: "0x953c77171e42ede9b4af2df0081e1f06bf35501b207993ce9340902faa40e3a6",
  CallbackRequested: "0x4f00175060ca94fae8c6ac24a7b9a64eb44658efe38c54ec3ab56f67cd79a42d",
  TrimSuppressed: "0xb4b0067a74881b99e6372aa2990ed4a03be814b1ed9e0413f2c30f73fd517a02",
  EpisodeOpened: "0x251e9690aae494ba6b320799fdfec8e88a8f537bd7e2862998faa19a72c1a9b3",
  EpisodeCancelled: "0xc6e9447f7622be80757ab435a291ad85f0dc7cbae9d1186719522956eedb6442",
  ProtectionExecuted: "0x384900fde4c9615d84b610a4889a0568ca153695045bc2a183a3c21950ada34e",
  DeRisked: "0x2daf4dea00efb60715717c9623908d454c5e5d845a7196b32e9f1384426bec50",
  ReRisked: "0x9fcf1dda8d7e7cf9836744c31ed05f39edf04fa0cd6e5702fe58a9345a1d9af9"
};
const ACTIONS = ["HOLD", "TRIM", "EXIT", "RERISK", "RERISK_FINAL"];

/* ---------------- tiny JSON-RPC client (fetch, retries + endpoint failover) ---------------- */
let rpcId = 0;
async function rpcOnce(url, method, params) {
  const ctl = new AbortController();
  const to = setTimeout(() => ctl.abort(), 20000);
  try {
    const res = await fetch(url, {
      method: "POST", signal: ctl.signal,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: ++rpcId, method, params })
    });
    if (!res.ok) throw new Error("HTTP " + res.status);
    const j = await res.json();
    if (j.error) throw new Error(j.error.message || "RPC error");
    return j.result;
  } finally { clearTimeout(to); }
}
async function rpc(urls, method, params) {
  let lastErr;
  for (const url of urls) {
    for (let attempt = 0; attempt < 2; attempt++) {
      try { return await rpcOnce(url, method, params); }
      catch (e) { lastErr = e; }
    }
  }
  throw lastErr || new Error("all RPC endpoints failed");
}
const call = (urls, to, data) => rpc(urls, "eth_call", [{ to, data }, "latest"]);
const getBalance = (urls, addr) => rpc(urls, "eth_getBalance", [addr, "latest"]);
const blockNumber = urls => rpc(urls, "eth_blockNumber", []);
async function blockTime(urls, blk) {
  const b = await rpc(urls, "eth_getBlockByNumber", ["0x" + blk.toString(16), false]);
  return parseInt(b.timestamp, 16);
}

/* ---------------- decoding / formatting ---------------- */
const U = hex => BigInt(hex);
const I = hex => { const v = BigInt(hex); return v >= (1n << 255n) ? v - (1n << 256n) : v; };
const words = data => { const out = []; for (let i = 2; i + 64 <= data.length; i += 64) out.push("0x" + data.slice(i, i + 64)); return out; };
const fmtTok = (wei, sym) => {
  const v = Number(wei) / 1e18;
  return v.toLocaleString("en-US", { minimumFractionDigits: 0, maximumFractionDigits: 6 }) + (sym ? " " + sym : "");
};
const fmtPrice = raw => "$" + (Number(raw) / 1e18).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const fmtTs = ts => new Date(ts * 1000).toISOString().replace("T", " ").slice(0, 16) + " UTC";
const padAddr = a => a.toLowerCase().replace(/^0x/, "").padStart(64, "0");
const padUint = v => v.toString(16).padStart(64, "0");
function parseEther(str) {
  const m = /^(\d+)(?:\.(\d{1,18}))?$/.exec(String(str).trim());
  if (!m) throw new Error("amount must be a decimal ETH string like \"0.0001\" (max 18 decimal places)");
  const whole = BigInt(m[1]) * 10n ** 18n;
  const frac = m[2] ? BigInt(m[2].padEnd(18, "0")) : 0n;
  return whole + frac;
}

/* ---------------- log scanning (chunked, mirrors the proof page) ---------------- */
async function scanLogs(urls, address, topics, fromBlock, chunk) {
  const head = parseInt(await blockNumber(urls), 16);
  const jobs = [];
  for (let f = fromBlock; f <= head; f += chunk) jobs.push([f, Math.min(f + chunk - 1, head)]);
  const out = [];
  for (let i = 0; i < jobs.length; i += 5) {
    const batch = jobs.slice(i, i + 5);
    const rs = await Promise.all(batch.map(([f, t]) =>
      rpc(urls, "eth_getLogs", [{ address, topics: [topics], fromBlock: "0x" + f.toString(16), toBlock: "0x" + t.toString(16) }])
        .catch(() => null)));
    rs.forEach(r => { if (Array.isArray(r)) out.push(...r); });
  }
  return out;
}

/* ---------------- shared live reads ---------------- */
async function readBrainState() {
  const [bal, updates, anchor, lastAction, dups, episodeActive, rerisk] = await Promise.all([
    getBalance(LASNA_RPCS, R5),
    call(LASNA_RPCS, R5, SEL.updates),
    call(LASNA_RPCS, R5, SEL.anchorPeak),
    call(LASNA_RPCS, R5, SEL.lastAction),
    call(LASNA_RPCS, R5, SEL.duplicatesIgnored),
    call(LASNA_RPCS, R5, SEL.episodeActive),
    call(LASNA_RPCS, R5, SEL.reriskCount)
  ]);
  const state = {
    address: R5,
    chain: "Reactive Lasna testnet (5318007)",
    fuel_lreact: fmtTok(U(bal), "lREACT"),
    fuel_lreact_wei: U(bal).toString(),
    price_updates_ingested: Number(U(updates)),
    anchor: fmtPrice(U(anchor)),
    anchor_raw: U(anchor).toString(),
    last_decision: ACTIONS[Number(U(lastAction))],
    duplicates_ignored: Number(U(dups)),
    rerisk_tranches_fired: Number(U(rerisk)),
    rerisk_episode_active: U(episodeActive) === 1n
  };
  if (state.rerisk_episode_active) {
    const [epAnchor, t1] = await Promise.all([
      call(LASNA_RPCS, R5, SEL.episodeAnchor),
      call(LASNA_RPCS, R5, SEL.tranche1Fired)
    ]);
    state.episode_anchor = fmtPrice(U(epAnchor));
    state.episode_tranche1_fired = U(t1) === 1n;
  }
  return state;
}

async function readLastPrice() {
  const logs = await scanLogs(LASNA_RPCS, R5, [TOPIC.PriceSeen], R5_DEPLOY, 30000);
  if (!logs.length) return null;
  logs.sort((a, b) => parseInt(a.blockNumber, 16) - parseInt(b.blockNumber, 16) || parseInt(a.logIndex, 16) - parseInt(b.logIndex, 16));
  const last = logs[logs.length - 1];
  const w = words(last.data);
  return {
    last_price_chainlink_eth_usd: fmtPrice(U(w[0])),
    last_price_raw: U(w[0]).toString(),
    last_price_update_number: Number(U(w[2])),
    last_price_tx: REACTSCAN + "/tx/" + last.transactionHash
  };
}

async function readVaultState() {
  const [position, safe, closed, prot, rerisk, ethBal, reserve, riskReserve] = await Promise.all([
    call(BASE_RPCS_CALL, V5, SEL.positionSize),
    call(BASE_RPCS_CALL, V5, SEL.safeBalance),
    call(BASE_RPCS_CALL, V5, SEL.closed),
    call(BASE_RPCS_CALL, V5, SEL.protectionCount),
    call(BASE_RPCS_CALL, V5, SEL.reriskCount),
    getBalance(BASE_RPCS_CALL, V5),
    call(BASE_RPCS_CALL, S5, SEL.reserve),
    call(BASE_RPCS_CALL, S5, SEL.riskReserve)
  ]);
  return {
    vault: {
      address: V5,
      chain: "Base Sepolia (84532)",
      position_weth: fmtTok(U(position), "WETH"),
      position_weth_wei: U(position).toString(),
      safe_balance_musdc: fmtTok(U(safe), "mUSDC"),
      safe_balance_musdc_wei: U(safe).toString(),
      closed_by_exit: U(closed) === 1n,
      protection_callbacks_executed: Number(U(prot)),
      rerisk_callbacks_executed: Number(U(rerisk)),
      callback_billing_eth: fmtTok(U(ethBal), "ETH"),
      callback_billing_eth_wei: U(ethBal).toString()
    },
    swap_desk: {
      address: S5,
      reserve_musdc: fmtTok(U(reserve), "mUSDC"),
      reserve_musdc_wei: U(reserve).toString(),
      reserve_weth: fmtTok(U(riskReserve), "WETH"),
      reserve_weth_wei: U(riskReserve).toString()
    }
  };
}

async function collectEvents(limit) {
  const items = [];
  const timeCache = {};
  const getTs = async (urls, blk) => {
    const key = urls[0] + blk;
    if (!(key in timeCache)) timeCache[key] = await blockTime(urls, blk).catch(() => 0);
    return timeCache[key];
  };
  const rTopics = [TOPIC.PriceSeen, TOPIC.Decision, TOPIC.CallbackRequested, TOPIC.TrimSuppressed, TOPIC.EpisodeOpened, TOPIC.EpisodeCancelled];
  const rLogs = await scanLogs(LASNA_RPCS, R5, rTopics, R5_DEPLOY, 30000);
  for (const l of rLogs) {
    const t0 = l.topics[0], w = words(l.data), blk = parseInt(l.blockNumber, 16);
    const ts = await getTs(LASNA_RPCS, blk);
    const base = { time: fmtTs(ts), timestamp: ts, chain: "Lasna", tx: l.transactionHash, explorer_tx: REACTSCAN + "/tx/" + l.transactionHash };
    if (t0 === TOPIC.PriceSeen) {
      items.push({ ...base, kind: "PriceSeen", detail: "Chainlink ETH/USD at " + fmtPrice(U(w[0])) + " (update #" + U(w[2]).toString() + ")" });
    } else if (t0 === TOPIC.Decision) {
      const a = Number(U(w[2]));
      items.push({ ...base, kind: "Decision", action: ACTIONS[a], detail: "Decision " + ACTIONS[a] + " at " + fmtPrice(U(w[0])) + " · model scores HOLD " + (Number(I(w[3])) / 1e6).toFixed(2) + " / TRIM " + (Number(I(w[4])) / 1e6).toFixed(2) + " / EXIT " + (Number(I(w[5])) / 1e6).toFixed(2) });
    } else if (t0 === TOPIC.CallbackRequested) {
      const a = Number(U(w[0]));
      items.push({ ...base, kind: "CallbackRequested", action: ACTIONS[a], detail: "Callback sent to the vault: " + ACTIONS[a] });
    } else if (t0 === TOPIC.TrimSuppressed) {
      items.push({ ...base, kind: "TrimSuppressed", detail: "Repeat TRIM inside the same fall ignored on purpose (update #" + U(w[2]).toString() + ")" });
    } else if (t0 === TOPIC.EpisodeOpened) {
      items.push({ ...base, kind: "EpisodeOpened", detail: "Re-risk episode opened, buy-back armed against anchor " + fmtPrice(U(w[0])) });
    } else if (t0 === TOPIC.EpisodeCancelled) {
      items.push({ ...base, kind: "EpisodeCancelled", detail: "Re-risk episode cancelled at " + fmtPrice(U(w[0])) });
    }
  }
  const vTopics = [TOPIC.ProtectionExecuted, TOPIC.DeRisked, TOPIC.ReRisked];
  const vLogs = await scanLogs(BASE_RPCS_LOGS, V5, vTopics, V5_DEPLOY, 50000);
  for (const l of vLogs) {
    const t0 = l.topics[0], w = words(l.data), blk = parseInt(l.blockNumber, 16);
    const ts = await getTs(BASE_RPCS_CALL, blk);
    const base = { time: fmtTs(ts), timestamp: ts, chain: "Base Sepolia", tx: l.transactionHash, explorer_tx: BASESCAN + "/tx/" + l.transactionHash };
    if (t0 === TOPIC.ProtectionExecuted) {
      const a = Number(U(w[1]));
      items.push({ ...base, kind: "ProtectionExecuted", action: ACTIONS[a], detail: "Vault executed " + ACTIONS[a] + ": position " + fmtTok(U(w[2]), "WETH") + " -> " + fmtTok(U(w[3]), "WETH") });
    } else if (t0 === TOPIC.DeRisked) {
      const a = Number(U(w[0]));
      items.push({ ...base, kind: "DeRisked", action: ACTIONS[a], detail: "Sold " + fmtTok(U(w[1]), "WETH") + " for " + fmtTok(U(w[2]), "mUSDC") });
    } else if (t0 === TOPIC.ReRisked) {
      items.push({ ...base, kind: "ReRisked", action: "RERISK", detail: "Bought back in: spent " + fmtTok(U(w[0]), "mUSDC") + " for " + fmtTok(U(w[1]), "WETH") });
    }
  }
  items.sort((a, b) => b.timestamp - a.timestamp || b.tx.localeCompare(a.tx));
  return items.slice(0, limit);
}

/* ---------------- MCP server ---------------- */
const server = new McpServer({ name: "sentinel", version: "1.0.0" });
const json = obj => ({ content: [{ type: "text", text: JSON.stringify(obj, null, 2) }] });
const fail = e => ({ isError: true, content: [{ type: "text", text: "Error: " + (e && e.message ? e.message : String(e)) }] });

server.tool(
  "sentinel_status",
  "Live state of Sentinel trio #5, read from the contracts at call time: the brain on Lasna (lREACT fuel, price updates ingested, last Chainlink ETH/USD price, anchor, last decision HOLD/TRIM/EXIT/RERISK), the guarded vault on Base Sepolia (WETH position, mock-USDC safe balance, closed?, protection and re-risk callback counts, callback billing balance), and the swap desk reserves.",
  {},
  async () => {
    try {
      const [brain, vaultDesk, lastPrice] = await Promise.all([
        readBrainState(), readVaultState(), readLastPrice().catch(() => null)
      ]);
      return json({
        system: "Sentinel trio #5 (live)",
        read_at: new Date().toISOString(),
        brain: { ...brain, ...(lastPrice || { last_price_chainlink_eth_usd: null }) },
        ...vaultDesk,
        links: {
          live_proof: "https://badutitem.github.io/sentinel-reactive/",
          demo_app: "https://badutitem.github.io/sentinel-reactive/app.html"
        }
      });
    } catch (e) { return fail(e); }
  }
);

server.tool(
  "sentinel_events",
  "Most recent events of the live Sentinel trio #5 across both chains, newest first: prices ingested, decisions (with model scores), callbacks requested, TRIM suppressions, re-risk episodes, and the vault's protection/de-risk/re-risk executions. Each event carries its explorer transaction link.",
  { limit: z.number().int().min(1).max(40).optional().describe("How many events to return (default 14, max 40)") },
  async ({ limit }) => {
    try {
      const events = await collectEvents(limit || 14);
      return json({ count: events.length, events });
    } catch (e) { return fail(e); }
  }
);

server.tool(
  "sentinel_prepare_deposit",
  "Prepare the unsigned transactions for depositing test ETH into Sentinel's guarded vault on Base Sepolia: (1) wrap — only the WETH shortfall, computed from the sender's live WETH balance; (2) approve — exact amount, skipped if the vault's allowance already suffices; (3) deposit into the shared guarded position. Returns {to, value, data} per step in order. The server NEVER signs and NEVER sends — sign and broadcast with your own wallet. Honest limits: testnet only; deposits join ONE shared position (no per-user accounting); withdrawals are owner-only in this demo, so test WETH you deposit cannot be withdrawn by you.",
  {
    sender: z.string().regex(/^0x[0-9a-fA-F]{40}$/).describe("Your wallet address on Base Sepolia (the future deposit signer)"),
    amount_eth: z.string().describe("Deposit amount as a decimal ETH string, e.g. \"0.0001\"")
  },
  async ({ sender, amount_eth }) => {
    try {
      const amount = parseEther(amount_eth);
      if (amount <= 0n) throw new Error("amount must be greater than zero");
      const from = sender;
      const [ethBalHex, wethBalHex, allowHex] = await Promise.all([
        getBalance(BASE_RPCS_CALL, from),
        call(BASE_RPCS_CALL, WETH, SEL.balanceOf + padAddr(from)),
        call(BASE_RPCS_CALL, WETH, SEL.allowance + padAddr(from) + padAddr(V5))
      ]);
      const ethBal = U(ethBalHex), wethBal = U(wethBalHex), allowance = U(allowHex);
      const transactions = [];
      const warnings = [];
      const shortfall = amount > wethBal ? amount - wethBal : 0n;
      if (shortfall > 0n) {
        transactions.push({
          step: 1, action: "wrap",
          description: "Wrap the WETH shortfall: deposit " + fmtTok(shortfall, "ETH") + " into WETH",
          chain_id: BASE_CHAIN_ID, to: WETH, value: shortfall.toString(), value_hex: "0x" + shortfall.toString(16), data: SEL.wethDeposit
        });
        if (ethBal < shortfall) {
          warnings.push("Sender holds " + fmtTok(ethBal, "ETH") + " but wrapping the shortfall needs " + fmtTok(shortfall, "ETH") + " (plus gas). The wrap transaction would fail unless the sender is funded first.");
        }
      }
      if (allowance < amount) {
        transactions.push({
          step: transactions.length + 1, action: "approve",
          description: "Approve the vault to pull exactly " + fmtTok(amount, "WETH"),
          chain_id: BASE_CHAIN_ID, to: WETH, value: "0", value_hex: "0x0", data: SEL.approve + padAddr(V5) + padUint(amount)
        });
      }
      transactions.push({
        step: transactions.length + 1, action: "deposit",
        description: "Deposit " + fmtTok(amount, "WETH") + " into the shared guarded position",
        chain_id: BASE_CHAIN_ID, to: V5, value: "0", value_hex: "0x0", data: SEL.vaultDeposit + padUint(amount)
      });
      return json({
        ready: warnings.length === 0,
        chain_id: BASE_CHAIN_ID,
        sender: from,
        amount: fmtTok(amount, "WETH"),
        amount_wei: amount.toString(),
        sender_balances_now: {
          eth: fmtTok(ethBal, "ETH"), eth_wei: ethBal.toString(),
          weth: fmtTok(wethBal, "WETH"), weth_wei: wethBal.toString(),
          vault_allowance_weth: fmtTok(allowance, "WETH"), vault_allowance_weth_wei: allowance.toString()
        },
        skipped: [
          ...(shortfall === 0n ? ["wrap — sender already holds enough WETH"] : []),
          ...(allowance >= amount ? ["approve — the vault already has enough allowance"] : [])
        ],
        transactions,
        warnings,
        note: "Unsigned transactions, in execution order. Sign and broadcast them yourself, waiting for each receipt before sending the next. This server holds no keys and sends nothing. Testnet only: deposits join one shared position and withdrawals are owner-only in this demo."
      });
    } catch (e) { return fail(e); }
  }
);

const CONTRACTS = [
  { name: "SentinelReactiveV5 — the brain (trio #5)", chain: "Reactive Lasna testnet", chain_id: 5318007, address: R5, explorer: REACTSCAN },
  { name: "SentinelVaultV4 — the vault (trio #5)", chain: "Base Sepolia", chain_id: BASE_CHAIN_ID, address: V5, explorer: BASESCAN },
  { name: "SentinelSwapV2 — the swap desk (trio #5)", chain: "Base Sepolia", chain_id: BASE_CHAIN_ID, address: S5, explorer: BASESCAN },
  { name: "SentinelReactiveV5 — rehearsal brain (#5R)", chain: "Reactive Lasna testnet", chain_id: 5318007, address: R5R, explorer: REACTSCAN },
  { name: "SentinelVaultV4 — rehearsal vault (#5R)", chain: "Base Sepolia", chain_id: BASE_CHAIN_ID, address: V5R, explorer: BASESCAN }
];
server.tool(
  "sentinel_verify",
  "The five Sentinel trio #5 / rehearsal contracts with Sourcify lookup and block-explorer links. Every contract is verified on Sourcify with an exact match — the code you read is the code that runs.",
  {},
  async () => json({
    contracts: CONTRACTS.map(c => ({
      name: c.name, chain: c.chain, chain_id: c.chain_id, address: c.address,
      sourcify: "https://sourcify.dev/#/lookup/" + c.address,
      explorer: c.explorer + "/address/" + c.address
    }))
  })
);

const transport = new StdioServerTransport();
await server.connect(transport);
console.error("sentinel-mcp: ready on stdio (tools: sentinel_status, sentinel_events, sentinel_prepare_deposit, sentinel_verify)");
