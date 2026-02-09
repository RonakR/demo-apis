const express = require("express");

const app = express();
app.use(express.json());

const usersById = new Map();
const usersByEmail = new Map();
let userCounter = 1;

function createUser({ name, email }) {
  const id = `u${userCounter++}`;
  const user = { id, name, email };
  usersById.set(id, user);
  usersByEmail.set(email, user);
  return user;
}

app.post("/users", (req, res) => {
  const { name, email } = req.body || {};
  if (!name || !email) {
    return res.status(400).json({ error: "name and email are required" });
  }

  const existing = usersByEmail.get(email);
  if (existing) {
    return res.status(200).json({ user: existing, existing: true });
  }

  const user = createUser({ name, email });
  return res.status(201).json({ user });
});

app.get("/users/:id", (req, res) => {
  const user = usersById.get(req.params.id);
  if (!user) {
    return res.status(404).json({ error: "user not found" });
  }
  return res.json({ user });
});

app.get("/users", (req, res) => {
  const { email } = req.query || {};
  if (!email) {
    return res.status(400).json({ error: "email query is required" });
  }
  const user = usersByEmail.get(email);
  if (!user) {
    return res.status(404).json({ error: "user not found" });
  }
  return res.json({ user });
});

app.get("/health", (_req, res) => {
  res.json({ status: "ok", service: "identity-api" });
});

const port = Number(process.env.PORT) || 3001;
app.listen(port, () => {
  console.log(`identity-api listening on port ${port}`);
});
