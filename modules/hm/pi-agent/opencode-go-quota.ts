/**
 * OpenCode Go Quota Extension for pi
 *
 * Fetches real-time usage data from the official Go usage API:
 *   GET https://opencode.ai/zen/go/v1/usage
 *   Authorization: Bearer <opencode-go api key>
 *
 * Response shape (current):
 *   {
 *     usage: {
 *       rolling:  { status: "ok" | "rate-limited", percent, resetsAt },
 *       weekly:   { status, percent, resetsAt },
 *       monthly:  { status, percent, resetsAt }
 *     }
 *   }
 *
 * Falls back to scraping the old Zen Console dashboard if no API key is set.
 *
 * Also does local per-message cost tracking as a fallback.
 *
 * Setup (env vars):
 *   OPENCODE_API_KEY          — your OpenCode API key (same key as /connect; preferred)
 *   OPENCODE_GO_WORKSPACE_ID  — legacy: workspace ID from the dashboard URL
 *   OPENCODE_GO_AUTH_COOKIE   — legacy: "auth" cookie from opencode.ai
 *
 * Install: place in ~/.pri/agent/extensions/opencode-go-quota.ts
 * No npm dependencies — uses JSON file storage + native fetch.
 */

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import path from "node:path";
import os from "node:os";
import fs from "node:fs";

// ── Limits ─────────────────────────────────────────────────────
const LIMIT_5H = 12;
const LIMIT_WEEK = 30;
const LIMIT_MONTH = 60;

const WINDOW_5H_MS = 5 * 60 * 60 * 1000;
const WINDOW_WEEK_MS = 7 * 24 * 60 * 60 * 1000;
const WINDOW_MONTH_MS = 30 * 24 * 60 * 60 * 1000;

const WARN_AT = 0.8;
const CRITICAL_AT = 0.95;

// ── Model cost estimates ──────────────────────────────────────
const MODEL_COST_PER_REQUEST: Record<string, number> = {
  "glm-5.1": 60 / 4300,
  "glm-5": 60 / 5750,
  "kimi-k2.5": 60 / 9250,
  "kimi-k2.6": 60 / 5750,
  "mimo-v2.5": 60 / 10900,
  "mimo-v2.5-pro": 60 / 6450,
  "mimo-v2-pro": 60 / 6450,
  "mimo-v2-omni": 60 / 6450,
  "minimax-m2.7": 60 / 11500,
  "minimax-m2.5": 60 / 14400,
  "qwen3.6-plus": 60 / 7200,
  "qwen3.5-plus": 60 / 8600,
  "deepseek-v4-pro": 60 / 5750,
  "deepseek-v4-flash": 60 / 10900,
  "hy3-preview": 60 / 10000,
};

function estimatedRequestsRemaining(modelId: string, remainingUsd: number): number {
  const costPerReq = MODEL_COST_PER_REQUEST[modelId];
  if (!costPerReq || costPerReq === 0) return 0;
  return Math.floor(remainingUsd / costPerReq);
}

// ── JSON File Storage ───────────────────────────────────────────
interface UsageRecord {
  timestamp: number;
  modelId: string;
  provider: string;
  tokens: number;
  costUsd: number;
}

interface ScrapeData {
  fraction5h: number;
  fractionWeek: number;
  fractionMonth: number;
  reset5hAt: number;
  resetWeekAt: number;
  resetMonthAt: number;
  fetchedAt: number;
  via: "api" | "scrape" | "manual";
}

interface GoUsageWindow {
  status: "ok" | "rate-limited";
  percent: number;
  resetsAt: string; // ISO timestamp
}

interface GoUsageResponse {
  usage: {
    rolling: GoUsageWindow;
    weekly: GoUsageWindow;
    monthly: GoUsageWindow;
  };
}

interface Store {
  records: UsageRecord[];
  reset5hAt?: number;
  resetWeekAt?: number;
  resetMonthAt?: number;
  scrapeData?: ScrapeData;
}

const STORE_FILE = path.join(
  os.homedir(),
  ".local",
  "share",
  "pi",
  "opencode-go-quota.json",
);

function loadStore(): Store {
  try {
    if (fs.existsSync(STORE_FILE)) {
      const raw = fs.readFileSync(STORE_FILE, "utf-8");
      const store = JSON.parse(raw) as Store;
      // Migrate old anchorTimestamp field if present
      if (!store.reset5hAt && (store as any).anchorTimestamp) {
        const a = (store as any).anchorTimestamp as number;
        store.reset5hAt = a + WINDOW_5H_MS;
        store.resetWeekAt = a + WINDOW_WEEK_MS;
        store.resetMonthAt = a + WINDOW_MONTH_MS;
        delete (store as any).anchorTimestamp;
      }
      return store;
    }
  } catch (err) {
    // Preserve the unreadable file instead of letting a later saveStore()
    // overwrite it — a torn read during a concurrent session's write would
    // otherwise wipe every record on the next insert.
    try {
      const backup = `${STORE_FILE}.corrupt-${Date.now()}`;
      fs.renameSync(STORE_FILE, backup);
      console.error(`[opencode-go-quota] store unreadable, backed up to ${backup}:`, err);
    } catch (backupErr) {
      console.error("[opencode-go-quota] store unreadable and backup failed:", backupErr);
    }
  }
  return { records: [] };
}

function saveStore(store: Store): void {
  const dir = path.dirname(STORE_FILE);
  fs.mkdirSync(dir, { recursive: true });
  const trimmed = store.records.length > 10000
    ? store.records.slice(-10000)
    : store.records;
  const json = JSON.stringify({
    records: trimmed,
    reset5hAt: store.reset5hAt,
    resetWeekAt: store.resetWeekAt,
    resetMonthAt: store.resetMonthAt,
    scrapeData: store.scrapeData,
  }, null, 0);
  // Atomic replace: a concurrent session reading a half-written file would
  // parse-fail, start from an empty store and wipe records on its next save.
  const tmp = `${STORE_FILE}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, json, "utf-8");
  fs.renameSync(tmp, STORE_FILE);
}

function insertRecord(store: Store, record: UsageRecord): void {
  store.records.push(record);
  saveStore(store);
}

// ── Usage API (official) ────────────────────────────────────────
const USAGE_API_URL = "https://opencode.ai/zen/go/v1/usage";
const SCRAPE_INTERVAL_MS = 5 * 60 * 1000; // 5 minutes
// Background refreshes give up fast; interactive commands keep the full budget.
const REFRESH_TIMEOUT_MS = 4000;
// Skip background refreshes younger than this (several sessions may start at once).
const FRESH_MS = 60 * 1000;

interface RefreshOptions {
  force?: boolean;
  timeoutMs?: number;
}

function getApiKey(): string | null {
  return process.env.OPENCODE_API_KEY?.trim() || null;
}

async function fetchUsageApi(timeoutMs = 10000): Promise<ScrapeData | { error: string } | null> {
  const apiKey = getApiKey();
  if (!apiKey) return null;

  try {
    const resp = await fetch(USAGE_API_URL, {
      headers: {
        "Authorization": `Bearer ${apiKey}`,
      },
      signal: AbortSignal.timeout(timeoutMs),
    });

    if (!resp.ok) {
      const body = await resp.json().catch(() => null) as { error?: { message?: string } } | null;
      const msg = body?.error?.message;
      if (resp.status === 401) return { error: `Auth failed (${msg ?? "invalid API key"})` };
      if (resp.status === 403) return { error: `No Go subscription (${msg ?? "EntitlementError"})` };
      return { error: `HTTP ${resp.status}${msg ? ": " + msg : ""}` };
    }

    const json = await resp.json() as GoUsageResponse;
    if (!json.usage?.rolling || !json.usage?.weekly || !json.usage?.monthly) {
      return { error: "Unexpected response shape" };
    }

    const now = Date.now();
    const windows = json.usage;
    const toData = (w: GoUsageWindow): { fraction: number; resetAt: number } => ({
      fraction: Math.max(0, Math.min(1, w.percent / 100)),
      resetAt: Date.parse(w.resetsAt) || now,
    });
    const rolling = toData(windows.rolling);
    const weekly = toData(windows.weekly);
    const monthly = toData(windows.monthly);

    return {
      fraction5h: rolling.fraction,
      fractionWeek: weekly.fraction,
      fractionMonth: monthly.fraction,
      reset5hAt: rolling.resetAt,
      resetWeekAt: weekly.resetAt,
      resetMonthAt: monthly.resetAt,
      fetchedAt: now,
      via: "api",
    };
  } catch (err) {
    return { error: err instanceof Error ? err.message : String(err) };
  }
}

function getWorkspaceId(): string | null {
  return process.env.OPENCODE_GO_WORKSPACE_ID?.trim() || null;
}

function getAuthCookie(): string | null {
  return process.env.OPENCODE_GO_AUTH_COOKIE?.trim() || null;
}

function isApiConfigured(): boolean {
  return !!getApiKey();
}

function isConfigured(): boolean {
  return isApiConfigured() || !!(getWorkspaceId() && getAuthCookie());
}

function parseDashboard(html: string): Omit<ScrapeData, "via"> | null {
  const NUM = String.raw`(-?\d+(?:\.\d+)?)`;

  // SolidJS SSR hydration output — field order may vary
  const rollingRe1 = new RegExp(String.raw`rollingUsage:\$R\[\d+\]=\{[^}]*usagePercent:${NUM}[^}]*resetInSec:${NUM}[^}]*\}`);
  const rollingRe2 = new RegExp(String.raw`rollingUsage:\$R\[\d+\]=\{[^}]*resetInSec:${NUM}[^}]*usagePercent:${NUM}[^}]*\}`);
  const weeklyRe1 = new RegExp(String.raw`weeklyUsage:\$R\[\d+\]=\{[^}]*usagePercent:${NUM}[^}]*resetInSec:${NUM}[^}]*\}`);
  const weeklyRe2 = new RegExp(String.raw`weeklyUsage:\$R\[\d+\]=\{[^}]*resetInSec:${NUM}[^}]*usagePercent:${NUM}[^}]*\}`);
  const monthlyRe1 = new RegExp(String.raw`monthlyUsage:\$R\[\d+\]=\{[^}]*usagePercent:${NUM}[^}]*resetInSec:${NUM}[^}]*\}`);
  const monthlyRe2 = new RegExp(String.raw`monthlyUsage:\$R\[\d+\]=\{[^}]*resetInSec:${NUM}[^}]*usagePercent:${NUM}[^}]*\}`);

  function parseWindow(re1: RegExp, re2: RegExp): { pct: number; resetSec: number } | null {
    const m1 = re1.exec(html);
    if (m1) return { pct: Number(m1[1]), resetSec: Number(m1[2]) };
    const m2 = re2.exec(html);
    if (m2) return { pct: Number(m2[2]), resetSec: Number(m2[1]) };
    return null;
  }

  const rolling = parseWindow(rollingRe1, rollingRe2);
  const weekly = parseWindow(weeklyRe1, weeklyRe2);
  const monthly = parseWindow(monthlyRe1, monthlyRe2);

  if (!rolling || !weekly || !monthly) return null;

  const now = Date.now();
  return {
    fraction5h: Math.max(0, Math.min(1, rolling.pct / 100)),
    fractionWeek: Math.max(0, Math.min(1, weekly.pct / 100)),
    fractionMonth: Math.max(0, Math.min(1, monthly.pct / 100)),
    reset5hAt: now + rolling.resetSec * 1000,
    resetWeekAt: now + weekly.resetSec * 1000,
    resetMonthAt: now + monthly.resetSec * 1000,
    fetchedAt: now,
  };
}

// ── Dashboard Scraper (legacy fallback) ──────────────────────────

async function fetchDashboard(timeoutMs = 10000): Promise<Omit<ScrapeData, "via"> | null> {
  const workspaceId = getWorkspaceId();
  const authCookie = getAuthCookie();
  if (!workspaceId || !authCookie) return null;

  try {
    const url = `https://opencode.ai/workspace/${workspaceId}/go`;
    const resp = await fetch(url, {
      headers: {
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Gecko/20100101 Firefox/148.0",
        "Cookie": `auth=${authCookie}`,
      },
      signal: AbortSignal.timeout(timeoutMs),
    });

    if (!resp.ok) return null;
    const html = await resp.text();
    return parseDashboard(html);
  } catch {
    return null;
  }
}

// ── Window Calculations ────────────────────────────────────────
interface WindowData {
  spend: number;
  limit: number;
  fraction: number;
  remaining: number;
  resetInMs: number;
  source: "scrape" | "local" | "fallback";
}

function getWindowData(store: Store, windowMs: number, limit: number, resetAt?: number, scrapedFraction?: number): WindowData {
  const now = Date.now();
  const cutoff = now - windowMs;

  // Calculate local spend from records
  let localSpend = 0;
  for (const r of store.records) {
    if (r.timestamp >= cutoff) localSpend += r.costUsd;
  }

  let resetInMs: number;
  if (resetAt) {
    resetInMs = Math.max(0, resetAt - now);
  } else {
    let oldest = now;
    for (const r of store.records) {
      if (r.timestamp >= cutoff && r.timestamp < oldest) oldest = r.timestamp;
    }
    resetInMs = oldest < now ? oldest + windowMs - now : windowMs;
  }

  // When scraped fraction is available, derive spend from it (server is source of truth)
  // Otherwise fall back to local spend tracking
  let fraction: number;
  let spend: number;
  let source: "scrape" | "local" | "fallback";

  if (scrapedFraction !== undefined) {
    fraction = scrapedFraction;
    spend = scrapedFraction * limit; // derive spend from server percentage
    source = "scrape";
  } else if (localSpend > 0) {
    fraction = Math.min(1, localSpend / limit);
    spend = localSpend;
    source = "local";
  } else {
    fraction = 0;
    spend = 0;
    source = "fallback";
  }

  return { spend, limit, fraction, remaining: Math.max(0, limit - spend), resetInMs, source };
}

// ── Time Formatting ─────────────────────────────────────────────
function formatReset(ms: number): string {
  if (ms <= 0) return "resets now";
  const totalSec = Math.floor(ms / 1000);
  const hours = Math.floor(totalSec / 3600);
  const minutes = Math.floor((totalSec % 3600) / 60);
  if (hours >= 24) {
    const days = Math.floor(hours / 24);
    const remHours = hours % 24;
    return remHours > 0 ? `${days}d ${remHours}h` : `${days}d`;
  }
  if (hours > 0) return `${hours}h ${minutes}min`;
  return `${minutes}min`;
}

function formatSpend(n: number): string {
  return `$${n.toFixed(2)}`;
}

function pct(fraction: number): string {
  return `${(fraction * 100).toFixed(1)}%`;
}

// Parse a reset countdown string like "4d 9h" or "3h 53min" into ms
function parseReset(s: string): number | null {
  const clean = s.trim().toLowerCase();
  if (!clean) return null;
  let ms = 0;
  const dayM = clean.match(/(\d+)\s*d/);
  if (dayM) ms += parseInt(dayM[1]) * 24 * 60 * 60 * 1000;
  const hourM = clean.match(/(\d+)\s*h/);
  if (hourM) ms += parseInt(hourM[1]) * 60 * 60 * 1000;
  const minM = clean.match(/(\d+)\s*min/);
  if (minM) ms += parseInt(minM[1]) * 60 * 1000;
  if (ms === 0) {
    const num = parseFloat(clean);
    if (!isNaN(num)) ms = num * 60 * 60 * 1000;
  }
  return ms > 0 ? ms : null;
}

// ─ Provider/Model Detection ───────────────────────────────────
function isOpencodeGoProvider(provider: string): boolean {
  const p = provider.toLowerCase();
  return p.includes("opencode") && p.includes("go");
}

function isOpencodeGoModel(modelId: string): boolean {
  return modelId.startsWith("opencode-go/");
}

// ── Extension ───────────────────────────────────────────────────
export default function opencodeGoQuotaExtension(pi: ExtensionAPI) {
  let store = loadStore();
  let currentModel: { provider: string; id: string } | null = null;
  const statusKey = "opencode-go-quota";
  let scrapeTimer: ReturnType<typeof setInterval> | null = null;
  // Cached ctx.ui for footer updates — set by the latest event handler
  let uiCtx: ExtensionContext | null = null;

  fs.mkdirSync(path.dirname(STORE_FILE), { recursive: true });

  // ── Fetch usage in the background, then periodically ─────────
  // Never blocks the caller: pi awaits every session_start handler serially,
  // so startup must not wait on this — callers fire-and-forget it.
  // Resolves true only when this call actually fetched and stored fresh data,
  // so commands can report failure instead of trusting the cached scrapeData.
  async function refreshScrape(opts: RefreshOptions = {}): Promise<boolean> {
    if (!isConfigured()) return false;
    const fetchedAt = store.scrapeData?.fetchedAt ?? 0;
    if (!opts.force && Date.now() - fetchedAt < FRESH_MS) return false;
    const timeoutMs = opts.timeoutMs ?? REFRESH_TIMEOUT_MS;

    let data: ScrapeData | null = null;

    // Preferred: official usage API
    if (isApiConfigured()) {
      const result = await fetchUsageApi(timeoutMs);
      if (result && "fraction5h" in result) {
        data = result;
      } else if (result && "error" in result) {
        console.error("[opencode-go-quota] usage API failed:", result.error);
      }
    }

    // Fallback: legacy dashboard scraper
    if (!data && !isApiConfigured()) {
      const scraped = await fetchDashboard(timeoutMs);
      if (scraped) data = { ...scraped, via: "scrape" };
    }

    if (!data) return false;

    store.scrapeData = data;
    store.reset5hAt = data.reset5hAt;
    store.resetWeekAt = data.resetWeekAt;
    store.resetMonthAt = data.resetMonthAt;
    try {
      saveStore(store);
    } catch (err) {
      console.error("[opencode-go-quota] failed to persist usage data:", err);
    }
    updateFooter();
    return true;
  }

  // ── Footer status line ───────────────────────────────────────
  function getFooterStatus(): string | null {
    const sd = store.scrapeData;
    const w5h = getWindowData(store, WINDOW_5H_MS, LIMIT_5H, store.reset5hAt, sd?.fraction5h);
    const wWeek = getWindowData(store, WINDOW_WEEK_MS, LIMIT_WEEK, store.resetWeekAt, sd?.fractionWeek);
    const wMonth = getWindowData(store, WINDOW_MONTH_MS, LIMIT_MONTH, store.resetMonthAt, sd?.fractionMonth);

    const parts: string[] = [
      `5h: ${pct(w5h.fraction)} (${formatReset(w5h.resetInMs)})`,
      `wk: ${pct(wWeek.fraction)} (${formatReset(wWeek.resetInMs)})`,
      `mo: ${pct(wMonth.fraction)} (${formatReset(wMonth.resetInMs)})`,
    ];

    return `GO ${parts.join("  ")}`;
  }

  function updateFooter(): void {
    try {
      if (!uiCtx?.ui) return;
      const status = getFooterStatus();
      if (status) {
        uiCtx.ui.setStatus(statusKey, status);
      }
    } catch (err) {
      console.error("[opencode-go-quota] updateFooter failed:", err);
    }
  }

  // ── Zen Console-style dashboard ───────────────────────────────
  function renderZenDashboard(): string[] {
    const sd = store.scrapeData;
    const w5h = getWindowData(store, WINDOW_5H_MS, LIMIT_5H, store.reset5hAt, sd?.fraction5h);
    const wWeek = getWindowData(store, WINDOW_WEEK_MS, LIMIT_WEEK, store.resetWeekAt, sd?.fractionWeek);
    const wMonth = getWindowData(store, WINDOW_MONTH_MS, LIMIT_MONTH, store.resetMonthAt, sd?.fractionMonth);

    const W = 72;
    const COL = 21;
    const BAR = 12;

    function bar(f: number): string {
      const filled = Math.max(0, Math.round(f * BAR));
      return "█".repeat(filled) + "░".repeat(BAR - filled);
    }
    function dot(f: number): string {
      return f >= CRITICAL_AT ? "" : f >= WARN_AT ? "🟡" : "🟢";
    }
    function win(title: string, d: WindowData): [string, string, string] {
      return [
        title,
        `${pct(d.fraction)}${dot(d.fraction)} ${bar(d.fraction)}`,
        `resets in ${formatReset(d.resetInMs)}`,
      ];
    }
    function line(s: string): string {
      return `│ ${s.padEnd(W - 4)} │`;
    }
    function hr(): string {
      return `├${"─".repeat(W - 2)}┤`;
    }

    const out: string[] = [];
    out.push(`┌${"─".repeat(W - 2)}┐`);
    out.push(line("GO"));
    out.push(line("Affordable coding models for everyone."));
    out.push(line(""));
    out.push(line("You have subscribed to OpenCode Go."));
    out.push(hr());
    out.push(line(""));

    const [c1, c2, c3] = [win("Rolling (5h)", w5h), win("Weekly", wWeek), win("Monthly", wMonth)];
    for (let r = 0; r < 3; r++) {
      out.push(line(`${c1[r].padEnd(COL)}  ${c2[r].padEnd(COL)}  ${c3[r].padEnd(COL)}`));
    }

    out.push(line(""));
    out.push(hr());
    out.push(line(`5h: ${formatSpend(w5h.spend).padEnd(6)} / ${formatSpend(LIMIT_5H).padEnd(6)}  wk: ${formatSpend(wWeek.spend).padEnd(6)} / ${formatSpend(LIMIT_WEEK).padEnd(6)}  mo: ${formatSpend(wMonth.spend).padEnd(6)} / ${formatSpend(LIMIT_MONTH).padEnd(6)}`));

    if (currentModel && isOpencodeGoModel(currentModel.id)) {
      const mid = currentModel.id.replace("opencode-go/", "");
      const reqs = estimatedRequestsRemaining(mid, w5h.remaining);
      out.push(line(`~${String(reqs).padStart(4)} requests left (5h, ${mid})`));
    }

    out.push(line(""));
    const sourceLabel = sd
      ? `Data from ${sd.via === "api" ? "Go usage API" : sd.via === "scrape" ? "Zen Console (legacy scrape)" : "manual input"} ┃ last update ${formatReset(Date.now() - sd.fetchedAt)} ago`
      : `Local tracking only (no API key / scrape config)`;
    out.push(line(sourceLabel));
    out.push(`└${"─".repeat(W - 2)}┘`);
    return out;
  }

  // ── Warnings ──────────────────────────────────────────────────
  function checkWarnings(ctx: ExtensionContext): void {
    const sd = store.scrapeData;
    const w5h = getWindowData(store, WINDOW_5H_MS, LIMIT_5H, store.reset5hAt, sd?.fraction5h);
    const wWeek = getWindowData(store, WINDOW_WEEK_MS, LIMIT_WEEK, store.resetWeekAt, sd?.fractionWeek);
    const wMonth = getWindowData(store, WINDOW_MONTH_MS, LIMIT_MONTH, store.resetMonthAt, sd?.fractionMonth);

    const windows = [
      { label: "5h window", data: w5h },
      { label: "Weekly", data: wWeek },
      { label: "Monthly", data: wMonth },
    ];

    const warnings: string[] = [];
    for (const { label, data } of windows) {
      if (data.fraction >= CRITICAL_AT) {
        warnings.push(`${label} at ${pct(data.fraction)} (${formatSpend(data.spend)}/${formatSpend(data.limit)}) — almost exhausted!`);
      } else if (data.fraction >= WARN_AT) {
        warnings.push(`${label} at ${pct(data.fraction)} — approaching limit`);
      }
    }

    if (warnings.length > 0 && currentModel) {
      const mid = currentModel.id.replace("opencode-go/", "");
      const cost = MODEL_COST_PER_REQUEST[mid] || 0;
      const cheaper = Object.entries(MODEL_COST_PER_REQUEST)
        .filter(([, c]) => c < cost && c > 0)
        .sort((a, b) => a[1] - b[1])
        .slice(0, 3)
        .map(([id]) => id);
      if (cheaper.length > 0) warnings.push(`Cheaper: ${cheaper.join(", ")}`);
    }

    if (warnings.length > 0) {
      const level = warnings.some(w => w.includes("almost exhausted")) ? "warning" as const : "info" as const;
      ctx.ui.notify(` OpenCode Go Quota:\n${warnings.join("\n")}`, level);
    }
  }

  // ── Event: Track current model ─────────────────────────────
  pi.on("model_select", async (event, ctx) => {
    uiCtx = ctx;
    currentModel = { provider: event.model.provider, id: event.model.id };
    updateFooter();
  });

  // ── Event: Track usage on message_end ───────────────────────
  pi.on("message_end", async (event, ctx) => {
    uiCtx = ctx;
    if (event.message.role !== "assistant") return;

    let model = currentModel;
    if (!model && ctx.model) {
      model = { provider: ctx.model.provider, id: ctx.model.id };
      currentModel = model;
    }
    if (!model) return;
    if (!isOpencodeGoProvider(model.provider) && !isOpencodeGoModel(model.id)) return;

    const usage = event.message.usage;
    if (!usage) return;

    const cost = usage.cost?.total ?? 0;
    if (cost === 0) return;

    const record: UsageRecord = {
      timestamp: Date.now(),
      modelId: model.id.replace("opencode-go/", ""),
      provider: model.provider,
      tokens: usage.tokens ?? 0,
      costUsd: cost,
    };

    try {
      insertRecord(store, record);
      updateFooter();
      checkWarnings(ctx);
    } catch (err) {
      console.error("[opencode-go-quota] Failed to record usage:", err);
    }
  });

  // ── Command: /quota ─────────────────────────────────────────
  pi.registerCommand("quota", {
    description: "OpenCode Go usage dashboard (Zen Console style)",
    handler: async (_args, ctx) => {
      // Try a fresh scrape before showing (interactive — worth the wait)
      await refreshScrape({ force: true, timeoutMs: 10000 });
      await ctx.ui.select("OpenCode Go — Quota Dashboard", renderZenDashboard());
    },
  });

  // ── Command: /quota-debug ───────────────────────────────────
  pi.registerCommand("quota-debug", {
    description: "Show internal quota extension state for debugging",
    handler: async (_args, ctx) => {
      const sd = store.scrapeData;
      const lines: string[] = [
        "=== OpenCode Go Quota Debug ===",
        "",
        `Configured: ${isConfigured()}`,
        `Workspace ID: ${getWorkspaceId() || "(not set)"}`,
        `Auth cookie: ${getAuthCookie() ? "set (" + getAuthCookie()!.slice(0, 8) + "...)" : "(not set)"}`,
        "",
        "Store:",
        `  records: ${store.records.length}`,
        `  reset5hAt: ${store.reset5hAt || "unset"}`,
        `  resetWeekAt: ${store.resetWeekAt || "unset"}`,
        `  resetMonthAt: ${store.resetMonthAt || "unset"}`,
        "",
        "Scrape data:",
        sd ? [
          `  fetchedAt: ${new Date(sd.fetchedAt).toLocaleString()}`,
          `  via: ${sd.via ?? "(legacy)"}`,
          `  fraction5h: ${sd.fraction5h}`,
          `  fractionWeek: ${sd.fractionWeek}`,
          `  fractionMonth: ${sd.fractionMonth}`,
          `  reset5hAt: ${new Date(sd.reset5hAt).toLocaleString()}`,
          `  resetWeekAt: ${new Date(sd.resetWeekAt).toLocaleString()}`,
          `  resetMonthAt: ${new Date(sd.resetMonthAt).toLocaleString()}`,
        ].join("\n") : "  none",
        "",
        "Computed windows:",
        (() => {
          const w5h = getWindowData(store, WINDOW_5H_MS, LIMIT_5H, store.reset5hAt, sd?.fraction5h);
          const wWeek = getWindowData(store, WINDOW_WEEK_MS, LIMIT_WEEK, store.resetWeekAt, sd?.fractionWeek);
          const wMonth = getWindowData(store, WINDOW_MONTH_MS, LIMIT_MONTH, store.resetMonthAt, sd?.fractionMonth);
          return [
            `  5h: ${pct(w5h.fraction)} spend=${formatSpend(w5h.spend)} reset=${formatReset(w5h.resetInMs)} source=${w5h.source}`,
            `  wk: ${pct(wWeek.fraction)} spend=${formatSpend(wWeek.spend)} reset=${formatReset(wWeek.resetInMs)} source=${wWeek.source}`,
            `  mo: ${pct(wMonth.fraction)} spend=${formatSpend(wMonth.spend)} reset=${formatReset(wMonth.resetInMs)} source=${wMonth.source}`,
          ].join("\n");
        })(),
        "",
        "Footer status:",
        `  "${getFooterStatus() || "(null)"}"`,
        "",
      ];
      await ctx.ui.select("OpenCode Go Quota — Debug", lines);
    },
  });

  // ── Command: /quota-reset ───────────────────────────────────
  pi.registerCommand("quota-reset", {
    description: "Reset all locally tracked OpenCode Go usage data",
    handler: async (_args, ctx) => {
      const confirmed = await ctx.ui.confirm(
        "Reset Quota Data",
        `Delete all ${store.records.length} tracked records? Scrape data is unaffected.`,
      );
      if (confirmed) {
        store.records = [];
        saveStore(store);
        updateFooter();
        ctx.ui.notify("OpenCode Go usage data cleared", "info");
      } else {
        ctx.ui.notify("Reset cancelled", "info");
      }
    },
  });

  // ── Command: /quota-init — manual fallback ─────────────────
  pi.registerCommand("quota-init", {
    description: "Manually seed quota data (use /quota-refresh instead for live data)",
    handler: async (_args, ctx) => {
      const infoLines = [
        "Manual seeding is deprecated. Set these env vars instead:",
        "",
        "  export OPENCODE_GO_WORKSPACE_ID=your-id",
        "  export OPENCODE_GO_AUTH_COOKIE=your-cookie",
        "",
        "Then use /quota-refresh to fetch live data.",
        "",
        "If you still want to enter values manually:",
      ];
      await ctx.ui.select("OpenCode Go — Init", infoLines);

      const reset5hStr = await ctx.ui.input("5h window resets in:", "e.g. 3h 53min");
      const reset5hMs = parseReset(reset5hStr);

      const resetWeekStr = await ctx.ui.input("Weekly resets in:", "e.g. 4d 9h");
      const resetWeekMs = parseReset(resetWeekStr);

      const resetMonthStr = await ctx.ui.input("Monthly resets in:", "e.g. 6d 20h");
      const resetMonthMs = parseReset(resetMonthStr);

      const now = Date.now();
      const reset5hAt = reset5hMs ? now + reset5hMs : undefined;
      const resetWeekAt = resetWeekMs ? now + resetWeekMs : undefined;
      const resetMonthAt = resetMonthMs ? now + resetMonthMs : undefined;

      const pctLines = [
        "Enter the three percentages:",
        "",
        "  ┌────────────────┬──────────┬──────────┐",
        "  │ Rolling (5h)   │ Weekly   │ Monthly  │",
        "  ├────────────────┼──────────┼──────────┤",
        "  │ <percentage>   │ <perc.>  │ <perc.>  │",
        "  └──────────────────────────┴──────────┘",
      ];
      await ctx.ui.select("OpenCode Go — Enter Percentages", pctLines);

      const input5h = await ctx.ui.input("Rolling (5h) %:", "e.g. 28");
      const pct5h = Math.min(100, Math.max(0, parseFloat(input5h) || 0));
      const spend5h = (pct5h / 100) * LIMIT_5H;

      const inputWeek = await ctx.ui.input("Weekly %:", "e.g. 45");
      const pctWeek = Math.min(100, Math.max(0, parseFloat(inputWeek) || 0));
      const spendWeek = (pctWeek / 100) * LIMIT_WEEK;

      const inputMonth = await ctx.ui.input("Monthly %:", "e.g. 71");
      const pctMonth = Math.min(100, Math.max(0, parseFloat(inputMonth) || 0));
      const spendMonth = (pctMonth / 100) * LIMIT_MONTH;

      // Store as scrape data so the display uses these values
      store.scrapeData = {
        fraction5h: pct5h / 100,
        fractionWeek: pctWeek / 100,
        fractionMonth: pctMonth / 100,
        reset5hAt: reset5hAt ?? now + WINDOW_5H_MS,
        resetWeekAt: resetWeekAt ?? now + WINDOW_WEEK_MS,
        resetMonthAt: resetMonthAt ?? now + WINDOW_MONTH_MS,
        fetchedAt: now,
        via: "manual",
      };
      store.reset5hAt = store.scrapeData.reset5hAt;
      store.resetWeekAt = store.scrapeData.resetWeekAt;
      store.resetMonthAt = store.scrapeData.resetMonthAt;
      saveStore(store);
      updateFooter();

      const resetInfo = [
        reset5hMs ? `5h:${formatReset(reset5hMs)}` : "5h:—",
        resetWeekMs ? `wk:${formatReset(resetWeekMs)}` : "wk:—",
        resetMonthMs ? `mo:${formatReset(resetMonthMs)}` : "mo:—",
      ].join(" ");
      ctx.ui.notify(
        `Seeded: ${resetInfo}\n5h=${pct(pct5h / 100)} wk=${pct(pctWeek / 100)} mo=${pct(pctMonth / 100)}`,
        "info",
      );
    },
  });

  // ── Command: /quota-refresh ─────────────────────────────────
  pi.registerCommand("quota-refresh", {
    description: "Fetch latest quota data from the Go usage API",
    handler: async (_args, ctx) => {
      if (!isConfigured()) {
        ctx.ui.notify("Missing env var: OPENCODE_API_KEY (or legacy WORKSPACE_ID + AUTH_COOKIE)", "warning");
        return;
      }
      ctx.ui.notify("Fetching usage data...", "info");
      const refreshed = await refreshScrape({ force: true, timeoutMs: 10000 });
      if (refreshed) {
        ctx.ui.notify(`Usage data refreshed (via ${store.scrapeData?.via})`, "info");
      } else {
        ctx.ui.notify("Failed to fetch usage data. Check your credentials.", "warning");
      }
    },
  });

  // ─ Session start ──────────────────────────────────────────
  pi.on("session_start", async (_event, ctx) => {
    // Arm with the fresh context; the previous runtime's ctx is stale after
    // session replacement/reload and must not be reused.
    uiCtx = ctx;
    store = loadStore();
    // Show cached data immediately; the network refresh runs in the background
    // (pi awaits session_start handlers serially, so awaiting it here would
    // hold back "Startup is still in progress" for up to the fetch timeout).
    updateFooter();
    void refreshScrape().catch((err) =>
      console.error("[opencode-go-quota] background refresh failed:", err));
    // Then set up periodic refresh
    if (isConfigured() && !scrapeTimer) {
      scrapeTimer = setInterval(() => {
        void refreshScrape().catch((err) =>
          console.error("[opencode-go-quota] periodic refresh failed:", err));
      }, SCRAPE_INTERVAL_MS);
    }
  });

  pi.on("session_shutdown", async () => {
    // Emitted before pi invalidates the runner: nulling uiCtx here makes any
    // in-flight refreshScrape() no-op in updateFooter() instead of throwing
    // "This extension ctx is stale after session replacement or reload."
    uiCtx = null;
    if (scrapeTimer) {
      clearInterval(scrapeTimer);
      scrapeTimer = null;
    }
  });

  pi.on("resources_discover", async (_event, ctx) => {
    uiCtx = ctx;
    updateFooter();
  });
}
