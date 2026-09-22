package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func writeTestJSON(t *testing.T, path string, value any) {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
}

func testPlugin(t *testing.T, root string, meta metadata) string {
	t.Helper()
	source := filepath.Join(root, "plugins", "marketplaces", "my-experts", "plugins", meta.Name)
	writeTestJSON(t, filepath.Join(source, ".codebuddy-plugin", "plugin.json"), map[string]any{
		"name": meta.Name, "version": meta.Version, "expertType": "agent",
	})
	if err := os.MkdirAll(filepath.Join(source, "agents"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(source, "agents", "main.md"), []byte("test"), 0o600); err != nil {
		t.Fatal(err)
	}
	return source
}

func TestRegisterLocalPluginAndHealthCheck(t *testing.T) {
	root := t.TempDir()
	meta := metadata{Name: "demo-expert", Version: "1.0.0"}
	source := testPlugin(t, root, meta)
	writeTestJSON(t, filepath.Join(root, "settings.json"), map[string]any{"theme": "dark", "enabledPlugins": map[string]any{"other@market": true}})
	writeTestJSON(t, filepath.Join(root, "plugins", "installed_plugins.json"), map[string]any{"version": 2, "plugins": map[string]any{"other@market": []any{map[string]any{"scope": "user"}}}})
	writeTestJSON(t, filepath.Join(root, "plugins", "marketplaces", "my-experts", ".codebuddy-plugin", "marketplace.json"), map[string]any{
		"name": "my-experts", "plugins": []any{map[string]any{"name": "other", "source": "./plugins/other"}},
	})

	if err := registerLocalPlugin(root, source, meta); err != nil {
		t.Fatal(err)
	}
	if !installationHealthy(root, source, meta) {
		t.Fatal("installed plugin did not pass health check")
	}
	settings, err := readJSONObject(filepath.Join(root, "settings.json"))
	if err != nil {
		t.Fatal(err)
	}
	if settings["theme"] != "dark" {
		t.Fatal("existing settings were not preserved")
	}
	enabled := settings["enabledPlugins"].(map[string]any)
	if enabled["other@market"] != true || enabled["demo-expert@my-experts"] != true {
		t.Fatal("enabled plugin entries are incomplete")
	}
}

func TestRegistrationRollsBackOnInvalidSettings(t *testing.T) {
	root := t.TempDir()
	meta := metadata{Name: "demo-expert", Version: "1.0.0"}
	source := testPlugin(t, root, meta)
	settingsPath := filepath.Join(root, "settings.json")
	if err := os.WriteFile(settingsPath, []byte("not json"), 0o600); err != nil {
		t.Fatal(err)
	}
	marketplacePath := filepath.Join(root, "plugins", "marketplaces", "my-experts", ".codebuddy-plugin", "marketplace.json")
	original := []byte(`{"name":"my-experts","plugins":[]}`)
	if err := os.MkdirAll(filepath.Dir(marketplacePath), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(marketplacePath, original, 0o600); err != nil {
		t.Fatal(err)
	}

	if err := registerLocalPlugin(root, source, meta); err == nil {
		t.Fatal("expected invalid settings to fail registration")
	}
	after, err := os.ReadFile(marketplacePath)
	if err != nil {
		t.Fatal(err)
	}
	if string(after) != string(original) {
		t.Fatal("marketplace file was not rolled back")
	}
	cache := filepath.Join(root, "plugins", "cache", "my-experts", meta.Name, meta.Version)
	if exists(cache) {
		t.Fatal("cache was not rolled back")
	}
	settings, _ := os.ReadFile(settingsPath)
	if string(settings) != "not json" {
		t.Fatal("invalid settings were overwritten")
	}
}

func TestRegistrationEarlyFailurePreservesExistingCache(t *testing.T) {
	root := t.TempDir()
	meta := metadata{Name: "demo-expert", Version: "1.0.0"}
	source := testPlugin(t, root, meta)
	marketplacePath := filepath.Join(root, "plugins", "marketplaces", "my-experts", ".codebuddy-plugin", "marketplace.json")
	writeTestJSON(t, marketplacePath, map[string]any{"name": "my-experts", "plugins": "invalid"})
	cacheFile := filepath.Join(root, "plugins", "cache", "my-experts", meta.Name, meta.Version, "keep.txt")
	if err := os.MkdirAll(filepath.Dir(cacheFile), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cacheFile, []byte("old cache"), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := registerLocalPlugin(root, source, meta); err == nil {
		t.Fatal("expected invalid marketplace to fail registration")
	}
	data, err := os.ReadFile(cacheFile)
	if err != nil || string(data) != "old cache" {
		t.Fatal("existing cache was damaged by an early failure")
	}
}

func TestVersionGreater(t *testing.T) {
	cases := []struct {
		candidate string
		current   string
		want      bool
	}{
		{"0.2.0", "0.1.1", true},
		{"0.2.0", "0.2.0", false},
		{"1.0.0", "0.99.9", true},
		{"0.1.9", "0.2.0", false},
	}
	for _, test := range cases {
		if got := versionGreater(test.candidate, test.current); got != test.want {
			t.Fatalf("versionGreater(%q, %q)=%v", test.candidate, test.current, got)
		}
	}
}
