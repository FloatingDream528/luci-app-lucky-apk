#!/usr/bin/env bash
set -euo pipefail

RELEASE_ROOT="${LUCKY_RELEASE_ROOT:-https://release.66666.host}"
CORE_ARCH="${LUCKY_CORE_ARCH:-x86_64}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PYTHON_BIN=""
for candidate in python3 python; do
	if command -v "$candidate" >/dev/null 2>&1 &&
		"$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
		PYTHON_BIN="$candidate"
		break
	fi
done

if [ -z "$PYTHON_BIN" ]; then
	echo "未找到 python，无法解析 Lucky 最新版本。"
	exit 1
fi

cd "$REPO_ROOT"

fetch() {
	curl --connect-timeout 10 --retry 3 --retry-delay 2 -fsSL "$1"
}

root_html="$(fetch "${RELEASE_ROOT}/")"
version_list="$(printf '%s\n' "$root_html" | grep -Eo 'v[0-9]+\.[0-9]+\.[0-9]+(beta[0-9]+)?' | sort -u || true)"

if [ -z "$version_list" ]; then
	echo "未从 ${RELEASE_ROOT}/ 解析到 Lucky 版本目录。"
	exit 1
fi

latest_tag="$(printf '%s\n' "$version_list" | "$PYTHON_BIN" -c '
import re
import sys

pattern = re.compile(r"^v(\d+)\.(\d+)\.(\d+)(?:beta(\d+))?$")
versions = []
for line in sys.stdin:
    line = line.strip()
    match = pattern.match(line)
    if not match:
        continue
    major, minor, patch, beta = match.groups()
    stable_rank = 1 if beta is None else 0
    beta_number = int(beta or 0)
    versions.append(((int(major), int(minor), int(patch), stable_rank, beta_number), line))

if not versions:
    raise SystemExit("没有可用的 Lucky 版本目录")

print(max(versions)[1])
')"

tag_html="$(fetch "${RELEASE_ROOT}/${latest_tag}/")"
release_subdir="$(
	printf '%s\n' "$tag_html" |
		grep -Eo '\./[0-9][^"/]*_lucky/' |
		sed 's#^\./##; s#/$##' |
		grep -v '_docker$' |
		head -n 1 || true
)"

if [ -z "$release_subdir" ]; then
	echo "未在 ${RELEASE_ROOT}/${latest_tag}/ 找到 Lucky 核心目录。"
	exit 1
fi

release_dir="${latest_tag}/${release_subdir}"
release_html="$(fetch "${RELEASE_ROOT}/${release_dir}/")"
source_file="$(
	printf '%s\n' "$release_html" |
		grep -Eo "lucky_[^\"<> ]+_Linux_${CORE_ARCH}\\.tar\\.gz" |
		sort -u |
		head -n 1 || true
)"

if [ -z "$source_file" ]; then
	echo "未在 ${RELEASE_ROOT}/${release_dir}/ 找到 Linux_${CORE_ARCH} 核心包。"
	exit 1
fi

upstream_version="${source_file#lucky_}"
upstream_version="${upstream_version%_Linux_${CORE_ARCH}.tar.gz}"
package_version="${latest_tag#v}"
package_version="${package_version/beta/_beta}"
source_url="${RELEASE_ROOT}/${release_dir}/${source_file}"

# 保存到 dl/ 目录，以便 OpenWrt SDK 构建时直接使用本地缓存，避免远程下载超时
mkdir -p "$REPO_ROOT/dl"
target_file="$REPO_ROOT/dl/$source_file"

echo "正在下载 Lucky 核心包到 dl/ 目录..."
curl --connect-timeout 15 --retry 5 --retry-delay 3 -fsSL "$source_url" -o "$target_file"
source_hash="$(sha256sum "$target_file" | awk '{ print $1 }')"

export PACKAGE_VERSION="$package_version"
export UPSTREAM_VERSION="$upstream_version"
export CORE_ARCH
export RELEASE_DIR="$release_dir"
export SOURCE_HASH="$source_hash"
export RELEASE_ROOT
export SOURCE_URL="$source_url"
export LUCKY_TAG="$latest_tag"

# 校验远程 sha256 文件
sha256_url="${source_url}.sha256"
if remote_sha256="$(fetch "$sha256_url" 2>/dev/null | awk '{ print $1 }')" && [ -n "$remote_sha256" ]; then
	if [ "$source_hash" != "$remote_sha256" ]; then
		echo "错误: 下载的包 ($source_hash) 和远程校验和 ($remote_sha256) 不匹配！"
		exit 1
	fi
	echo "校验和 ($source_hash) 匹配成功。"
else
	echo "警告: 未找到远程 sha256 校验文件 ($sha256_url)，跳过验证。"
fi

"$PYTHON_BIN" <<'PY'
import os
import re
from pathlib import Path


def update_assignments(path, values):
    file_path = Path(path)
    text = file_path.read_text(encoding="utf-8")
    for key, value in values.items():
        text, count = re.subn(
            rf"^{re.escape(key)}:=.*$",
            f"{key}:={value}",
            text,
            flags=re.MULTILINE,
        )
        if count == 0:
            raise SystemExit(f"{path} 缺少 {key} 配置")
    file_path.write_text(text, encoding="utf-8")


update_assignments(
    "lucky/Makefile",
    {
        "PKG_VERSION": os.environ["PACKAGE_VERSION"],
        "PKG_RELEASE": "1",
        "LUCKY_UPSTREAM_VERSION": os.environ["UPSTREAM_VERSION"],
        "LUCKY_CORE_ARCH": os.environ["CORE_ARCH"],
        "LUCKY_RELEASE_DIR": os.environ["RELEASE_DIR"],
        "PKG_HASH": os.environ["SOURCE_HASH"],
    },
)

update_assignments(
    "luci-app-lucky/Makefile",
    {
        "PKG_VERSION": os.environ["PACKAGE_VERSION"],
    },
)
PY

{
	printf 'LUCKY_TAG=%s\n' "$LUCKY_TAG"
	printf 'PKG_VERSION=%s\n' "$PACKAGE_VERSION"
	printf 'LUCKY_UPSTREAM_VERSION=%s\n' "$UPSTREAM_VERSION"
	printf 'LUCKY_CORE_ARCH=%s\n' "$CORE_ARCH"
	printf 'LUCKY_RELEASE_ROOT=%s\n' "$RELEASE_ROOT"
	printf 'LUCKY_RELEASE_DIR=%s\n' "$RELEASE_DIR"
	printf 'LUCKY_SOURCE_FILE=%s\n' "$source_file"
	printf 'LUCKY_SOURCE_URL=%s\n' "$SOURCE_URL"
	printf 'PKG_HASH=%s\n' "$SOURCE_HASH"
} > .lucky-release.env

if [ -n "${GITHUB_ENV:-}" ]; then
	{
		printf 'LUCKY_TAG=%s\n' "$LUCKY_TAG"
		printf 'LUCKY_PKG_VERSION=%s\n' "$PACKAGE_VERSION"
		printf 'LUCKY_UPSTREAM_VERSION=%s\n' "$UPSTREAM_VERSION"
		printf 'LUCKY_CORE_ARCH=%s\n' "$CORE_ARCH"
		printf 'LUCKY_RELEASE_DIR=%s\n' "$RELEASE_DIR"
		printf 'LUCKY_SOURCE_URL=%s\n' "$SOURCE_URL"
		printf 'LUCKY_CORE_HASH=%s\n' "$SOURCE_HASH"
	} >> "$GITHUB_ENV"
fi

echo "Lucky 最新版本: ${LUCKY_TAG}"
echo "核心包: ${SOURCE_URL}"
echo "sha256: ${SOURCE_HASH}"
