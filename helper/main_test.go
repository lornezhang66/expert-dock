package main

import (
	"testing"
	"time"
)

func TestSafeZipPath(t *testing.T) {
	for _, path := range []string{"expert/agents/main.md", ".codebuddy-plugin/plugin.json"} {
		if _, err := safeZipPath(path); err != nil {
			t.Fatalf("safe path rejected: %s: %v", path, err)
		}
	}
	for _, path := range []string{"../outside", "/absolute", `C:\outside`} {
		if _, err := safeZipPath(path); err == nil {
			t.Fatalf("unsafe path accepted: %s", path)
		}
	}
}

func TestValidName(t *testing.T) {
	for _, name := range []string{"demo-expert", "expert2"} {
		if !validName(name) {
			t.Fatalf("valid name rejected: %s", name)
		}
	}
	for _, name := range []string{"A-bad", "-bad", "bad-", "../bad"} {
		if validName(name) {
			t.Fatalf("invalid name accepted: %s", name)
		}
	}
}

func TestInstallLockWaitsForCurrentInstall(t *testing.T) {
	root := t.TempDir()
	release, err := acquireInstallLock(root)
	if err != nil {
		t.Fatal(err)
	}

	go func() {
		time.Sleep(50 * time.Millisecond)
		release()
	}()
	secondRelease, err := acquireInstallLock(root)
	if err != nil {
		t.Fatal(err)
	}
	secondRelease()
}
