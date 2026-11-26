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
 *   sentinel_status           live flagship state, read at call time
 *   sentinel_events           recent decisions / callbacks / protections
 *   sentinel_prepare_deposit  unsigned wrap/approve/deposit txs for YOUR wallet
 *   sentinel_verify           the three flagship contracts + Sourcify/explorer links
 *
 * The live system's vault is SentinelVaultV5, a per-user pool: a deposit
 * mints shares in the depositor's name, and any holder can redeem their
 * shares at any time for their pro-rata slice of both pool assets.
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

const R5 = "0x37EeF5e3179E55c0e96E1528180B55Fa20DC150B"; // SentinelReactiveV5 — flagship brain, Lasna
const R5_DEPLOY = 9172277;
const V5 = "0x108513e6439664fdeE9050e1ccc208e8c1b61441"; // SentinelVaultV5 — flagship per-user vault, Base Sepolia
const V5_DEPLOY = 63196568;
const S5 = "0x17700999733F766968EA252D5a17ac39F96F2C28"; // SentinelSwapV2 — flagship desk, Base Sepolia
const WETH = "0x4200000000000000000000000000000000000006"; // canonical Base WETH
const MUSDC = "0x96E467Ff7958851d307D28118EBAAD333CAb85B2"; // MockUSDC (the pool's safe asset, mock)

const SEL = {
  updates: "0x68a82ef6", anchorPeak: "0x4e801ffc", lastAction: "0x89f71d53",
  duplicatesIgnored: "0x58aec1ac", episodeActive: "0xccecbdaf", episodeAnchor: "0x8b169dac",
  tranche1Fired: "0x7862b6ee", tranche2Fired: "0x99157f7d", reriskCount: "0x8beaf925",
  positionSize: "0x84f523ad", safeBalance: "0x88780b8e", closed: "0x597e1fb5",
  protectionCount: "0x9b02c402", reserve: "0xcd3293de", riskReserve: "0x44c5999e",
  balanceOf: "0x70a08231", allowance: "0xdd62ed3e", approve: "0x095ea7b3",
  wethDeposit: "0xd0e30db0", vaultDeposit: "0xb6b55f25",
  sharesOf: "0xf5eb42dc", totalShares: "0x3a98ef39", claimOf: "0xfccd7f72",
  managedRisk: "0x7bf1cb19", managedSafe: "0xba02153d",
  priceSource: "0x20531bc9", latestPrice: "0x53084eff"
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
  ReRisked: "0x9fcf1dda8d7e7cf9836744c31ed05f39edf04fa0cd6e5702fe58a9345a1d9af9",
  SharesMinted: "0xd5103f333769455df788908e17b0f6f83838ebeae2cd1ed6f23ec20dad88c9a3",
  SharesRedeemed: "0xc2c19174f35fcb7370641b55802c8f596e4827983eefbb49c33373ac0cad5a1d"
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
  const [position, safe, closed, prot, rerisk, ethBal, reserve, riskReserve, totalShares] = await Promise.all([
    call(BASE_RPCS_CALL, V5, SEL.positionSize),
    call(BASE_RPCS_CALL, V5, SEL.safeBalance),
    call(BASE_RPCS_CALL, V5, SEL.closed),
    call(BASE_RPCS_CALL, V5, SEL.protectionCount),
    call(BASE_RPCS_CALL, V5, SEL.reriskCount),
    getBalance(BASE_RPCS_CALL, V5),
    call(BASE_RPCS_CALL, S5, SEL.reserve),
    call(BASE_RPCS_CALL, S5, SEL.riskReserve),
    call(BASE_RPCS_CALL, V5, SEL.totalShares)
  ]);
  return {
    vault: {
      address: V5,
      chain: "Base Sepolia (84532)",
      kind: "per-user pooled vault (SentinelVaultV5) — deposits mint shares, holders redeem their own slice at any time",
      position_weth: fmtTok(U(position), "WETH"),
      position_weth_wei: U(position).toString(),
      safe_balance_musdc: fmtTok(U(safe), "mUSDC"),
      safe_balance_musdc_wei: U(safe).toString(),
      total_shares_outstanding: fmtTok(U(totalShares), "shares"),
      total_shares_outstanding_raw: U(totalShares).toString(),
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
  const vTopics = [TOPIC.ProtectionExecuted, TOPIC.DeRisked, TOPIC.ReRisked, TOPIC.SharesMinted, TOPIC.SharesRedeemed];
  const vLogs = await scanLogs(BASE_RPCS_LOGS, V5, vTopics, V5_DEPLOY, 50000);
  for (const l of vLogs) {
    const t0 = l.topics[0], w = words(l.data), blk = parseInt(l.blockNumber, 16);
    const ts = await getTs(BASE_RPCS_CALL, blk);
    const base = { time: fmtTs(ts), timestamp: ts, chain: "Base Sepolia", tx: l.transactionHash, explorer_tx: BASESCAN + "/tx/" + l.transactionHash };
    if (t0 === TOPIC.SharesMinted) {
      const user = "0x" + l.topics[1].slice(-40);
      items.push({ ...base, kind: "SharesMinted", detail: "Deposit: " + fmtTok(U(w[0]), "WETH") + " in, " + fmtTok(U(w[1]), "shares") + " minted to " + user });
    } else if (t0 === TOPIC.SharesRedeemed) {
      const user = "0x" + l.topics[1].slice(-40);
      items.push({ ...base, kind: "SharesRedeemed", detail: "Redeemed by " + user + ": " + fmtTok(U(w[0]), "shares") + " burned for " + fmtTok(U(w[1]), "WETH") + " + " + fmtTok(U(w[2]), "mUSDC") });
    } else if (t0 === TOPIC.ProtectionExecuted) {
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
const server = new McpServer({ name: "sentinel", version: "1.1.0" });
const json = obj => ({ content: [{ type: "text", text: JSON.stringify(obj, null, 2) }] });
const fail = e => ({ isError: true, content: [{ type: "text", text: "Error: " + (e && e.message ? e.message : String(e)) }] });

server.tool(
  "sentinel_status",
  "Live state of the Sentinel live system (the per-user flagship), read from the contracts at call time: the brain on Lasna (lREACT fuel, price updates ingested, last Chainlink ETH/USD price, anchor, last decision HOLD/TRIM/EXIT/RERISK), the per-user pooled vault on Base Sepolia (WETH position, mock-USDC safe balance, total shares outstanding, closed?, protection and re-risk callback counts, callback billing balance), and the swap desk reserves.",
  {},
  async () => {
    try {
      const [brain, vaultDesk, lastPrice] = await Promise.all([
        readBrainState(), readVaultState(), readLastPrice().catch(() => null)
      ]);
      return json({
        system: "Sentinel — the live system (per-user flagship)",
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
  "Most recent events of the Sentinel live system across both chains, newest first: prices ingested, decisions (with model scores), callbacks requested, TRIM suppressions, re-risk episodes, the vault's protection/de-risk/re-risk executions, and user deposits (shares minted) and redemptions. Each event carries its explorer transaction link.",
  { limit: z.number().int().min(1).max(40).optional().describe("How many events to return (default 14, max 40)") },
  async ({ limit }) => {
    try {
      const events = await collectEvents(limit || 14);
      return json({ count: events.length, events });
    } catch (e) { return fail(e); }
  }
);

/* Expected shares for a deposit, mirroring SentinelVaultV5's own math:
 * first deposit mints 1:1; later deposits mint floor(amount * totalShares /
 * poolRiskEq) with the safe leg valued at the desk's reference price
 * (rounded up, against the depositor). Returns null when the vault would
 * revert (no reference price for a mixed pool). Both pool assets are
 * 18-decimal as deployed. */
async function expectedShares(amount) {
  const [tsHex, mrHex, msHex] = await Promise.all([
    call(BASE_RPCS_CALL, V5, SEL.totalShares),
    call(BASE_RPCS_CALL, V5, SEL.managedRisk),
    call(BASE_RPCS_CALL, V5, SEL.managedSafe)
  ]);
  const totalShares = U(tsHex), managedRisk = U(mrHex), managedSafe = U(msHex);
  if (totalShares === 0n) return amount;
  let poolRiskEq = managedRisk;
  if (managedSafe > 0n) {
    const src = "0x" + (await call(BASE_RPCS_CALL, S5, SEL.priceSource)).slice(-40);
    const price = U(await call(BASE_RPCS_CALL, src, SEL.latestPrice + padAddr(WETH)));
    if (price === 0n) return null;
    const denom = price * 10n ** 18n;
    const safeEq = (managedSafe * 10n ** 18n * 10n ** 18n + denom - 1n) / denom;
    poolRiskEq = managedRisk + safeEq;
  }
  if (poolRiskEq === 0n) return null;
  return (amount * totalShares) / poolRiskEq;
}

async function readUserShares(user) {
  const [sharesHex, claimHex] = await Promise.all([
    call(BASE_RPCS_CALL, V5, SEL.sharesOf + padAddr(user)),
    call(BASE_RPCS_CALL, V5, SEL.claimOf + padAddr(user))
  ]);
  const cw = claimHex.slice(2).padStart(128, "0");
  return {
    shares: U(sharesHex),
    claimRisk: BigInt("0x" + cw.slice(0, 64)),
    claimSafe: BigInt("0x" + cw.slice(64, 128))
  };
}

server.tool(
  "sentinel_prepare_deposit",
  "Prepare the unsigned transactions for depositing test ETH into Sentinel's per-user guarded vault on Base Sepolia: (1) wrap — only the WETH shortfall, computed from the sender's live WETH balance; (2) approve — exact amount, skipped if the vault's allowance already suffices; (3) deposit — which MINTS SHARES in the sender's name. The response reports the sender's current shares and claim, plus the shares this deposit is expected to mint (computed from live pool state with the vault's own formula). Shares are redeemable at any time for the holder's pro-rata slice of both pool assets (WETH + mock USDC). Returns {to, value, data} per step in order. The server NEVER signs and NEVER sends — sign and broadcast with your own wallet. Honest limits: testnet only; the guard acts on the whole pool at once, so every holder shares its decisions pro-rata; the safe asset is a mock token.",
  {
    sender: z.string().regex(/^0x[0-9a-fA-F]{40}$/).describe("Your wallet address on Base Sepolia (the future deposit signer)"),
    amount_eth: z.string().describe("Deposit amount as a decimal ETH string, e.g. \"0.0001\"")
  },
  async ({ sender, amount_eth }) => {
    try {
      const amount = parseEther(amount_eth);
      if (amount <= 0n) throw new Error("amount must be greater than zero");
      const from = sender;
      const [ethBalHex, wethBalHex, allowHex, userShares, minted] = await Promise.all([
        getBalance(BASE_RPCS_CALL, from),
        call(BASE_RPCS_CALL, WETH, SEL.balanceOf + padAddr(from)),
        call(BASE_RPCS_CALL, WETH, SEL.allowance + padAddr(from) + padAddr(V5)),
        readUserShares(from),
        expectedShares(amount)
      ]);
      const ethBal = U(ethBalHex), wethBal = U(wethBalHex), allowance = U(allowHex);
      if (minted === null) throw new Error("the vault cannot value its safe leg right now (no reference price) — a deposit into the mixed pool would revert; try again later");
      if (minted === 0n) throw new Error("this amount is dust at the pool's current share price — it would mint 0 shares and the vault would revert; deposit more");
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
        description: "Deposit " + fmtTok(amount, "WETH") + " into the per-user pool — mints about " + fmtTok(minted, "shares") + " in the sender's name",
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
        sender_shares_now: {
          shares: fmtTok(userShares.shares, "shares"), shares_raw: userShares.shares.toString(),
          claim_weth: fmtTok(userShares.claimRisk, "WETH"), claim_weth_wei: userShares.claimRisk.toString(),
          claim_musdc: fmtTok(userShares.claimSafe, "mUSDC"), claim_musdc_wei: userShares.claimSafe.toString()
        },
        deposit_returns: {
          expected_shares_minted: fmtTok(minted, "shares"), expected_shares_minted_raw: minted.toString(),
          expected_shares_after: fmtTok(userShares.shares + minted, "shares"),
          note: "Computed from live pool state at call time with the vault's own formula; the SharesMinted event of the deposit transaction is authoritative. Shares redeem at any time for your pro-rata slice of both pool assets."
        },
        skipped: [
          ...(shortfall === 0n ? ["wrap — sender already holds enough WETH"] : []),
          ...(allowance >= amount ? ["approve — the vault already has enough allowance"] : [])
        ],
        transactions,
        warnings,
        note: "Unsigned transactions, in execution order. Sign and broadcast them yourself, waiting for each receipt before sending the next. This server holds no keys and sends nothing. Testnet only: the deposit mints shares in your name in the per-user pool, redeemable at any time for your slice of both pool assets."
      });
    } catch (e) { return fail(e); }
  }
);

const CONTRACTS = [
  { name: "SentinelReactiveV5 — the brain (live system)", chain: "Reactive Lasna testnet", chain_id: 5318007, address: R5, explorer: REACTSCAN },
  { name: "SentinelVaultV5 — the per-user vault (live system)", chain: "Base Sepolia", chain_id: BASE_CHAIN_ID, address: V5, explorer: BASESCAN },
  { name: "SentinelSwapV2 — the swap desk (live system)", chain: "Base Sepolia", chain_id: BASE_CHAIN_ID, address: S5, explorer: BASESCAN }
];
server.tool(
  "sentinel_verify",
  "The three Sentinel flagship (Release 6) contracts with Sourcify lookup and block-explorer links. Every contract is verified on Sourcify with an exact match — the code you read is the code that runs.",
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
