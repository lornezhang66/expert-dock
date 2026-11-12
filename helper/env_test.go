package main

import (
	"os"
	"strings"
	"testing"
)

func TestNpmWorkbuddyRcContent(t *testing.T) {
	previous := []string{
		"registry=https://npm.example.com/",
		"//nvwa.jiuqi.com.cn/nexus/repository/npm-gov-group/:_auth=OLDVALUE",
		"  always-auth=false",
		"//other.registry/:_authToken=keepme",
		"# a comment",
	}
	got := npmWorkbuddyRcContent(previous)
	want := "always-auth=true\r\n" +
		helperNpmAuthKey + "=" + helperNpmAuthValue + "\r\n" +
		"registry=https://npm.example.com/\r\n" +
		"//other.registry/:_authToken=keepme\r\n" +
		"# a comment"
	if got != want {
		t.Fatalf("rc 内容不符。\n得到：%q\n期望：%q", got, want)
	}
	if empty := npmWorkbuddyRcContent(nil); !strings.HasSuffix(empty, "\r\n") {
		t.Fatalf("无既有配置时 rc 应以 CRLF 结尾：%q", empty)
	}
}

func TestAddUserPathEntry(t *testing.T) {
	// 分隔符随平台；目录是单个 PATH 条目，本身不含分隔符
	sep := string(os.PathListSeparator)
	dir := "nodedir"
	if got := addUserPathEntry("", dir); got != dir {
		t.Fatalf("空当前值应直接返回目录：%q", got)
	}
	if got := addUserPathEntry("a"+sep+dir+sep, dir); got != "a"+sep+dir+sep {
		t.Fatalf("已存在条目应原样返回：%q", got)
	}
	if got := addUserPathEntry("a"+sep+"b", dir); got != dir+sep+"a"+sep+"b" {
		t.Fatalf("新目录应前置：%q", got)
	}
}

func TestNodeMajorOK(t *testing.T) {
	cases := []struct {
		output string
		want   bool
	}{
		{"v22.22.2", true},
		{"v20.0.0", true},
		{"v20.11.1\n", true},
		{"v19.9.9", false},
		{"v18.0.0", false},
		{"garbage", false},
		{"", false},
		{"v20", false}, // 蓝本正则要求主版本号后带点
	}
	for _, c := range cases {
		if got := nodeMajorOK(c.output, helperNodeMinimum); got != c.want {
			t.Errorf("nodeMajorOK(%q)=%v，期望 %v", c.output, got, c.want)
		}
	}
}
