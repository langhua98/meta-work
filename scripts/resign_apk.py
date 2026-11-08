#!/usr/bin/env python3
"""用小橘遥控（法莉娅）安卓版的固定密钥重新签一个 APK（GitHub 上没配 XIAOJU_TOKEN、编出来是临时签名时用）。

    XIAOJU_TOKEN=xa_… python3 scripts/resign_apk.py 输入.apk 输出.apk

- 密钥在小橘云盘私有文件夹 /小橘推送/签名/android-signing.json（PKCS12 + 密码），用完就删，不落盘到别处。
- 去掉原来的签名（META-INF 里的签名文件和 v2 签名块），用 JDK 的 jarsigner 签 v1（SHA-1 摘要：Android 4.2 / API 17
  只认 SHA-1 的 v1 签名）。只有 v1：Android 4.2～10 能装；Android 11 以上要 v2，得用 GitHub 编译时的 apksigner 签。
- 签完核对证书指纹和云盘里那把一样。
"""
import base64, hashlib, json, os, re, shutil, subprocess, sys, tempfile, urllib.parse, urllib.request, zipfile

BASE = (os.environ.get("XIAOJU_URL") or "https://langhua1998-xiaoju-cloud.hf.space").rstrip("/") + "/api/agent/v1"
KEY_PATH = "/小橘推送/签名/android-signing.json"
SIG_FILE = re.compile(r"^META-INF/([^/]+\.(SF|RSA|DSA|EC)|MANIFEST\.MF)$", re.I)


def get(path):
    req = urllib.request.Request(BASE + path, headers={"Authorization": "Bearer " + os.environ["XIAOJU_TOKEN"]})
    return urllib.request.urlopen(req, timeout=60).read()


def strip(src, dst):
    """复制一份不带签名的 APK（zipfile 重写时 v2 签名块自然就没了）。"""
    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w") as zout:
        for info in zin.infolist():
            if SIG_FILE.match(info.filename):
                continue
            zout.writestr(info, zin.read(info.filename), compress_type=info.compress_type)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    if not os.environ.get("XIAOJU_TOKEN"):
        sys.exit("缺少 XIAOJU_TOKEN")
    src, out = sys.argv[1], sys.argv[2]
    item = json.loads(get("/items?" + urllib.parse.urlencode({"path": KEY_PATH})))
    item = item.get("item") or item
    key = json.loads(get("/items/%s/content" % item["id"]))
    tmp = tempfile.mkdtemp(prefix="xjsign-")
    try:
        ks = os.path.join(tmp, "k.p12")
        with open(ks, "wb") as f:
            f.write(base64.b64decode(key["p12_base64"]))
        env = dict(os.environ, XJ_PASS=key["password"])
        unsigned = os.path.join(tmp, "u.apk")
        strip(src, unsigned)
        subprocess.run(["jarsigner", "-keystore", ks, "-storetype", "PKCS12", "-storepass:env", "XJ_PASS",
                        "-digestalg", "SHA1", "-sigalg", "SHA1withRSA", "-signedjar", out, unsigned, key["alias"]],
                       env=env, check=True, stdout=subprocess.DEVNULL)
        # 核对：APK 里的证书就是云盘那把
        want = subprocess.run(["keytool", "-list", "-keystore", ks, "-storetype", "PKCS12", "-storepass:env", "XJ_PASS",
                               "-alias", key["alias"], "-rfc"], env=env, check=True, capture_output=True, text=True).stdout
        got = subprocess.run(["keytool", "-printcert", "-jarfile", out, "-rfc"], check=True, capture_output=True, text=True).stdout
        pem = lambda s: re.search(r"-----BEGIN CERTIFICATE-----(.+?)-----END CERTIFICATE-----", s, re.S).group(1).replace("\n", "")
        if pem(want) != pem(got):
            sys.exit("签完的证书和固定密钥对不上")
        fp = hashlib.sha256(base64.b64decode(pem(got))).hexdigest()
        with zipfile.ZipFile(out) as z:
            bad = z.testzip()
        if bad:
            sys.exit("签完的 APK 坏了：" + bad)
        print(f"已用固定密钥签名：{out}（证书 SHA-256 {fp[:16]}…）")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


main()
