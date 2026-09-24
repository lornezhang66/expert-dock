import assert from "node:assert/strict";
import test from "node:test";
import worker from "../src/index.js";

test("lists each currently shared expert once", async () => {
  const env = {
    DB: {
      prepare(sql) {
        assert.match(sql, /s\.enabled=1/);
        return {
          async all() {
            return { results: [
              { token: "latest-token", expert_id: "one", name: "one", description: "<script>", type: "expert", version: "2.0.0", manifest: '{"displayName":{"zh":"专家一"}}' },
              { token: "old-token", expert_id: "one", name: "one", description: "old", type: "expert", version: "1.0.0", manifest: "{}" },
              { token: "team-token", expert_id: "two", name: "team", description: "团队", type: "team", version: "1.0.0", manifest: "{}" },
            ] };
          },
        };
      },
    },
  };

  const response = await worker.fetch(new Request("https://example.com/experts"), env);
  const html = await response.text();

  assert.equal(response.status, 200);
  assert.match(html, /专家一/);
  assert.match(html, /href="\/s\/latest-token"/);
  assert.doesNotMatch(html, /old-token/);
  assert.match(html, /href="\/s\/team-token"/);
  assert.match(html, /&lt;script&gt;/);
});
