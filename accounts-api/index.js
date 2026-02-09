const express = require("express");

const app = express();
app.use(express.json());

const IDENTITY_BASE_URL =
  process.env.IDENTITY_BASE_URL || "http://identity-api:3001";
const CATALOG_BASE_URL =
  process.env.CATALOG_BASE_URL || "http://catalog-api:3003";

const accountsById = new Map();
const accountsByUserId = new Map();
const balancesByAccountId = new Map();
let accountCounter = 1;

async function fetchJson(url, options) {
  const res = await fetch(url, options);
  const text = await res.text();
  const data = text ? JSON.parse(text) : {};
  if (!res.ok) {
    const error = new Error(data.error || res.statusText);
    error.status = res.status;
    throw error;
  }
  return data;
}

async function ensureUserExists(userId) {
  const data = await fetchJson(
    `${IDENTITY_BASE_URL}/users/${encodeURIComponent(userId)}`
  );
  return data.user || data;
}

function createAccount({ userId, type }) {
  const id = `a${accountCounter++}`;
  const account = { id, userId, type, createdAt: new Date().toISOString() };
  accountsById.set(id, account);
  const existing = accountsByUserId.get(userId) || [];
  existing.push(account);
  accountsByUserId.set(userId, existing);
  balancesByAccountId.set(id, 0);
  return account;
}

function applyCredit(accountId, amount) {
  const current = balancesByAccountId.get(accountId) || 0;
  const next = current + amount;
  balancesByAccountId.set(accountId, next);
  return next;
}

app.post("/accounts", async (req, res) => {
  try {
    const { userId, type = "standard" } = req.body || {};
    if (!userId) {
      return res.status(400).json({ error: "userId is required" });
    }
    await ensureUserExists(userId);
    const account = createAccount({ userId, type });
    return res.status(201).json({ account });
  } catch (err) {
    const status = err.status || 500;
    return res.status(status).json({ error: err.message });
  }
});

app.get("/accounts/:id", (req, res) => {
  const account = accountsById.get(req.params.id);
  if (!account) {
    return res.status(404).json({ error: "account not found" });
  }
  const balance = balancesByAccountId.get(account.id) || 0;
  return res.json({ account, balance });
});

app.get("/accounts", (req, res) => {
  const { userId } = req.query || {};
  if (!userId) {
    return res.status(400).json({ error: "userId query is required" });
  }
  const accounts = accountsByUserId.get(userId) || [];
  return res.json({ accounts });
});

app.post("/accounts/:id/credit", (req, res) => {
  const account = accountsById.get(req.params.id);
  if (!account) {
    return res.status(404).json({ error: "account not found" });
  }
  const { amount } = req.body || {};
  if (typeof amount !== "number" || Number.isNaN(amount)) {
    return res.status(400).json({ error: "amount must be a number" });
  }
  const balance = applyCredit(account.id, amount);
  return res.json({ accountId: account.id, balance });
});

app.post("/accounts/onboard", async (req, res) => {
  try {
    const { name, email, productId, initialCredit = 0 } = req.body || {};
    if (!name || !email || !productId) {
      return res
        .status(400)
        .json({ error: "name, email, and productId are required" });
    }

    const userResponse = await fetchJson(`${IDENTITY_BASE_URL}/users`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name, email }),
    });
    const user = userResponse.user || userResponse;

    const account = createAccount({ userId: user.id, type: "standard" });
    if (typeof initialCredit === "number" && !Number.isNaN(initialCredit)) {
      applyCredit(account.id, initialCredit);
    }

    const assignmentResponse = await fetchJson(
      `${CATALOG_BASE_URL}/products/${encodeURIComponent(productId)}/assign`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ accountId: account.id }),
      }
    );

    const balance = balancesByAccountId.get(account.id) || 0;
    return res.status(201).json({
      user,
      account,
      assignment: assignmentResponse.assignment || assignmentResponse,
      balance,
    });
  } catch (err) {
    const status = err.status || 500;
    return res.status(status).json({ error: err.message });
  }
});

app.get("/health", (_req, res) => {
  res.json({ status: "ok", service: "accounts-api" });
});

const port = Number(process.env.PORT) || 3002;
app.listen(port, () => {
  console.log(`accounts-api listening on port ${port}`);
});
