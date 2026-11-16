// gencred 生成内网 nexus 凭据的加密存储材料（轮换凭据时本地运行，产物手工粘贴进代码）。
//
// 用法：
//
//	go run ./cmd/gencred -value 'base64(user:password)'
//
// -value 接收 npm _auth= 后可直接使用的值（即 base64(user:password)），不要传明文。
// 密钥 = SHA-256(part1 + part2)，两端拼接后派生，任意一半单独出现不构成可用密钥。
// 说明：这是混淆层（防扫描器/strings），不是密码学边界——密钥随二进制分发，防不了逆向。
package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"flag"
	"fmt"
	"os"
)

func main() {
	value := flag.String("value", "", "凭据明文（user:password 或原始 token）")
	flag.Parse()
	if *value == "" {
		fmt.Fprintln(os.Stderr, "缺少 -value")
		os.Exit(1)
	}

	part1 := make([]byte, 16)
	part2 := make([]byte, 16)
	nonce := make([]byte, 12)
	if _, err := rand.Read(part1); err != nil {
		panic(err)
	}
	if _, err := rand.Read(part2); err != nil {
		panic(err)
	}
	if _, err := rand.Read(nonce); err != nil {
		panic(err)
	}

	key := sha256.Sum256(append(append([]byte{}, part1...), part2...))
	block, err := aes.NewCipher(key[:])
	if err != nil {
		panic(err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		panic(err)
	}
	ct := gcm.Seal(nonce, nonce, []byte(*value), nil) // nonce 前置拼进密文

	fmt.Printf("// env.go 内粘贴：\n\tnpmAuthCipherB64 = %q\n\tnpmAuthKeyPart1  = %q\n\n",
		base64.StdEncoding.EncodeToString(ct), hex.EncodeToString(part1))
	fmt.Printf("// sync.go 内粘贴：\nconst npmAuthKeyPart2 = %q\n", hex.EncodeToString(part2))
	fmt.Fprintf(os.Stderr, "\n[校验] 解密回读应为：%s\n", *value)
}
