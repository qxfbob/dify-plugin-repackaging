#!/bin/bash
# author: Junjie.M
# modified for Dify ARM64 offline plugin repackaging

set -o pipefail

DEFAULT_GITHUB_API_URL=https://github.com
DEFAULT_MARKETPLACE_API_URL=https://marketplace.dify.ai
DEFAULT_PIP_MIRROR_URL=https://mirrors.aliyun.com/pypi/simple

GITHUB_API_URL="${GITHUB_API_URL:-$DEFAULT_GITHUB_API_URL}"
MARKETPLACE_API_URL="${MARKETPLACE_API_URL:-$DEFAULT_MARKETPLACE_API_URL}"
PIP_MIRROR_URL="${PIP_MIRROR_URL:-$DEFAULT_PIP_MIRROR_URL}"

CURR_DIR=$(dirname "$0")
cd "$CURR_DIR" || exit 1
CURR_DIR=$(pwd)

ARCH_NAME=$(uname -m)
OS_TYPE=$(uname)
OS_TYPE=$(echo "$OS_TYPE" | tr '[:upper:]' '[:lower:]')

CMD_NAME="dify-plugin-${OS_TYPE}-amd64"
if [[ "$ARCH_NAME" == "arm64" || "$ARCH_NAME" == "aarch64" ]]; then
    CMD_NAME="dify-plugin-${OS_TYPE}-arm64"
fi

PIP_PLATFORM=""
RAW_PLATFORM=""
PACKAGE_SUFFIX="offline"
PRERELEASE_ALLOW=0

market() {
    if [[ -z "$2" || -z "$3" || -z "$4" ]]; then
        echo ""
        echo "Usage: $0 market [plugin author] [plugin name] [plugin version]"
        echo "Example:"
        echo "  $0 market langgenius openai_api_compatible 0.0.53"
        echo ""
        exit 1
    fi

    PLUGIN_AUTHOR=$2
    PLUGIN_NAME=$3
    PLUGIN_VERSION=$4
    PLUGIN_PACKAGE_PATH="${CURR_DIR}/${PLUGIN_AUTHOR}-${PLUGIN_NAME}_${PLUGIN_VERSION}.difypkg"
    PLUGIN_DOWNLOAD_URL="${MARKETPLACE_API_URL}/api/v1/plugins/${PLUGIN_AUTHOR}/${PLUGIN_NAME}/${PLUGIN_VERSION}/download"

    echo ""
    echo "=========================================="
    echo "Downloading from Dify Marketplace"
    echo "=========================================="
    echo "Author: ${PLUGIN_AUTHOR}"
    echo "Plugin: ${PLUGIN_NAME}"
    echo "Version: ${PLUGIN_VERSION}"
    echo "URL: ${PLUGIN_DOWNLOAD_URL}"

    curl -fL -o "${PLUGIN_PACKAGE_PATH}" "${PLUGIN_DOWNLOAD_URL}"
    if [[ $? -ne 0 ]]; then
        echo "✗ Error: Download failed"
        echo "  Please check the plugin author, name, and version"
        exit 1
    fi

    DOWNLOADED_SIZE=$(du -h "${PLUGIN_PACKAGE_PATH}" | cut -f1)
    echo "✓ Downloaded successfully (${DOWNLOADED_SIZE})"

    repackage "${PLUGIN_PACKAGE_PATH}"
}

github() {
    if [[ -z "$2" || -z "$3" || -z "$4" ]]; then
        echo ""
        echo "Usage: $0 github [Github repo] [Release title] [Assets name]"
        echo "Example:"
        echo "  $0 github junjiem/dify-plugin-tools-dbquery v0.0.2 db_query.difypkg"
        echo ""
        exit 1
    fi

    GITHUB_REPO=$2
    if [[ "${GITHUB_REPO}" != "${GITHUB_API_URL}"* ]]; then
        GITHUB_REPO="${GITHUB_API_URL}/${GITHUB_REPO}"
    fi

    RELEASE_TITLE=$3
    ASSETS_NAME=$4
    PLUGIN_NAME="${ASSETS_NAME%.difypkg}"
    PLUGIN_PACKAGE_PATH="${CURR_DIR}/${PLUGIN_NAME}-${RELEASE_TITLE}.difypkg"
    PLUGIN_DOWNLOAD_URL="${GITHUB_REPO}/releases/download/${RELEASE_TITLE}/${ASSETS_NAME}"

    echo ""
    echo "=========================================="
    echo "Downloading from GitHub"
    echo "=========================================="
    echo "Repository: ${GITHUB_REPO}"
    echo "Release: ${RELEASE_TITLE}"
    echo "Asset: ${ASSETS_NAME}"
    echo "URL: ${PLUGIN_DOWNLOAD_URL}"

    curl -fL -o "${PLUGIN_PACKAGE_PATH}" "${PLUGIN_DOWNLOAD_URL}"
    if [[ $? -ne 0 ]]; then
        echo "✗ Error: Download failed"
        echo "  Please check the GitHub repo, release title, and asset name"
        exit 1
    fi

    DOWNLOADED_SIZE=$(du -h "${PLUGIN_PACKAGE_PATH}" | cut -f1)
    echo "✓ Downloaded successfully (${DOWNLOADED_SIZE})"

    repackage "${PLUGIN_PACKAGE_PATH}"
}

_local() {
    if [[ -z "$2" ]]; then
        echo ""
        echo "Usage: $0 local [difypkg path]"
        echo "Example:"
        echo "  $0 local ./db_query.difypkg"
        echo ""
        exit 1
    fi

    PLUGIN_PACKAGE_PATH=$(realpath "$2")
    repackage "${PLUGIN_PACKAGE_PATH}"
}

install_unzip() {
    if command -v unzip &> /dev/null; then
        return 0
    fi

    echo "Installing unzip ..."

    if command -v apt-get &> /dev/null; then
        sudo apt-get update
        sudo apt-get install -y unzip
    elif command -v dnf &> /dev/null; then
        sudo dnf install -y unzip
    elif command -v yum &> /dev/null; then
        sudo yum install -y unzip
    else
        echo "✗ Error: unzip not found and no supported package manager detected."
        echo "  Please install unzip manually."
        exit 1
    fi
}

strip_dev_dependencies_from_pyproject() {
    if [ ! -f "pyproject.toml" ]; then
        return 0
    fi

    echo ""
    echo "Removing dev/test dependency groups from pyproject.toml..."

    python3 - <<'PY'
from pathlib import Path

p = Path("pyproject.toml")
lines = p.read_text(encoding="utf-8").splitlines()

out = []
skip_table = False
skip_multiline_optional = False

dev_keys = {
    "dev",
    "test",
    "tests",
    "pytest",
    "lint",
    "format",
    "typing",
    "docs",
}

remove_exact_tables = {
    "dependency-groups",
    "tool.uv.dependency-groups",
}

remove_table_prefixes = (
    "dependency-groups.",
    "tool.uv.dependency-groups.",
)

def table_name(line: str):
    s = line.strip()
    if s.startswith("[") and s.endswith("]"):
        return s.strip("[]").strip()
    return None

def starts_dev_key(line: str):
    s = line.strip()
    if "=" not in s:
        return False
    key = s.split("=", 1)[0].strip().strip('"').strip("'")
    return key in dev_keys

for line in lines:
    t = table_name(line)

    if t is not None:
        skip_multiline_optional = False

        if t in remove_exact_tables or t.startswith(remove_table_prefixes):
            skip_table = True
            continue

        skip_table = False
        out.append(line)
        continue

    if skip_table:
        continue

    if skip_multiline_optional:
        if "]" in line:
            skip_multiline_optional = False
        continue

    # Remove dev/test entries inside [project.optional-dependencies]
    # Supports:
    #   dev = [...]
    #   test = [
    #       ...
    #   ]
    if starts_dev_key(line):
        if "[" in line and "]" not in line:
            skip_multiline_optional = True
        continue

    out.append(line)

p.write_text("\n".join(out) + "\n", encoding="utf-8")
PY

    echo "✓ Removed dev/test dependency groups from pyproject.toml"

    echo "Remaining dev/test references:"
    grep -nE "pytest|dependency-groups|optional-dependencies|dev =" pyproject.toml || true
}

inject_uv_offline_config() {
    if [ ! -f "pyproject.toml" ]; then
        return 0
    fi

    echo ""
    echo "Injecting offline uv configuration into pyproject.toml..."

    python3 - <<'PY'
from pathlib import Path

p = Path("pyproject.toml")
lines = p.read_text(encoding="utf-8").splitlines()

out = []
skip = False

remove_tables = {
    "tool.uv",
    "tool.uv.pip",
}

for line in lines:
    stripped = line.strip()

    if stripped.startswith("[") and stripped.endswith("]"):
        table = stripped.strip("[]").strip()

        if table in remove_tables:
            skip = True
            continue

        skip = False
        out.append(line)
        continue

    if skip:
        continue

    out.append(line)

append = """
[tool.uv]
# Offline installation: do not use external package indexes.
no-index = true
find-links = ["./wheels"]
prerelease = "allow"

# Important for ARM64 offline packages:
# Limit uv resolution to Linux ARM64 only.
# Otherwise uv may try to resolve Windows/macOS conditional dependencies,
# such as gevent -> cffi on win32, and fail because only Linux ARM64 wheels exist.
environments = [
    "sys_platform == 'linux' and platform_machine == 'aarch64'",
]
required-environments = [
    "sys_platform == 'linux' and platform_machine == 'aarch64'",
]

[tool.uv.pip]
no-index = true
find-links = ["./wheels"]
"""

content = "\n".join(out).rstrip() + "\n\n" + append.strip() + "\n"
p.write_text(content, encoding="utf-8")
PY

    echo "✓ Injected [tool.uv] and [tool.uv.pip] offline ARM64 configuration"
    grep -nE "tool.uv|no-index|find-links|prerelease|environments|required-environments|platform_machine|sys_platform" pyproject.toml || true
}

patch_requirements_for_arm64() {
    if [ ! -f "requirements.txt" ]; then
        return 0
    fi

    echo ""
    echo "Applying ARM64 dependency compatibility patches..."

    echo "Before jiter patch:"
    grep -n "jiter" requirements.txt || true

    python3 - <<'PY'
from pathlib import Path

p = Path("requirements.txt")
text = p.read_text(encoding="utf-8")

new_lines = []
for line in text.splitlines():
    stripped = line.strip()

    # Replace all exact pinned jiter versions:
    #   jiter==0.15.0
    #   jiter==0.16.0
    #   jiter==0.x.x ; marker
    if stripped.startswith("jiter=="):
        prefix_spaces = line[:len(line) - len(line.lstrip())]
        new_lines.append(prefix_spaces + "jiter==0.14.0")
    else:
        new_lines.append(line)

p.write_text("\n".join(new_lines) + "\n", encoding="utf-8")
PY

    echo "After jiter patch:"
    grep -n "jiter" requirements.txt || true

    echo "✓ Dependency patches applied"
}

update_requirements_for_offline() {
    if [ ! -f "requirements.txt" ]; then
        return 0
    fi

    echo ""
    echo "Updating requirements.txt for offline installation..."

    if ! grep -q '^--no-index --find-links=./wheels/$' requirements.txt; then
        if [[ "$OS_TYPE" == "darwin" ]]; then
            sed -i ".bak" '1i\
--no-index --find-links=./wheels/
' requirements.txt && rm -f requirements.txt.bak
        else
            sed -i '1i\--no-index --find-links=./wheels/' requirements.txt
        fi
    fi

    if [ -f ".difyignore" ]; then
        IGNORE_PATH=".difyignore"
    elif [ -f ".gitignore" ]; then
        IGNORE_PATH=".gitignore"
    else
        IGNORE_PATH=""
    fi

    if [ -n "$IGNORE_PATH" ]; then
        if [[ "$OS_TYPE" == "darwin" ]]; then
            sed -i ".bak" '/^wheels\//d' "${IGNORE_PATH}" && rm -f "${IGNORE_PATH}.bak"
        else
            sed -i '/^wheels\//d' "${IGNORE_PATH}"
        fi
    fi

    echo "✓ requirements.txt updated for offline mode"
}

repackage() {
    local PACKAGE_PATH=$1
    PACKAGE_NAME_WITH_EXTENSION=$(basename "${PACKAGE_PATH}")
    PACKAGE_NAME="${PACKAGE_NAME_WITH_EXTENSION%.*}"

    echo ""
    echo "=========================================="
    echo "Dify Plugin Repackaging Tool"
    echo "=========================================="
    echo "Source: ${PACKAGE_PATH}"
    echo "Work directory: ${CURR_DIR}/${PACKAGE_NAME}"

    echo ""
    echo "Extracting plugin package..."
    install_unzip

    rm -rf "${CURR_DIR:?}/${PACKAGE_NAME}"

    unzip -o "${PACKAGE_PATH}" -d "${CURR_DIR}/${PACKAGE_NAME}"
    if [[ $? -ne 0 ]]; then
        echo "✗ Error: Failed to extract package"
        exit 1
    fi

    echo "✓ Package extracted successfully"

    cd "${CURR_DIR}/${PACKAGE_NAME}" || exit 1

    if [ ! -f "pyproject.toml" ] && [ ! -f "requirements.txt" ]; then
        echo "⚠ Warning: No pyproject.toml or requirements.txt found"
    fi

    strip_dev_dependencies_from_pyproject

    if python3 -m pip --version &> /dev/null 2>&1; then
        PIP_CMD="python3 -m pip"
    elif command -v pip &> /dev/null && pip --version &> /dev/null 2>&1; then
        PIP_CMD="pip"
    elif command -v pip3 &> /dev/null && pip3 --version &> /dev/null 2>&1; then
        PIP_CMD="pip3"
    else
        echo "✗ Error: pip not found. Install: python3 -m ensurepip --upgrade"
        exit 1
    fi

    echo "✓ Using pip: ${PIP_CMD}"

    echo ""
    echo "=========================================="
    echo "Step 1: Detecting Python and platform"
    echo "=========================================="

    PYTHON_CMD_FOR_UV="python3"
    PY_VERSION_FULL=$(python3 --version 2>&1 | awk '{print $2}')
    PY_MAJOR=$(echo "$PY_VERSION_FULL" | cut -d. -f1)
    PY_MINOR=$(echo "$PY_VERSION_FULL" | cut -d. -f2)
    PYTHON_VERSION=$PY_VERSION_FULL

    echo "Detected Python: $PYTHON_VERSION"

    if [ "$PY_MAJOR" -eq 3 ] && [ "$PY_MINOR" -ge 14 ]; then
        echo "⚠ Warning: Python $PYTHON_VERSION is too new for some packages"

        if command -v python3.12 &> /dev/null; then
            PYTHON_CMD_FOR_UV="python3.12"
            PYTHON_VERSION=$($PYTHON_CMD_FOR_UV --version 2>&1 | awk '{print $2}')
            echo "✓ Switched to python3.12 ($PYTHON_VERSION)"
        elif command -v python3.13 &> /dev/null; then
            PYTHON_CMD_FOR_UV="python3.13"
            PYTHON_VERSION=$($PYTHON_CMD_FOR_UV --version 2>&1 | awk '{print $2}')
            echo "✓ Switched to python3.13 ($PYTHON_VERSION)"
        else
            echo "⚠ Warning: No compatible Python version found, proceeding with $PYTHON_VERSION"
        fi
    else
        echo "✓ Python version $PYTHON_VERSION is compatible"
    fi

    UV_PY_VERSION=$($PYTHON_CMD_FOR_UV - <<'PY'
import sys
print(f"{sys.version_info.major}.{sys.version_info.minor}")
PY
)

    if [[ -n "$RAW_PLATFORM" ]]; then
        echo "Target platform args: ${RAW_PLATFORM}"
    else
        echo "Target platform args: current platform"
    fi

    UV_PRERELEASE_FLAG=""
    if [[ "$PRERELEASE_ALLOW" -eq 1 ]]; then
        UV_PRERELEASE_FLAG="--prerelease=allow"
        echo "Prerelease versions: allowed"
    else
        echo "Prerelease versions: disallowed"
    fi

    echo "✓ Configuration: python=$UV_PY_VERSION, raw_platform=${RAW_PLATFORM:-current}"

    echo ""
    echo "=========================================="
    echo "Step 2: Processing dependencies"
    echo "=========================================="

    if [ -f "pyproject.toml" ]; then
        if command -v uv &> /dev/null; then
            echo "Found pyproject.toml, regenerating requirements.txt with uv..."

            rm -f requirements.txt
            rm -f uv.lock

            echo "Generating fresh uv.lock file..."
            uv lock \
                --python "${UV_PY_VERSION}" \
                ${UV_PRERELEASE_FLAG}

            if [[ $? -ne 0 ]]; then
                echo "✗ Error: uv lock failed"
                exit 1
            fi

            echo "Exporting fresh requirements.txt from uv.lock..."
            uv export --format requirements-txt \
                --no-hashes \
                --no-dev \
                -o requirements.txt \
                ${UV_PRERELEASE_FLAG}

            if [[ $? -ne 0 ]]; then
                echo "✗ Error: uv export failed"
                exit 1
            fi

            echo "✓ requirements.txt regenerated successfully"
        else
            echo "✗ Error: pyproject.toml found but uv is not installed"
            echo "  Please install uv: python -m pip install uv"
            exit 1
        fi
    elif [ -f "requirements.txt" ]; then
        echo "✓ Using existing requirements.txt"
    else
        echo "✗ Error: requirements.txt not found"
        exit 1
    fi

    if [ ! -f "requirements.txt" ]; then
        echo "✗ Error: requirements.txt not found"
        exit 1
    fi

    patch_requirements_for_arm64

    echo ""
    echo "=========================================="
    echo "Step 3: Downloading dependencies"
    echo "=========================================="
    echo "Index URL: ${PIP_MIRROR_URL}"

    if [ -n "$PIP_PLATFORM" ]; then
        echo "Platform args: ${PIP_PLATFORM}"
    else
        echo "Platform args: current platform"
    fi

mkdir -p ./wheels
echo "Downloading wheels to ./wheels/..."

echo "Final jiter line before pip download:"
grep -n "jiter" requirements.txt || true

# ==========================================
# 新增：手动预处理纯 Python 依赖
# ==========================================
echo "Pre-downloading pure-python packages that often fail cross-platform resolution..."

# 1. 先尝试直接下载 odfpy 的 wheel 包（不带平台参数）
echo "  -> Attempting to download odfpy wheel directly..."
${PIP_CMD} download odfpy==1.4.1 --no-deps -d ./wheels \
    --index-url "${PIP_MIRROR_URL}" \
    --trusted-host mirrors.aliyun.com \
    --trusted-host pypi.org \
    --trusted-host files.pythonhosted.org

# 2. 如果下载的是源码包，尝试构建 wheel
if ! ls ./wheels/odfpy-*.whl 1> /dev/null 2>&1; then
    echo "  -> Only source package available, building wheel from source..."
    
    # 创建临时目录构建 wheel
    mkdir -p ./tmp_odfpy
    cd ./tmp_odfpy
    
    # 下载源码包
    ${PIP_CMD} download odfpy==1.4.1 --no-binary=:all: --no-deps -d . \
        --index-url "${PIP_MIRROR_URL}" \
        --trusted-host mirrors.aliyun.com \
        --trusted-host pypi.org \
        --trusted-host files.pythonhosted.org
    
    # 解压并构建 wheel
    if ls odfpy-1.4.1.tar.gz 1> /dev/null 2>&1; then
        tar -xzf odfpy-1.4.1.tar.gz
        cd odfpy-1.4.1
        python setup.py bdist_wheel
        cp dist/odfpy-*.whl ../../wheels/
        cd ../..
        rm -rf ./tmp_odfpy
        echo "  -> Successfully built odfpy wheel from source"
    else
        echo "  -> Failed to download odfpy source package"
        cd ..
        rm -rf ./tmp_odfpy
    fi
fi

# 3. 检查是否成功获取 odfpy wheel
if ! ls ./wheels/odfpy-*.whl 1> /dev/null 2>&1; then
    echo "  -> Warning: Could not obtain odfpy wheel, will try alternative methods..."
    
    # 尝试从 GitHub 或其他可信来源下载预构建的 wheel
    echo "  -> Downloading pre-built odfpy wheel from alternative source..."
    curl -fL -o ./wheels/odfpy-1.4.1-py2.py3-none-any.whl \
        "https://github.com/odfpy/odfpy/releases/download/v1.4.1/odfpy-1.4.1-py2.py3-none-any.whl" \
        || echo "  -> Failed to download from alternative source"
fi

# 4. 其他纯 Python 包同样处理
for pkg in et-xmlfile tabulate pyxlsb; do
    echo "  -> Pre-downloading $pkg..."
    ${PIP_CMD} download "$pkg" --no-deps -d ./wheels \
        --index-url "${PIP_MIRROR_URL}" \
        --trusted-host mirrors.aliyun.com \
        --trusted-host pypi.org \
        --trusted-host files.pythonhosted.org || echo "  -> $pkg might not be needed or already exists."
done
# ==========================================

# 执行主依赖下载，关键在于加上 --find-links=./wheels
${PIP_CMD} download ${PIP_PLATFORM} \
    --prefer-binary \
    --find-links=./wheels \
    -r requirements.txt \
    -d ./wheels \
    --index-url "${PIP_MIRROR_URL}" \
    --trusted-host mirrors.aliyun.com \
    --trusted-host pypi.org \
    --trusted-host files.pythonhosted.org



    if [[ $? -ne 0 ]]; then
        echo "✗ Error: Failed to download dependencies"
        exit 1
    fi

    WHEEL_COUNT=$(ls -1 ./wheels/*.whl 2>/dev/null | wc -l)
    echo "✓ Downloaded ${WHEEL_COUNT} wheel packages"

    echo ""
    echo "Injecting offline configuration after wheel download..."
    inject_uv_offline_config

    echo ""
    echo "Removing uv.lock before packaging..."
    rm -f uv.lock
    echo "✓ Removed uv.lock to force offline resolution from ./wheels"

    echo ""
    echo "=========================================="
    echo "Step 4: Updating offline install config"
    echo "=========================================="

    update_requirements_for_offline

    echo ""
    echo "=========================================="
    echo "Step 5: Packaging plugin"
    echo "=========================================="

    cd "${CURR_DIR}" || exit 1

    if [ ! -f "${CURR_DIR}/${CMD_NAME}" ]; then
        echo "✗ Error: packaging command not found: ${CURR_DIR}/${CMD_NAME}"
        exit 1
    fi

    chmod 755 "${CURR_DIR}/${CMD_NAME}"

    OUTPUT_PACKAGE="${CURR_DIR}/${PACKAGE_NAME}-${PACKAGE_SUFFIX}.difypkg"
    echo "Packaging: ${PACKAGE_NAME}"
    echo "Output: ${OUTPUT_PACKAGE}"
    echo "Max size: 5120 MB"

    "${CURR_DIR}/${CMD_NAME}" plugin package "${CURR_DIR}/${PACKAGE_NAME}" \
        -o "${OUTPUT_PACKAGE}" \
        --max-size 5120

    if [[ $? -ne 0 ]]; then
        echo "✗ Error: Packaging failed"
        exit 1
    fi

    FILE_SIZE=$(du -h "${OUTPUT_PACKAGE}" | cut -f1)

    echo ""
    echo "=========================================="
    echo "✓ Package created successfully!"
    echo "=========================================="
    echo "Location: ${OUTPUT_PACKAGE}"
    echo "Size: ${FILE_SIZE}"
    echo "Platform: ${RAW_PLATFORM:-current}"
}

print_usage() {
    echo "usage: $0 [-p platform] [-s package_suffix] [-R] {market|github|local}"
    echo ""
    echo "-p platform:"
    echo "    Python packages platform for cross repacking."
    echo "    Example:"
    echo "      -p manylinux_2_28_aarch64"
    echo "      -p \"manylinux_2_28_aarch64 --platform manylinux_2_17_aarch64 --platform manylinux2014_aarch64\""
    echo ""
    echo "-s package_suffix:"
    echo "    Output package suffix."
    echo "    Example:"
    echo "      -s offline-arm"
    echo ""
    echo "-R:"
    echo "    Allow pre-release versions during uv resolution."
    echo ""
    echo "Commands:"
    echo "    market [plugin author] [plugin name] [plugin version]"
    echo "    github [Github repo] [Release title] [Assets name]"
    echo "    local [difypkg path]"
    echo ""
    exit 1
}

while getopts "p:s:R" opt; do
    case "$opt" in
        p)
            RAW_PLATFORM="${OPTARG}"

            if [[ "${OPTARG}" == --platform* ]]; then
                PIP_PLATFORM="${OPTARG} --only-binary=:all:"
            elif [[ "${OPTARG}" == *"aarch64"* && "${OPTARG}" != *"--platform"* ]]; then
                PIP_PLATFORM="--platform ${OPTARG} --platform manylinux_2_17_aarch64 --platform manylinux2014_aarch64 --only-binary=:all:"
            else
                PIP_PLATFORM="--platform ${OPTARG} --only-binary=:all:"
            fi
            ;;
        s)
            PACKAGE_SUFFIX="${OPTARG}"
            ;;
        R)
            PRERELEASE_ALLOW=1
            ;;
        *)
            print_usage
            exit 1
            ;;
    esac
done

shift $((OPTIND - 1))

case "$1" in
    market)
        market "$@"
        ;;
    github)
        github "$@"
        ;;
    local)
        _local "$@"
        ;;
    *)
        print_usage
        exit 1
        ;;
esac

exit 0
