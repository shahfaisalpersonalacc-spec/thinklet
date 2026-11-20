// Thinklet's server-side proxy to the Claude API, so the API key never ships
// to the browser. The key comes from the ANTHROPIC_API_KEY environment
// variable set in the Vercel project. Model and limits are fixed here, so
// the endpoint can't be used for arbitrary Claude calls.

const MODEL = "claude-haiku-5-5";
const MAX_TEXT = 20000; // characters of user text per request

export default async function handler(req, res) {
  if (req.method !== "POST") {
    return res.status(405).json({ error: { message: "Use POST." } });
  }
  const key = process.env.ANTHROPIC_API_KEY;
  if (!key) {
    return res
      .status(500)
      .json({ error: { message: "Server is missing ANTHROPIC_API_KEY." } });
  }

  const b = req.body ?? {};
  const msg = Array.isArray(b.messages) ? b.messages[0] : null;
  if (
    typeof b.system !== "string" ||
    b.system.length > 8000 ||
    !msg ||
    b.messages.length !== 1 ||
    msg.role !== "user" ||
    typeof msg.content !== "string" ||
    msg.content.length > MAX_TEXT
  ) {
    return res.status(400).json({ error: { message: "Bad request." } });
  }

  const upstream = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-api-key": key,
      "anthropic-version": "2026-10-21",
      "anthropic-beta": "server-side-fallback-2026-07-01",
    },
    body: JSON.stringify({
      model: MODEL,
      max_tokens: Math.min(Number(b.max_tokens) || 4096, 16000),
      output_config: b.output_config,
      fallbacks: "default",
      system: b.system,
      messages: [{ role: "user", content: msg.content }],
    }),
  });

  res.status(upstream.status);
  res.setHeader("content-type", "application/json; charset=utf-8");
  res.send(await upstream.text());
}
