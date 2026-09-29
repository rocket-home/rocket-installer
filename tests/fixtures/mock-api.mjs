// Мок облака rocket-home для теста token-agent.sh:
//   GET /api/mqtt/v1/token[?lifetime=grant] и /api/mqtt/v1/locations/{id}/token:
//     Bearer "good-access"  → короткий JWT jwt-N (lifetime: short — старое/выключенное облако);
//     Bearer "grant-access" → токен моста gjwt-N на год (lifetime: grant), если просили grant;
//     всё прочее → 401;
//   POST /oauth/token (refresh):
//     "good-refresh"  → good-access;  "grant-refresh" → grant-access;
//     "flaky-refresh" → 503 (сеть/облако лежит);  иначе → 400 invalid_grant;
//   GET /__stats → {"requests": N} — сколько запросов к облаку было (кроме самого /__stats).
// Печатает порт первой строкой stdout.
import { createServer } from "node:http";

let jwtCounter = 0;
let requests = 0;

const server = createServer((req, res) => {
  let bodyRaw = "";
  req.on("data", (d) => (bodyRaw += d));
  req.on("end", () => {
    const json = (code, obj) => {
      res.writeHead(code, { "content-type": "application/json" });
      res.end(JSON.stringify(obj));
    };
    const url = new URL(req.url, "http://mock");

    if (url.pathname === "/__stats") return json(200, { requests });
    requests += 1;

    const isToken =
      url.pathname === "/api/mqtt/v1/token" ||
      /^\/api\/mqtt\/v1\/locations\/[^/]+\/token$/.test(url.pathname);

    if (req.method === "GET" && isToken) {
      const auth = req.headers.authorization;
      const wantGrant = url.searchParams.get("lifetime") === "grant";
      if (auth === "Bearer good-access" || auth === "Bearer grant-access") {
        jwtCounter += 1;
        if (auth === "Bearer grant-access" && wantGrant) {
          return json(200, {
            token: `gjwt-${jwtCounter}`,
            locationId: "loc123",
            expiresIn: 31536000,
            lifetime: "grant",
          });
        }
        return json(200, {
          token: `jwt-${jwtCounter}`,
          locationId: "loc123",
          expiresIn: 3600,
          ...(wantGrant ? { lifetime: "short" } : {}),
        });
      }
      return json(401, { message: "Unauthenticated." });
    }

    if (req.method === "POST" && url.pathname === "/oauth/token") {
      const params = new URLSearchParams(bodyRaw);
      const rt = params.get("refresh_token");
      if (params.get("grant_type") === "refresh_token") {
        if (rt === "good-refresh" || rt === "grant-refresh") {
          return json(200, {
            access_token: rt === "grant-refresh" ? "grant-access" : "good-access",
            refresh_token: rt,
            expires_in: 31536000,
          });
        }
        if (rt === "flaky-refresh") return json(503, { error: "unavailable" });
      }
      return json(400, { error: "invalid_grant" });
    }

    json(404, { error: "not_found" });
  });
});

server.listen(0, "127.0.0.1", () => {
  console.log(server.address().port);
});
