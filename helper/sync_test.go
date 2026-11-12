package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// ---- 测试脚手架 ----

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

// 建 marketplace/<market>/plugins/<plugin>/ 结构并写入声明文件
func makePlugin(t *testing.T, root, market, plugin string, files map[string]string) string {
	t.Helper()
	dir := filepath.Join(root, market, "plugins", plugin)
	for name, content := range files {
		writeFile(t, filepath.Join(dir, name), content)
	}
	return dir
}

func readMcpJson(t *testing.T, path string) map[string]any {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var cfg map[string]any
	if err := json.Unmarshal(stripUtf8Bom(raw), &cfg); err != nil {
		t.Fatalf("写回产物不是合法 JSON：%v", err)
	}
	return cfg
}

func serverOf(t *testing.T, cfg map[string]any, name string) map[string]any {
	t.Helper()
	servers, _ := cfg["mcpServers"].(map[string]any)
	entry, _ := servers[name].(map[string]any)
	if entry == nil {
		t.Fatalf("条目 %s 不存在或不是对象", name)
	}
	return entry
}

// ---- 用例 ----

// 硬约束 2：执行命令整段按包声明覆盖，@latest 原样照搬；未配置的键绝不代写
func TestSyncUpdatesExistingVerbatimSkipsUnconfigured(t *testing.T) {
	dir := t.TempDir()
	mcpJson := filepath.Join(dir, "mcp.json")
	writeFile(t, mcpJson, `{"mcpServers":{
		"gbc":{"type":"stdio","command":"node","args":["old.js"],"env":{"GBC_TOKEN":"real"}},
		"other":{"type":"stdio","command":"keep-me","args":["a"]}
	}}`)
	root := filepath.Join(dir, "marketplaces")
	makePlugin(t, root, "gov", "gbc-plugin", map[string]string{
		".mcp.json": `{"mcpServers":{
			"gbc":{"type":"stdio","command":"npx","args":["-y","jiuqi-gbc-mcp@latest"]},
			"fresh":{"type":"stdio","command":"npx","args":["-y","never-installed"]}
		}}`,
	})
	result, err := syncExpertMcpDependencies(root, mcpJson)
	if err != nil {
		t.Fatal(err)
	}
	if result.Updated != 1 || result.Skipped != 1 || result.Scanned != 2 {
		t.Fatalf("计数不符：%+v", result)
	}
	cfg := readMcpJson(t, mcpJson)
	gbc := serverOf(t, cfg, "gbc")
	if gbc["command"] != "npx" {
		t.Fatalf("command 未按包声明覆盖：%v", gbc["command"])
	}
	if !reflect.DeepEqual(gbc["args"], []any{"-y", "jiuqi-gbc-mcp@latest"}) {
		t.Fatalf("args 未按包声明照搬（@latest 必须原样）：%v", gbc["args"])
	}
	// 声明无 env → env 落空对象（对齐蓝本 mergedEnv 空对象行为）
	if !reflect.DeepEqual(gbc["env"], map[string]any{}) {
		t.Fatalf("env 应为空对象：%v", gbc["env"])
	}
	// other 未在声明中：原样保留
	if serverOf(t, cfg, "other")["command"] != "keep-me" {
		t.Fatal("无关条目被改动")
	}
	// fresh 未配置：绝不代写
	if cfg["mcpServers"].(map[string]any)["fresh"] != nil {
		t.Fatal("代写了未配置条目")
	}
}

// 硬约束 3：占位符沿用已配值；无已配值整键省略；字面值以包为准；声明外的既有 env 键丢失（对齐蓝本）
func TestSyncEnvMergeRules(t *testing.T) {
	dir := t.TempDir()
	mcpJson := filepath.Join(dir, "mcp.json")
	writeFile(t, mcpJson, `{"mcpServers":{"gbc":{"command":"node","env":{
		"GBC_TOKEN":"real-token","GBC_URL":"https://old.example","EXTRA":"will-be-dropped"
	}}}}`)
	root := filepath.Join(dir, "marketplaces")
	makePlugin(t, root, "gov", "p", map[string]string{
		".mcp.json": `{"mcpServers":{"gbc":{"command":"node","env":{
			"GBC_TOKEN":"${GBC_TOKEN}","GBC_URL":"${GBC_URL}","NEVER_SET":"${NEVER_SET}","LITERAL":"pkg-value"
		}}}}`,
	})
	if _, err := syncExpertMcpDependencies(root, mcpJson); err != nil {
		t.Fatal(err)
	}
	env := serverOf(t, readMcpJson(t, mcpJson), "gbc")["env"].(map[string]any)
	if env["GBC_TOKEN"] != "real-token" {
		t.Fatalf("已配占位符值被覆盖：%v", env["GBC_TOKEN"])
	}
	if env["GBC_URL"] != "https://old.example" {
		t.Fatalf("已配占位符值被覆盖：%v", env["GBC_URL"])
	}
	if v, present := env["NEVER_SET"]; present {
		t.Fatalf("无已配值的占位符必须整键省略，不得写字面量：%v", v)
	}
	if env["LITERAL"] != "pkg-value" {
		t.Fatalf("字面值应以包为准：%v", env["LITERAL"])
	}
	if _, present := env["EXTRA"]; present {
		t.Fatal("声明外的既有 env 键应随 env 整体重建而移除（对齐蓝本语义）")
	}
}

// 硬约束 1 + 4：headers 与自定义键原样保留
func TestSyncPreservesUnknownKeys(t *testing.T) {
	dir := t.TempDir()
	mcpJson := filepath.Join(dir, "mcp.json")
	writeFile(t, mcpJson, `{"mcpServers":{"gbc":{"command":"node","headers":{"Authorization":"Bearer pat"},"note":"custom"}}}`)
	root := filepath.Join(dir, "marketplaces")
	makePlugin(t, root, "gov", "p", map[string]string{
		".mcp.json": `{"mcpServers":{"gbc":{"command":"npx","args":["-y","pkg"]}}}`,
	})
	if _, err := syncExpertMcpDependencies(root, mcpJson); err != nil {
		t.Fatal(err)
	}
	entry := serverOf(t, readMcpJson(t, mcpJson), "gbc")
	if !reflect.DeepEqual(entry["headers"], map[string]any{"Authorization": "Bearer pat"}) {
		t.Fatalf("headers 被破坏：%v", entry["headers"])
	}
	if entry["note"] != "custom" {
		t.Fatalf("自定义键被破坏：%v", entry["note"])
	}
}

// 硬约束 5：坏 JSON 原样保留（逐字节一致）
func TestSyncBadJsonUntouched(t *testing.T) {
	dir := t.TempDir()
	mcpJson := filepath.Join(dir, "mcp.json")
	bad := `{"mcpServers":{ broken`
	writeFile(t, mcpJson, bad)
	root := filepath.Join(dir, "marketplaces")
	makePlugin(t, root, "gov", "p", map[string]string{".mcp.json": `{"mcpServers":{"gbc":{"command":"npx"}}}`})
	result, err := syncExpertMcpDependencies(root, mcpJson)
	if err == nil {
		t.Fatal("坏 JSON 必须报错而不是静默跳过")
	}
	if result.Updated != 0 {
		t.Fatal("坏 JSON 情况下不得计数更新")
	}
	got, _ := os.ReadFile(mcpJson)
	if string(got) != bad {
		t.Fatalf("坏 JSON 文件被改动：%q", string(got))
	}
}

// mcp.json 缺失：零操作、不建文件
func TestSyncMissingMcpJsonNoop(t *testing.T) {
	dir := t.TempDir()
	mcpJson := filepath.Join(dir, "mcp.json")
	root := filepath.Join(dir, "marketplaces")
	makePlugin(t, root, "gov", "p", map[string]string{".mcp.json": `{"mcpServers":{"gbc":{"command":"npx"}}}`})
	result, err := syncExpertMcpDependencies(root, mcpJson)
	if err != nil {
		t.Fatal(err)
	}
	if result.Updated+result.Skipped+result.Scanned != 0 {
		t.Fatalf("缺失 mcp.json 必须零操作：%+v", result)
	}
	if _, err := os.Stat(mcpJson); !os.IsNotExist(err) {
		t.Fatal("不得代建 mcp.json")
	}
}

// BOM 剥离：带 BOM 可解析；更新写回后无 BOM
func TestSyncBomHandled(t *testing.T) {
	dir := t.TempDir()
	mcpJson := filepath.Join(dir, "mcp.json")
	writeFile(t, mcpJson, "\xEF\xBB\xBF"+`{"mcpServers":{"gbc":{"command":"node"}}}`)
	root := filepath.Join(dir, "marketplaces")
	makePlugin(t, root, "gov", "p", map[string]string{
		".mcp.json": `{"mcpServers":{"gbc":{"command":"npx","args":["-y","pkg"]}}}`,
	})
	if _, err := syncExpertMcpDependencies(root, mcpJson); err != nil {
		t.Fatal(err)
	}
	raw, _ := os.ReadFile(mcpJson)
	if strings.HasPrefix(string(raw), "\xEF\xBB\xBF") {
		t.Fatal("写回产物带 BOM（WorkBuddy 严格 JSON 解析会整体失败）")
	}
	if serverOf(t, readMcpJson(t, mcpJson), "gbc")["command"] != "npx" {
		t.Fatal("带 BOM 输入未参与同步")
	}
}

// 无变更不写回（文件逐字节一致）
func TestSyncNoChangeNoWrite(t *testing.T) {
	dir := t.TempDir()
	mcpJson := filepath.Join(dir, "mcp.json")
	// 既有条目必须是同步后的完整形态（蓝本会无条件注入 type 与 env:{}）——
	// 若既有条目缺这些键，同步本身就会视为变更（与蓝本行为一致）
	content := "{\"mcpServers\":{\"gbc\":{\"type\":\"stdio\",\"command\":\"npx\",\"args\":[\"-y\",\"pkg\"],\"env\":{}}}}\n"
	writeFile(t, mcpJson, content)
	root := filepath.Join(dir, "marketplaces")
	makePlugin(t, root, "gov", "p", map[string]string{
		".mcp.json": `{"mcpServers":{"gbc":{"type":"stdio","command":"npx","args":["-y","pkg"]}}}`,
	})
	result, err := syncExpertMcpDependencies(root, mcpJson)
	if err != nil {
		t.Fatal(err)
	}
	if result.Updated != 0 {
		t.Fatalf("相同内容不应计更新：%+v", result)
	}
	got, _ := os.ReadFile(mcpJson)
	if string(got) != content {
		t.Fatal("无变更时文件被重写")
	}
}

// runtime：声明了才动
func TestSyncRuntimeOnlyWhenDeclared(t *testing.T) {
	dir := t.TempDir()
	mcpJson := filepath.Join(dir, "mcp.json")
	writeFile(t, mcpJson, `{"mcpServers":{"a":{"command":"node","runtime":"node20"},"b":{"command":"node","runtime":"node20"}}}`)
	root := filepath.Join(dir, "marketplaces")
	makePlugin(t, root, "gov", "p", map[string]string{
		".mcp.json": `{"mcpServers":{
			"a":{"command":"npx","args":[],"runtime":"node22"},
			"b":{"command":"npx","args":[]}
		}}`,
	})
	if _, err := syncExpertMcpDependencies(root, mcpJson); err != nil {
		t.Fatal(err)
	}
	cfg := readMcpJson(t, mcpJson)
	if serverOf(t, cfg, "a")["runtime"] != "node22" {
		t.Fatal("声明的 runtime 未覆盖")
	}
	if serverOf(t, cfg, "b")["runtime"] != "node20" {
		t.Fatal("未声明 runtime 被误动")
	}
}

// 声明形态：plugin.json 字符串引用（剥 ./）与裸对象顶层
func TestSyncDeclarationForms(t *testing.T) {
	dir := t.TempDir()
	mcpJson := filepath.Join(dir, "mcp.json")
	writeFile(t, mcpJson, `{"mcpServers":{"fromRef":{"command":"old"},"fromBare":{"command":"old"}}}`)
	root := filepath.Join(dir, "marketplaces")
	makePlugin(t, root, "gov", "ref-plugin", map[string]string{
		".codebuddy-plugin/plugin.json": `{"name":"ref-plugin","dependencies":{"mcpServers":"./mcp-dep.json"}}`,
		"mcp-dep.json":                  `{"mcpServers":{"fromRef":{"command":"ref-cmd"}}}`,
	})
	makePlugin(t, root, "gov", "bare-plugin", map[string]string{
		".mcp.json": `{"fromBare":{"command":"bare-cmd"}}`,
	})
	if _, err := syncExpertMcpDependencies(root, mcpJson); err != nil {
		t.Fatal(err)
	}
	cfg := readMcpJson(t, mcpJson)
	if serverOf(t, cfg, "fromRef")["command"] != "ref-cmd" {
		t.Fatal("plugin.json 字符串引用未解析")
	}
	if serverOf(t, cfg, "fromBare")["command"] != "bare-cmd" {
		t.Fatal("裸对象声明未识别")
	}
}

// args 强制转换：缺失落空数组（不是 null）；标量包单元素
func TestSyncArgsCoercion(t *testing.T) {
	dir := t.TempDir()
	mcpJson := filepath.Join(dir, "mcp.json")
	writeFile(t, mcpJson, `{"mcpServers":{"a":{"command":"node","args":["x"]},"b":{"command":"node","args":["x"]}}}`)
	root := filepath.Join(dir, "marketplaces")
	makePlugin(t, root, "gov", "p", map[string]string{
		".mcp.json": `{"mcpServers":{"a":{"command":"npx"},"b":{"command":"npx","args":"single"}}}`,
	})
	if _, err := syncExpertMcpDependencies(root, mcpJson); err != nil {
		t.Fatal(err)
	}
	cfg := readMcpJson(t, mcpJson)
	if !reflect.DeepEqual(serverOf(t, cfg, "a")["args"], []any{}) {
		t.Fatalf("缺失 args 应落空数组：%v", serverOf(t, cfg, "a")["args"])
	}
	if !reflect.DeepEqual(serverOf(t, cfg, "b")["args"], []any{"single"}) {
		t.Fatalf("标量 args 应包成单元素数组：%v", serverOf(t, cfg, "b")["args"])
	}
}

// 既有条目损坏（非对象）：跳过不碰，绝不让整个同步崩溃
func TestSyncCorruptedEntrySkipped(t *testing.T) {
	dir := t.TempDir()
	mcpJson := filepath.Join(dir, "mcp.json")
	content := `{"mcpServers":{"broken":"not-an-object"}}`
	writeFile(t, mcpJson, content)
	root := filepath.Join(dir, "marketplaces")
	makePlugin(t, root, "gov", "p", map[string]string{
		".mcp.json": `{"mcpServers":{"broken":{"command":"npx"}}}`,
	})
	result, err := syncExpertMcpDependencies(root, mcpJson)
	if err != nil {
		t.Fatal(err)
	}
	if result.Skipped != 1 {
		t.Fatalf("损坏条目应计跳过：%+v", result)
	}
	got, _ := os.ReadFile(mcpJson)
	if string(got) != content {
		t.Fatal("损坏条目被改动")
	}
}

// 市场/插件目录缺失：无事可做
func TestSyncEmptyMarketplaces(t *testing.T) {
	dir := t.TempDir()
	mcpJson := filepath.Join(dir, "mcp.json")
	writeFile(t, mcpJson, `{"mcpServers":{"gbc":{"command":"node"}}}`)
	result, err := syncExpertMcpDependencies(filepath.Join(dir, "nope"), mcpJson)
	if err != nil {
		t.Fatal(err)
	}
	if result.Updated != 0 {
		t.Fatalf("无市场不应有更新：%+v", result)
	}
}
