package main

// GMSCP-7877：专家包 MCP 声明 → 用户级 ~/.workbuddy/mcp.json 合并刷新。
// 语义与 docs/legacy-windows-helper/helper-ui.ps1 的 Sync-ExpertMcpDependencies 逐条对齐：
//  1. 只更新已存在条目；未配置过的键绝不代写（首装条目归 WorkBuddy 连接卡引导）
//  2. 执行命令（type/command/args，以及声明了才动的 runtime）整段按包声明覆盖——
//     包是版本决策的唯一事实源，@latest 与固定版本均照搬，不做 dist-tag 解析
//  3. env 合并：${PLACEHOLDER} 沿用已配值，无已配值整个键省略（宁缺勿错）；字面值以包为准
//  4. headers 等自定义键原样保留（只触碰 type/command/args/runtime/env 五个键）
//  5. 用户级 mcp.json 解析失败 → 不动文件交人工；写回一律 UTF-8 无 BOM
//     （WorkBuddy 严格 JSON 解析遇 BOM 整体失败——helper 时代实测教训）
//
// 键序说明：写回走 encoding/json（map 按键排序输出）。键序对消费方（WorkBuddy 严格 JSON
// 解析）无语义，且写回只在确有更新时发生；不为外观上的 diff 安静引入有序 JSON 结构。
// 与蓝本的一处已知差异：既有条目存在但不是 JSON 对象时，蓝本会对 null 调方法直接崩溃；
// 这里按"条目损坏"处理——跳过并记日志，绝不动它。

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

type mcpSyncResult struct {
	Updated int `json:"updated"`
	Skipped int `json:"skipped"`
	Scanned int `json:"scanned"`
}

// 与蓝本正则一致：整串占位符形态（${KEY}），不匹配前缀/后缀拼接
var envPlaceholderRe = regexp.MustCompile(`^\$\{[A-Za-z_][A-Za-z0-9_]*\}$`)

func workBuddyPaths() (marketplacesRoot, mcpJsonPath string) {
	home, err := os.UserHomeDir()
	if err != nil {
		home = "."
	}
	return filepath.Join(home, ".workbuddy", "plugins", "marketplaces"),
		filepath.Join(home, ".workbuddy", "mcp.json")
}

// install 成功后与常驻启动时各调一次（对齐蓝本触发时机）；失败只记日志，不影响安装结果
func syncWorkBuddyMcp() mcpSyncResult {
	root, mcpJson := workBuddyPaths()
	result, err := syncExpertMcpDependencies(root, mcpJson)
	if err != nil {
		helperLog("ERROR", "MCP同步", "同步中止："+err.Error())
		return result
	}
	helperLog("INFO", "MCP同步", fmt.Sprintf("MCP 同步完成：更新 %d / 跳过 %d / 扫描 %d",
		result.Updated, result.Skipped, result.Scanned))
	return result
}

func syncExpertMcpDependencies(marketplacesRoot, mcpJsonPath string) (mcpSyncResult, error) {
	var result mcpSyncResult
	if !exists(mcpJsonPath) {
		helperLog("INFO", "MCP同步", "用户级 mcp.json 不存在（尚未配置过任何 MCP），跳过——首装由 WorkBuddy 连接引导完成")
		return result, nil
	}
	raw, err := os.ReadFile(mcpJsonPath)
	if err != nil {
		return result, err
	}
	var cfg map[string]any
	if err := json.Unmarshal(stripUtf8Bom(raw), &cfg); err != nil {
		// 硬约束：坏 JSON 原样保留，绝不写回
		return result, fmt.Errorf("用户级 mcp.json 解析失败，文件未改动（请人工检查）：%w", err)
	}
	servers, _ := cfg["mcpServers"].(map[string]any)
	if len(servers) == 0 {
		return result, nil
	}
	marketNames, err := sortedSubDirs(marketplacesRoot)
	if err != nil {
		return result, nil // 市场根不存在/不可读：无事可同步
	}
	for _, market := range marketNames {
		pluginsDir := filepath.Join(marketplacesRoot, market, "plugins")
		pluginNames, err := sortedSubDirs(pluginsDir)
		if err != nil {
			continue // 无 plugins 目录的市场直接跳过（市场更新不经过 Helper）
		}
		for _, plugin := range pluginNames {
			declServers := pluginMcpDeclaration(filepath.Join(pluginsDir, plugin))
			for _, name := range sortedKeys(declServers) {
				result.Scanned++
				syncServerEntry(name, declServers[name], servers, &result)
			}
		}
	}
	if result.Updated > 0 {
		var buf bytes.Buffer
		enc := json.NewEncoder(&buf)
		enc.SetEscapeHTML(false)
		enc.SetIndent("", "  ")
		if err := enc.Encode(cfg); err != nil {
			return result, err
		}
		if err := writeFileAtomic(mcpJsonPath, buf.Bytes(), 0o600); err != nil {
			return result, fmt.Errorf("写回失败：%w", err)
		}
		helperLog("INFO", "MCP同步", fmt.Sprintf("写回 %s（更新 %d 个条目，无 BOM）", mcpJsonPath, result.Updated))
	} else {
		helperLog("INFO", "MCP同步", "无变更，不写回")
	}
	return result, nil
}

// 读取一个专家包的 MCP 声明，返回 serverName → server 对象。
// 声明位置：包根 .mcp.json，或 plugin.json dependencies.mcpServers 指向的相对路径（剥 "./"）。
// 与蓝本保持一致：dependencies.mcpServers 内联对象形态不受理（蓝本注释提及但代码未实现）。
func pluginMcpDeclaration(pluginDir string) map[string]any {
	declPath := filepath.Join(pluginDir, ".mcp.json")
	if !exists(declPath) {
		pluginJsonPath := filepath.Join(pluginDir, ".codebuddy-plugin", "plugin.json")
		if raw, err := os.ReadFile(pluginJsonPath); err == nil {
			var pj map[string]any
			if err := json.Unmarshal(stripUtf8Bom(raw), &pj); err != nil {
				helperLog("WARN", "MCP同步", fmt.Sprintf("plugin.json 解析失败，跳过 %s：%v", pluginDir, err))
				return nil
			}
			deps, _ := pj["dependencies"].(map[string]any)
			if ref, _ := deps["mcpServers"].(string); ref != "" {
				candidate := filepath.Join(pluginDir, strings.TrimPrefix(ref, "./"))
				if exists(candidate) {
					declPath = candidate
				}
			}
		}
	}
	if !exists(declPath) {
		return nil
	}
	raw, err := os.ReadFile(declPath)
	if err != nil {
		return nil
	}
	var decl map[string]any
	if err := json.Unmarshal(stripUtf8Bom(raw), &decl); err != nil {
		helperLog("WARN", "MCP同步", fmt.Sprintf("声明文件解析失败，跳过 %s：%v", declPath, err))
		return nil
	}
	if servers, ok := decl["mcpServers"].(map[string]any); ok && len(servers) > 0 {
		return servers
	}
	return decl // 裸对象形态：顶层即 server 映射
}

func syncServerEntry(name string, declServer any, servers map[string]any, result *mcpSyncResult) {
	decl, ok := declServer.(map[string]any)
	if !ok {
		return // 声明条目不是对象（脏数据），不碰
	}
	existing, ok := servers[name].(map[string]any)
	if !ok {
		// 无既有条目（或既有条目损坏）：首装由 WorkBuddy 连接引导，绝不代写
		result.Skipped++
		helperLog("INFO", "MCP同步", name+"：用户尚未配置过（无既有条目），首装由 WorkBuddy 连接引导完成，不代写")
		return
	}
	before, _ := json.Marshal(existing)

	// 执行命令整段以包声明为准，直接覆盖；args 与蓝本一致：未声明时落空数组
	existing["type"] = jsonString(decl["type"])
	existing["command"] = jsonString(decl["command"])
	existing["args"] = jsonStringArray(decl["args"])
	if rt := jsonString(decl["runtime"]); rt != "" {
		existing["runtime"] = rt
	}

	// env 合并：占位符沿用已配值，字面值以包为准
	merged := map[string]any{}
	existingEnv, _ := existing["env"].(map[string]any)
	declEnv, _ := decl["env"].(map[string]any)
	preserved, omitted := []string{}, 0
	for _, key := range sortedKeys(declEnv) {
		value := jsonString(declEnv[key])
		if envPlaceholderRe.MatchString(value) {
			if old := jsonString(existingEnv[key]); old != "" {
				merged[key] = old
				preserved = append(preserved, key)
			} else {
				// 占位符且无已配值：宁缺勿错——写死 "${KEY}" 字面量会被当环境变量原样传入
				omitted++
				helperLog("WARN", "MCP同步", name+"："+key+" 无已配值，本次省略（请在 WorkBuddy 连接卡补配）")
			}
		} else {
			merged[key] = value
		}
	}
	existing["env"] = merged

	after, _ := json.Marshal(existing)
	if !bytes.Equal(before, after) {
		result.Updated++
		keep := "-"
		if len(preserved) > 0 {
			keep = strings.Join(preserved, "/")
		}
		helperLog("INFO", "MCP同步", fmt.Sprintf("%s：已按包声明刷新（沿用已配值：%s；%d 个键待补配）", name, keep, omitted))
	}
}

func stripUtf8Bom(data []byte) []byte {
	if len(data) >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF {
		return data[3:]
	}
	return data
}

// jsonString 对应蓝本 [string]$x 的宽松转换；数字按 JSON 数值最小化输出
func jsonString(value any) string {
	switch v := value.(type) {
	case nil:
		return ""
	case string:
		return v
	case bool:
		return strconv.FormatBool(v)
	case float64:
		return strconv.FormatFloat(v, 'f', -1, 64)
	default:
		return fmt.Sprintf("%v", v)
	}
}

// jsonStringArray 对应蓝本 @($declServer.args | ForEach { [string]$_ })：
// 数组逐项转字符串；标量包成单元素；缺失/空一律返回非 nil 空数组（nil 会被序列化成 null）
func jsonStringArray(value any) []string {
	switch v := value.(type) {
	case []any:
		out := make([]string, 0, len(v))
		for _, item := range v {
			out = append(out, jsonString(item))
		}
		return out
	case string:
		return []string{v}
	default:
		if v == nil {
			return []string{}
		}
		return []string{fmt.Sprintf("%v", v)}
	}
}

func sortedKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for key := range m {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func sortedSubDirs(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() {
			names = append(names, entry.Name())
		}
	}
	sort.Strings(names)
	return names, nil
}

// 阶段 1 走 stdout；阶段 2 Windows 壳接入统一日志汇（对齐蓝本 %APPDATA%/ExpertDock/logs）
func helperLog(level, area, message string) {
	fmt.Printf("%s [ExpertDock][%s][%s] %s\n", time.Now().Format("2006-01-02 15:04:05"), area, level, message)
}
