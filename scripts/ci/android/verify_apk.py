"""核验 Android arm64 交付物，输出不包含私钥的 JSON 证据。"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import zipfile


ROOT = Path(__file__).resolve().parents[3]


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def run(*args, cwd=ROOT):
    return subprocess.check_output(args, cwd=cwd, text=True, encoding="utf-8", errors="replace").strip()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def allocated_sections(data):
    # AGP 会剥离调试符号；比较全部带 SHF_ALLOC 标记的节，验证实际装载内容。
    require(data[:6] == b"\x7fELF\x02\x01", "原生库不是小端 ELF64")
    require(struct.unpack_from("<H", data, 18)[0] == 183, "原生库不是 AArch64")
    offset = struct.unpack_from("<Q", data, 40)[0]
    size, count, names_index = struct.unpack_from("<HHH", data, 58)
    sections = [struct.unpack_from("<IIQQQQIIQQ", data, offset + i * size) for i in range(count)]
    names = sections[names_index]
    strings = data[names[4]:names[4] + names[5]]
    result = {}
    for name, kind, flags, address, start, length, *_ in sections:
        if flags & 2:
            label = strings[name:strings.index(b"\0", name)].decode()
            result[label] = [address, length, sha(data[start:start + length]) if kind != 8 else "NOBITS"]
    require(result, "ELF 缺少可装载节")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apk", type=Path, required=True)
    parser.add_argument("--mode", choices=["debug", "release"], required=True)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--build-tools", default="36.0.0")
    parser.add_argument("--expected-cert", default="")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    tools = args.sdk / "build-tools" / args.build_tools
    aapt = tools / ("aapt2.exe" if os.name == "nt" else "aapt2")
    # Windows 直接调用 JAR，避免批处理文件的 shell 转义。
    signer = ["java", "-jar", str(tools / "lib/apksigner.jar")]
    badging = run(str(aapt), "dump", "badging", str(args.apk.resolve()))
    signature = run(*signer, "verify", "--verbose", "--print-certs", str(args.apk.resolve()))
    package = re.search(r"package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'", badging)
    minimum = re.search(r"^(?:minSdkVersion|sdkVersion):'(\d+)'", badging, re.M)
    target = re.search(r"^targetSdkVersion:'(\d+)'", badging, re.M)
    require(package and minimum and target, "APK manifest 信息不完整")
    require(package[1] == "com.buzhidao10068.fluxdo", "APK 应用标识不符")
    version = re.search(r"^version:\s*(\S+)", (ROOT / "pubspec.yaml").read_text(encoding="utf-8"), re.M)[1]
    version_name, version_code = version.split("+")
    require([package[3], package[2]] == [version_name, version_code], "APK 版本与 pubspec.yaml 不符")
    require(int(minimum[1]) == 28 and int(target[1]) == 36, "APK SDK 范围应为 min 28 / target 36")
    certificates = re.findall(r"Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]+)", signature)
    require(len(certificates) == 1, "APK 应包含且仅包含一个当前签名证书")
    if args.mode == "release":
        require(args.expected_cert, "候选 release 必须提供预期签名证书摘要")
    if args.expected_cert:
        expected = args.expected_cert.replace(":", "").lower().strip()
        require(certificates[0].lower() == expected, "APK 签名证书与维护者配置不符")
    rust = ROOT / "core/doh_proxy"
    rust_sha = run("git", "rev-parse", "HEAD", cwd=rust)
    gitlink = run("git", "ls-tree", "HEAD", "core/doh_proxy").split()[2]
    require(rust_sha == gitlink, "Rust HEAD 与主仓 gitlink 不一致")
    require(not run("git", "status", "--porcelain", "--untracked-files=no", cwd=rust), "Rust 存在未提交源码")
    native_root = rust / "target/aarch64-linux-android" / args.mode
    fingerprints = list((native_root / ".fingerprint").glob("doh_proxy-*/lib-doh_proxy.json"))
    require(any("ech" in json.loads(p.read_text())["features"] for p in fingerprints), "缺少 ECH 编译指纹")
    source = (native_root / "libdoh_proxy.so").read_bytes()
    staged = (ROOT / "android/app/src/main/jniLibs/arm64-v8a/libdoh_proxy.so").read_bytes()
    require(source == staged, "打包暂存库与当前 Rust 编译输出不一致")
    ca_pem = (rust / "certs/ca.crt").read_bytes()
    ca_der = (rust / "certs/ca.der").read_bytes()
    with zipfile.ZipFile(args.apk) as apk:
        libraries = [p for p in apk.namelist() if p.startswith("lib/") and p.endswith(".so")]
        require(libraries and all(p.split("/")[1] == "arm64-v8a" for p in libraries), "APK 包含其他 ABI 或缺少原生库")
        # Windows 上部分 CargoKit 批处理可能吞掉编译失败，不能只相信 Gradle 退出码。
        required_libraries = {"libdoh_proxy.so", "librhttp.so", "libsuper_native_extensions.so",
                              "libquickjs_c_bridge_plugin.so", "libflutter.so"}
        missing = required_libraries - {Path(p).name for p in libraries}
        require(not missing, f"APK 缺少必要原生库：{sorted(missing)}")
        for path in libraries:
            allocated_sections(apk.read(path))
        packed = apk.read("lib/arm64-v8a/libdoh_proxy.so")
        require(allocated_sections(source) == allocated_sections(packed), "APK 内 Rust 可装载内容与源码构建输出不一致")
        require(ca_pem in packed, "Rust 库未嵌入当前构建的 CA")
        require(apk.read("assets/flutter_assets/assets/certs/proxy_ca.pem") == ca_pem, "Flutter CA 与 Rust 不一致")
        require(apk.read("res/raw/proxy_ca.der") == ca_der, "Android CA 与 Rust 不一致")
    evidence = {
        "main_sha": run("git", "rev-parse", "HEAD"),
        "rust_sha": rust_sha,
        "main_tracked_changes": run("git", "status", "--porcelain", "--untracked-files=no"),
        "apk": args.apk.name, "apk_sha256": sha(args.apk.read_bytes()),
        "application_id": package[1], "version_name": package[3], "version_code": package[2],
        "min_sdk": int(minimum[1]), "target_sdk": int(target[1]), "abi": "arm64-v8a",
        "mode": args.mode, "signer_sha256": certificates[0].lower(),
        "signature_verification": signature, "native_libraries": libraries,
        "rust_source_library_sha256": sha(source), "rust_packed_library_sha256": sha(packed),
        "rust_allocated_sections_match": True, "ech_fingerprint_present": True,
        "ca_der_sha256": sha(ca_der), "ca_resources_match": True,
        "ci_url": f"{os.getenv('GITHUB_SERVER_URL', '')}/{os.getenv('GITHUB_REPOSITORY', '')}/actions/runs/{os.getenv('GITHUB_RUN_ID', '')}",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"APK 核验通过：{args.apk.name} SHA-256 {evidence['apk_sha256']}")


if __name__ == "__main__":
    main()
