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
	const auth = "TEST-AUTH-VALUE"
	got := npmWorkbuddyRcContent(previous, auth)
	want := "always-auth=true\r\n" +
		helperNpmAuthKey + "=" + auth + "\r\n" +
		"registry=https://npm.example.com/\r\n" +
		"//other.registry/:_authToken=keepme\r\n" +
		"# a comment"
	if got != want {
		t.Fatalf("rc 内容不符。\n得到：%q\n期望：%q", got, want)
	}
	if empty := npmWorkbuddyRcContent(nil, auth); !strings.HasSuffix(empty, "\r\n") {
		t.Fatalf("无既有配置时 rc 应以 CRLF 结尾：%q", empty)
	}
}

// 加密存储的凭据必须能正确解密回读。契约（v0.9.3 起）：解出值是 npm `_auth=` 后
// 可直接使用的 base64 形态（不含冒号，仅 base64 字符集）；测试不断言明文——
// 明文不允许出现在仓库任何位置。真实有效性由发布前 nexus 实测保证。
func TestHelperNpmAuthDecrypts(t *testing.T) {
	v1, err := helperNpmAuth()
	if err != nil {
		t.Fatalf("解密失败：%v", err)
	}
	if len(v1) < 16 || strings.Contains(v1, ":") {
		t.Fatalf("解密结果形态不符（应为 base64 凭据串，不得含冒号明文）：长度 %d", len(v1))
	}
	v2, err := helperNpmAuth()
	if err != nil || v2 != v1 {
		t.Fatalf("重复解密结果不稳定：%q vs %q (%v)", v2, v1, err)
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
