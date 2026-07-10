// Мок облака rocket-home для теста token-agent.sh:
//   GET /api/mqtt/v1/token — Bearer "good-access" → JWT jwt-N (счётчик растёт),
//                            всё прочее → 401;
//   POST /oauth/token (refresh) — "good-refresh" → новый good-access,
//                                 иначе → 400 invalid_grant.
// Печатает порт первой строкой stdout.
import { createServer } from "node:http";

let jwtCounter = 0;

const server = createServer((req, res) => {
  let bodyRaw = "";
  req.on("data", (d) => (bodyRaw += d));
  req.on("end", () => {
    const json = (code, obj) => {
      res.writeHead(code, { "content-type": "application/json" });
      res.end(JSON.stringify(obj));
    };

    if (req.method === "GET" && req.url === "/api/mqtt/v1/token") {
      if (req.headers.authorization === "Bearer good-access") {
        jwtCounter += 1;
        return json(200, {
          token: `jwt-${jwtCounter}`,
          locationId: "loc123",
          expiresIn: 3600,
        });
      }
      return json(401, { message: "Unauthenticated." });
    }

    if (req.method === "POST" && req.url === "/oauth/token") {
      const params = new URLSearchParams(bodyRaw);
      if (
        params.get("grant_type") === "refresh_token" &&
        params.get("refresh_token") === "good-refresh"
      ) {
        return json(200, {
          access_token: "good-access",
          refresh_token: "good-refresh",
          expires_in: 31536000,
        });
      }
      return json(400, { error: "invalid_grant" });
    }

    json(404, { error: "not_found" });
  });
});

server.listen(0, "127.0.0.1", () => {
  console.log(server.address().port);
});
