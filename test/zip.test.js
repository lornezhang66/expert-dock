import test from "node:test";
import assert from "node:assert/strict";
import { strToU8, zipSync } from "fflate";
import { inspectExpertZip } from "../src/zip.js";

const prompt = { en: "Help me", zh: "请帮助我" };
const manifest = {
  name: "demo-expert",
  version: "1.0.0",
  expertType: "agent",
  description: "A focused demo expert.",
  author: { name: "Tester", email: "test@example.com" },
  agents: ["./agents/demo-expert.md"],
  agentName: "demo-expert",
  displayName: { en: "Demo Expert", zh: "演示专家" },
  profession: { en: "Demo Specialist", zh: "演示顾问" },
  displayDescription: { en: "A demo expert used to validate packages.", zh: "专".repeat(40) },
  avatar: "avatars/expert.png",
  categoryId: "02-Engineering",
  defaultInitPrompt: prompt,
  plugin: "demo-expert",
  tags: [{ en: "Demo", zh: "演示" }, { en: "Test", zh: "测试" }, { en: "Quality", zh: "质量" }],
  quickPrompts: [prompt, { en: "Check this", zh: "检查这个" }, { en: "Explain this", zh: "解释这个" }],
};
const agent = `---\nname: demo-expert\ndescription: A demo expert\ndisplayName: { en: Demo, zh: 演示 }\nprofession: { en: Specialist, zh: 顾问 }\n---\nYou are a demo expert.`;
const png = new Uint8Array(36);
png.set([0x89, 0x50, 0x4e, 0x47], 0);
png.set([0x49, 0x48, 0x44, 0x52], 12);
new DataView(png.buffer).setUint32(16, 512);
new DataView(png.buffer).setUint32(20, 512);
png.set([0x49, 0x45, 0x4e, 0x44], png.length - 8);

function packageFiles(overrides = {}) {
  return {
    "demo-expert/.codebuddy-plugin/plugin.json": strToU8(JSON.stringify(manifest)),
    "demo-expert/agents/demo-expert.md": strToU8(agent),
    "demo-expert/avatars/expert.png": png,
    ...overrides,
  };
}

test("reads a valid WorkBuddy 2.4 expert package", () => {
  const result = inspectExpertZip(zipSync(packageFiles()));
  assert.equal(result.manifest.name, "demo-expert");
  assert.equal(result.manifestPath, "demo-expert/.codebuddy-plugin/plugin.json");
});

test("rejects duplicate manifests", () => {
  const zip = zipSync(packageFiles({ "demo-expert/other/.codebuddy-plugin/plugin.json": strToU8(JSON.stringify(manifest)) }));
  assert.throws(() => inspectExpertZip(zip), /只能包含一个/);
});

test("rejects tools in Agent frontmatter", () => {
  const invalid = agent.replace("profession:", "tools: [Bash]\nprofession:");
  const zip = zipSync(packageFiles({ "demo-expert/agents/demo-expert.md": strToU8(invalid) }));
  assert.throws(() => inspectExpertZip(zip), /不可声明 tools/);
});
