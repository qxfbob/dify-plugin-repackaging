#!/bin/bash
# author: Junjie.M

DEFAULT_GITHUB_API_URL=https://github.com
DEFAULT_MARKETPLACE_API_URL=https://marketplace.dify.ai
DEFAULT_PIP_MIRROR_URL=https://mirrors.aliyun.com/pypi/simple

GITHUB_API_URL="${GITHUB_API_URL:-$DEFAULT_GITHUB_API_URL}"
MARKETPLACE_API_URL="${MARKETPLACE_API_URL:-$DEFAULT_MARKETPLACE_API_URL}"
PIP_MIRROR_URL="${PIP_MIRROR_URL:-$DEFAULT_PIP_MIRROR_URL}"

CURR_DIR=`dirname $0`
cd $CURR_DIR || exit 1
CURR_DIR=`pwd`
USER=`whoami`
ARCH_NAME=`uname -m`
OS_TYPE=$(uname)
OS_TYPE=$(echo "$OS_TYPE" | tr '[:upper:]' '[:lower:]')

CMD_NAME="dify-plugin-${OS_TYPE}-amd64"
if [[ "arm64" == "$ARCH_NAME" || "aarch64" == "$ARCH_NAME" ]]; then
	CMD_NAME="dify-plugin-${OS_TYPE}-arm64"
fi

# Cross packaging / resolution controls
PIP_PLATFORM=""
RAW_PLATFORM=""    # raw value from -p, e.g. manylinux2014_x86_64
PACKAGE_SUFFIX="offline"
PRERELEASE_ALLOW=0

market(){
	if [[ -z "$2" || -z "$3" || -z "$4" ]]; then
		echo ""
		echo "Usage: "$0" market [plugin author] [plugin name] [plugin version]"
		echo "Example:"
		echo "	"$0" market junjiem mcp_sse 0.0.1"
		echo "	"$0" market langgenius agent 0.0.9"
		echo ""
		exit 1
	fi
	PLUGIN_AUTHOR=$2
	PLUGIN_NAME=$3
	PLUGIN_VERSION=$4
	PLUGIN_PACKAGE_PATH=${CURR_DIR}/${PLUGIN_AUTHOR}-${PLUGIN_NAME}_${PLUGIN_VERSION}.difypkg
	PLUGIN_DOWNLOAD_URL=${MARKETPLACE_API_URL}/api/v1/plugins/${PLUGIN_AUTHOR}/${PLUGIN_NAME}/${PLUGIN_VERSION}/download

	echo ""
	echo "=========================================="
	echo "Downloading from Dify Marketplace"
	echo "=========================================="
	echo "Author: ${PLUGIN_AUTHOR}"
	echo "Plugin: ${PLUGIN_NAME}"
	echo "Version: ${PLUGIN_VERSION}"
	echo "URL: ${PLUGIN_DOWNLOAD_URL}"

	curl -L -o ${PLUGIN_PACKAGE_PATH} ${PLUGIN_DOWNLOAD_URL}
	if [[ $? -ne 0 ]]; then
		echo "✗ Error: Download failed"
		echo "  Please check the plugin author, name, and version"
		exit 1
	fi

	DOWNLOADED_SIZE=$(du -h "${PLUGIN_PACKAGE_PATH}" | cut -f1)
	echo "✓ Downloaded successfully (${DOWNLOADED_SIZE})"

	repackage ${PLUGIN_PACKAGE_PATH}
}

github(){
	if [[ -z "$2" || -z "$3" || -z "$4" ]]; then
		echo ""
		echo "Usage: "$0" github [Github repo] [Release title] [Assets name (include .difypkg suffix)]"
		echo "Example:"
		echo "	"$0" github junjiem/dify-plugin-tools-dbquery v0.0.2 db_query.difypkg"
		echo "	"$0" github https://github.com/junjiem/dify-plugin-agent-mcp_sse 0.0.1 agent-mcp_see.difypkg"
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
	PLUGIN_PACKAGE_PATH=${CURR_DIR}/${PLUGIN_NAME}-${RELEASE_TITLE}.difypkg
	PLUGIN_DOWNLOAD_URL=${GITHUB_REPO}/releases/download/${RELEASE_TITLE}/${ASSETS_NAME}

	echo ""
	echo "=========================================="
	echo "Downloading from GitHub"
	echo "=========================================="
	echo "Repository: ${GITHUB_REPO}"
	echo "Release: ${RELEASE_TITLE}"
	echo "Asset: ${ASSETS_NAME}"
	echo "URL: ${PLUGIN_DOWNLOAD_URL}"

	curl -L -o ${PLUGIN_PACKAGE_PATH} ${PLUGIN_DOWNLOAD_URL}
	if [[ $? -ne 0 ]]; then
		echo "✗ Error: Download failed"
		echo "  Please check the GitHub repo, release title, and asset name"
		exit 1
	fi

	DOWNLOADED_SIZE=$(du -h "${PLUGIN_PACKAGE_PATH}" | cut -f1)
	echo "✓ Downloaded successfully (${DOWNLOADED_SIZE})"

	repackage ${PLUGIN_PACKAGE_PATH}
}

_local(){
	echo $2
	if [[ -z "$2" ]]; then
		echo ""
		echo "Usage: "$0" local [difypkg path]"
		echo "Example:"
		echo "	"$0" local ./db_query.difypkg"
		echo "	"$0" local /root/dify-plugin/db_query.difypkg"
		echo ""
		exit 1
	fi
	PLUGIN_PACKAGE_PATH=`realpath $2`
	repackage ${PLUGIN_PACKAGE_PATH}
}

repackage(){
	local PACKAGE_PATH=$1
	PACKAGE_NAME_WITH_EXTENSION=`basename ${PACKAGE_PATH}`
	PACKAGE_NAME="${PACKAGE_NAME_WITH_EXTENSION%.*}"

	echo ""
	echo "=========================================="
	echo "Dify Plugin Repackaging Tool"
	echo "=========================================="
	echo "Source: ${PACKAGE_PATH}"
	echo "Work directory: ${CURR_DIR}/${PACKAGE_NAME}"

	# Extract plugin package
	echo ""
	echo "Extracting plugin package..."
	install_unzip
	unzip -o ${PACKAGE_PATH} -d ${CURR_DIR}/${PACKAGE_NAME}
	if [[ $? -ne 0 ]]; then
		echo "✗ Error: Failed to extract package"
		exit 1
	fi
	echo "✓ Package extracted successfully"

	cd ${CURR_DIR}/${PACKAGE_NAME} || exit 1
	if [ ! -f "pyproject.toml" ] && [ ! -f "requirements.txt" ]; then
		echo "⚠ Warning: No pyproject.toml or requirements.txt found"
	fi

	# Inject [tool.uv] config into pyproject.toml (runtime will use local wheels offline)
inject_uv_into_pyproject() {
    local PYFILE="$1"
    [ -f "$PYFILE" ] || return 0
    awk '
    BEGIN { in_uv=0; saw_uv=0; saw_no=0; saw_find=0; saw_pre=0; saw_env=0 }
    function print_missing(){
      if (!saw_no) print "no-index = true";
      if (!saw_find) print "find-links = [\"./wheels\"]";
      if (!saw_pre) print "prerelease = \"allow\"";
      if (!saw_env) print "environments = [\"sys_platform == \\\"linux\\\"\"]";
    }
    /^[ \t]*\[tool\.uv\][ \t]*$/ { saw_uv=1; in_uv=1; saw_no=0; saw_find=0; saw_pre=0; saw_env=0; print; next }
    { if (in_uv && $0 ~ /^[ \t]*\[/) { print_missing(); in_uv=0 } }
    { if (in_uv && $0 ~ /^[ \t]*no-index[ \t]*=/) { print "no-index = true"; saw_no=1; next } }
    { if (in_uv && $0 ~ /^[ \t]*find-links[ \t]*=/) { print "find-links = [\"./wheels\"]"; saw_find=1; next } }
    { if (in_uv && $0 ~ /^[ \t]*prerelease[ \t]*=/) { print "prerelease = \"allow\""; saw_pre=1; next } }
    { if (in_uv && $0 ~ /^[ \t]*environments[ \t]*=/) { print "environments = [\"sys_platform == \\\"linux\\\"\"]"; saw_env=1; next } }
    { print }
    END { if (in_uv) { print_missing() } if (!saw_uv) { print "" print "[tool.uv]" print "no-index = true" print "find-links = [\"./wheels\"]" print "prerelease = \"allow\"" print "environments = [\"sys_platform == \\\"linux\\\"\"]" } }
    ' "$PYFILE" > "$PYFILE.tmp" && mv "$PYFILE.tmp" "$PYFILE"
    echo "Injected [tool.uv] into $PYFILE"
}

	if python3 -m pip --version &> /dev/null 2>&1; then
		PIP_CMD="python3 -m pip"
	elif command -v pip &> /dev/null && pip --version &> /dev/null 2>&1; then
		PIP_CMD=pip
	elif command -v pip3 &> /dev/null && pip3 --version &> /dev/null 2>&1; then
		PIP_CMD=pip3
	else
		echo "pip not found. Install: python3 -m ensurepip --upgrade"
		exit 1
	fi
	echo "✓ Using pip: ${PIP_CMD}"

 # ============================================
  # Step 0: Install uv
  # ============================================
  if ! command -v uv &> /dev/null; then
      echo "Installing uv..."
      pip install uv 2>/dev/null || pip3 install uv 2>/dev/null
      if ! command -v uv &> /dev/null; then
          curl -LsSf https://astral.sh/uv/install.sh | sh 2>/dev/null
          export PATH="$HOME/.local/bin:$PATH"
      fi
  fi
  command -v uv &> /dev/null && echo "✓ uv: $(uv --version)" || echo "⚠ uv not found"

  # ============================================
  # Step 1: Detect Python and platform
  # ============================================
  echo ""
  echo "=========================================="
  echo "Step 1: Detecting Python and platform"
  echo "=========================================="
  
  # 检测Python版本，如果不是3.12则尝试切换
  PYTHON_CMD_FOR_UV="python3"
  PY_VERSION_FULL=$(python3 --version 2>&1 | awk '{print $2}')
  PY_MAJOR=$(echo $PY_VERSION_FULL | cut -d. -f1)
  PY_MINOR=$(echo $PY_VERSION_FULL | cut -d. -f2)
  PYTHON_VERSION=$PY_VERSION_FULL
  
  echo "Detected Python: $PYTHON_VERSION"
  
  # 如果Python不是3.12，尝试使用3.12
  if [ "$PY_MAJOR" -eq 3 ] && [ "$PY_MINOR" -ne 12 ]; then
      if command -v python3.12 &> /dev/null; then
          PYTHON_CMD_FOR_UV="python3.12"
          PYTHON_VERSION=$($PYTHON_CMD_FOR_UV --version 2>&1 | awk '{print $2}')
          echo "✓ Switched to python3.12 ($PYTHON_VERSION) for compatibility"
      else
          echo "⚠ Warning: Python 3.12 not found, using $PYTHON_VERSION"
      fi
  else
      echo "✓ Python version $PYTHON_VERSION is compatible"
  fi
  
  # 设置uv目标平台
  local UV_PLATFORM=""
  if [[ -n "$RAW_PLATFORM" ]]; then
      case "$RAW_PLATFORM" in
          *linux*|*manylinux* )
              UV_PLATFORM="linux"
              echo "Target platform: Linux (cross-compilation from $OS_TYPE)"
              ;;
          *macos*|*darwin* )
              UV_PLATFORM="macos"
              echo "Target platform: macOS (cross-compilation from $OS_TYPE)"
              ;;
          *win* )
              UV_PLATFORM="windows"
              echo "Target platform: Windows (cross-compilation from $OS_TYPE)"
              ;;
          * )
              UV_PLATFORM=""
              echo "Target platform: current ($OS_TYPE)"
              ;;
      esac
  else
      if [[ "$OS_TYPE" == "darwin" ]]; then
          UV_PLATFORM="macos"
      elif [[ "$OS_TYPE" == "linux" ]]; then
          UV_PLATFORM="linux"
      elif [[ "$OS_TYPE" == "windows" ]]; then
          UV_PLATFORM="windows"
      fi
      echo "Target platform: $UV_PLATFORM (current system)"
  fi
  
  # 设置prerelease标志
  UV_PRERELEASE_FLAG=""
  if [[ "$PRERELEASE_ALLOW" -eq 1 ]]; then
      UV_PRERELEASE_FLAG="--prerelease=allow"
      echo "Prerelease versions: allowed"
  else
      echo "Prerelease versions: disallowed"
  fi
  
  echo "✓ Configuration: platform=${UV_PLATFORM:-current}, python=$PYTHON_VERSION"

    # ============================================
  # Step 2: Processing dependencies
  # ============================================
  echo ""
  echo "=========================================="
  echo "Step 2: Processing dependencies"
  echo "=========================================="
  
  # Inject [tool.uv] config to enable offline wheel usage
  if [ -f "pyproject.toml" ]; then
      echo "Found pyproject.toml, injecting [tool.uv] configuration..."
      inject_uv_into_pyproject "pyproject.toml"
  fi

  if [ -f "pyproject.toml" ] && [ ! -f "requirements.txt" ]; then
      if command -v uv &> /dev/null; then
          echo "Generating uv.lock file..."
          uv lock ${UV_PLATFORM:+--python-platform ${UV_PLATFORM}} \
          --python-version "${UV_PY_VERSION}" ${UV_PRERELEASE_FLAG}
          if [[ $? -ne 0 ]]; then
              echo "✗ Error: uv lock failed"
              exit 1
          fi
          echo "✓ uv.lock generated successfully"
          echo "Exporting requirements.txt from uv.lock..."
          uv export --format requirements-txt -o requirements.txt \
          ${UV_PLATFORM:+--python-platform ${UV_PLATFORM}} \
          --python-version "${UV_PY_VERSION}" ${UV_PRERELEASE_FLAG}
          if [[ $? -ne 0 ]]; then
              echo "✗ Error: uv export failed"
              exit 1
          fi
          echo "✓ requirements.txt generated successfully"
      else
          echo "✗ Error: pyproject.toml found but uv is not installed"
          echo " Please install uv: pip install uv"
          echo " Or commit requirements.txt with the plugin"
          exit 1
      fi
  elif [ -f "requirements.txt" ]; then
      echo "✓ Using existing requirements.txt"
  fi

  [ ! -f "requirements.txt" ] && echo "✗ Error: requirements.txt not found" && exit 1

  # ============================================================
  # 关键新增：解析出包含所有传递依赖的完整列表
  # ============================================================
  REQ_FILE="requirements.txt"
  if command -v uv &> /dev/null; then
      echo "Resolving all transitive dependencies (e.g. anyio, tqdm, werkzeug)..."
      # 使用 uv pip compile 将简写的 requirements.txt 解析为包含所有间接依赖的完整列表
      uv pip compile requirements.txt -o _full_requirements.txt \
          ${UV_PLATFORM:+--python-platform ${UV_PLATFORM}} \
          --python-version "${UV_PY_VERSION}" ${UV_PRERELEASE_FLAG} 2>/dev/null || cp requirements.txt _full_requirements.txt
      
      # 如果生成成功且非空，则使用它
      if [ -s "_full_requirements.txt" ]; then
          REQ_FILE="_full_requirements.txt"
          echo "✓ Full requirements resolved: $REQ_FILE"
          # 显示传递依赖示例
          echo "  Sample transitive dependencies:"
          grep -E "^(anyio|tqdm|werkzeug|colorama)" "$REQ_FILE" | head -5 | sed 's/^/    - /'
      else
          echo "⚠ Failed to resolve full requirements, falling back to original."
      fi
  fi

   # ============================================
  # Step 3: Download Python dependencies as wheels
  # ============================================
  echo ""
  echo "=========================================="
  echo "Step 3: Downloading dependencies"
  echo "=========================================="
  echo "Index URL: ${PIP_MIRROR_URL}"
  [ -n "$PIP_PLATFORM" ] && echo "Platform: ${RAW_PLATFORM}"
  mkdir -p ./wheels
  echo "Downloading wheels to ./wheels/..."

  # ---- 阶段 1: 批量下载 (大部分包能成功) ----
  echo "Phase 1: Batch download with platform constraints..."
  if [ -n "$PIP_PLATFORM" ]; then
      BATCH_OK=0
      ${PIP_CMD} download ${PIP_PLATFORM} --only-binary=:all: --prefer-binary \
          -r "$REQ_FILE" -d ./wheels \
          --index-url ${PIP_MIRROR_URL} --trusted-host mirrors.aliyun.com 2>&1 && BATCH_OK=1

      if [ "$BATCH_OK" -ne 1 ]; then
          echo ""
          echo "⚠ Phase 1 failed, switching to per-package download..."

          # ---- 阶段 2: 逐个下载 (处理纯 Python 包如 odfpy, anyio, tqdm) ----
          echo "Phase 2: Per-package download with fallback..."
          FAILED_PKGS=""
          SUCCESS_COUNT=0
          FALLBACK_COUNT=0

          while IFS= read -r line || [ -n "$line" ]; do
              # 跳过注释、空行、pip 选项行
              line=$(echo "$line" | sed 's/#.*//' | xargs)
              [ -z "$line" ] && continue
              [[ "$line" == --* ]] && continue

              echo "  → ${line}"

              # 尝试 1: 带平台约束 (要求 wheel)
              if ${PIP_CMD} download ${PIP_PLATFORM} --only-binary=:all: --no-deps \
                  --prefer-binary "$line" -d ./wheels \
                  --index-url ${PIP_MIRROR_URL} --trusted-host mirrors.aliyun.com 2>/dev/null; then
                  echo "    ✅ wheel (platform-matched)"
                  SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
              # 尝试 2: 不带平台约束 (允许 sdist, 适用于纯 Python 包)
              elif ${PIP_CMD} download --no-deps --prefer-binary "$line" -d ./wheels \
                  --index-url ${PIP_MIRROR_URL} --trusted-host mirrors.aliyun.com 2>/dev/null; then
                  echo "    ⚠️  sdist fallback (pure-python package)"
                  FALLBACK_COUNT=$((FALLBACK_COUNT + 1))
              else
                  echo "    ❌ FAILED"
                  FAILED_PKGS="${FAILED_PKGS}\n    - ${line}"
              fi
          done < "$REQ_FILE"

          echo ""
          echo "  Phase 2 summary: ${SUCCESS_COUNT} wheels, ${FALLBACK_COUNT} sdist fallbacks"

          if [ -n "$FAILED_PKGS" ]; then
              echo ""
              echo "✗ Error: Failed to download the following packages:"
              echo -e "$FAILED_PKGS"
              exit 1
          fi
      fi
  else
      # 没有指定平台,直接下载
      ${PIP_CMD} download --prefer-binary -r "$REQ_FILE" -d ./wheels \
          --index-url ${PIP_MIRROR_URL} --trusted-host mirrors.aliyun.com
      if [[ $? -ne 0 ]]; then
          echo "✗ Error: Failed to download dependencies"
          exit 1
      fi
  fi

  # Count downloaded packages
  WHEEL_COUNT=$(ls -1 ./wheels/*.whl 2>/dev/null | wc -l)
  SDIST_COUNT=$(ls -1 ./wheels/*.tar.gz ./wheels/*.zip 2>/dev/null | wc -l)
  echo "✓ Downloaded $WHEEL_COUNT wheel packages, $SDIST_COUNT source packages"

   # ============================================
  # Step 3.1: Verify downloaded dependencies
  # ============================================
  echo ""
  echo "=========================================="
  echo "Step 3.1: Verifying downloaded dependencies"
  echo "=========================================="
  
  # 从 RAW_PLATFORM 推导 uv 验证用的平台
  UV_VERIFY_PLATFORM=""
  if [ -n "$RAW_PLATFORM" ]; then
      if echo "$RAW_PLATFORM" | grep -qi 'aarch64\|arm64'; then
          UV_VERIFY_PLATFORM="linux-aarch64"
      elif echo "$RAW_PLATFORM" | grep -qi 'x86_64\|x64\|amd64'; then
          UV_VERIFY_PLATFORM="linux-x86_64"
      fi
  fi
  
  VERIFY_OK=0
  
  # 优先用 uv 验证 (加 --system 和 --python-platform)
  if command -v uv &> /dev/null; then
      echo "Verifying with uv..."
      [ -n "$UV_VERIFY_PLATFORM" ] && echo "Target platform: ${UV_VERIFY_PLATFORM}"
      if uv pip install --system \
          ${UV_VERIFY_PLATFORM:+--python-platform ${UV_VERIFY_PLATFORM}} \
          --no-index --find-links ./wheels -r "$REQ_FILE" --dry-run 2>uv_verify_error.log; then
          echo "✓ All dependencies verified by uv."
          VERIFY_OK=1
      else
          echo "⚠ uv verification failed:"
          cat uv_verify_error.log
      fi
  fi
  
  # uv 不可用或失败时，用文件检查验证
  if [ "$VERIFY_OK" -eq 0 ]; then
      echo "Falling back to pip file-check verification..."
      MISSING_PKGS=""
      while IFS= read -r line || [ -n "$line" ]; do
          line=$(echo "$line" | sed 's/#.*//' | xargs)
          [ -z "$line" ] && continue
          [[ "$line" == --* ]] && continue
          
          # 跳过 Windows 专用包
          if echo "$line" | grep -qi 'sys_platform.*win32'; then
              echo "  ⊘ Skipping (Windows-only): ${line}"
              continue
          fi
          
          # 提取包名 (去掉版本号、extras、markers)
          PKG_NAME=$(echo "$line" | sed 's/\[.*\]//' | sed 's/[<>=!~].*//' | sed 's/;.*//' | xargs | tr '[:upper:]' '[:lower:]')
          [ -z "$PKG_NAME" ] && continue
          PKG_PATTERN=$(echo "$PKG_NAME" | tr '-' '_')
          
          if ! ls ./wheels/ 2>/dev/null | grep -iq "^${PKG_PATTERN}-.*\.\(whl\|tar\.gz\|zip\)"; then
              MISSING_PKGS="${MISSING_PKGS}\n    - ${line}"
          fi
      done < "$REQ_FILE"
      
      if [ -n "$MISSING_PKGS" ]; then
          echo "✗ Missing packages in ./wheels/:"
          echo -e "$MISSING_PKGS"
          exit 1
      else
          echo "✓ All dependencies found in ./wheels/."
          VERIFY_OK=1
      fi
  fi

  # ============================================
  # Step 4: Packaging plugin
  # ============================================
  echo ""
  echo "=========================================="
  echo "Step 4: Packaging plugin"
  echo "=========================================="
  cd ${CURR_DIR} || exit 1
  chmod 755 ${CURR_DIR}/${CMD_NAME}
  OUTPUT_PACKAGE="${CURR_DIR}/${PACKAGE_NAME}-${PACKAGE_SUFFIX}.difypkg"
  echo "Packaging: ${PACKAGE_NAME}"
  echo "Output: ${OUTPUT_PACKAGE}"
  echo "Max size: 5120 MB"
  
  # 使用正确的Python版本执行打包命令
${CURR_DIR}/${CMD_NAME} plugin package ${CURR_DIR}/${PACKAGE_NAME} \
      -o ${OUTPUT_PACKAGE} --max-size 5120
  if [[ $? -ne 0 ]]; then
      echo "✗ Error: Packaging failed"
      exit 1
  fi
  
  # 获取文件大小
  FILE_SIZE=$(du -h "${OUTPUT_PACKAGE}" | cut -f1)
  echo ""
  echo "=========================================="
  echo "✓ Package created successfully!"
  echo "=========================================="
  echo "Location: ${OUTPUT_PACKAGE}"
  echo "Size: ${FILE_SIZE}"
  echo "Platform: ${RAW_PLATFORM:-current}"

	# ============================================
	# Step 5: Package the plugin
	# ============================================
	echo ""
	echo "=========================================="
	echo "Step 4: Packaging plugin"
	echo "=========================================="

	cd ${CURR_DIR} || exit 1
	chmod 755 ${CURR_DIR}/${CMD_NAME}

	OUTPUT_PACKAGE="${CURR_DIR}/${PACKAGE_NAME}-${PACKAGE_SUFFIX}.difypkg"
	echo "Packaging: ${PACKAGE_NAME}"
	echo "Output: ${OUTPUT_PACKAGE}"
	echo "Max size: 5120 MB"

	${CURR_DIR}/${CMD_NAME} plugin package ${CURR_DIR}/${PACKAGE_NAME} \
		-o ${OUTPUT_PACKAGE} --max-size 5120
	if [[ $? -ne 0 ]]; then
		echo "✗ Error: Packaging failed"
		exit 1
	fi

	# Get file size
	FILE_SIZE=$(du -h "${OUTPUT_PACKAGE}" | cut -f1)
	echo ""
	echo "=========================================="
	echo "✓ Package created successfully!"
	echo "=========================================="
	echo "Location: ${OUTPUT_PACKAGE}"
	echo "Size: ${FILE_SIZE}"
	echo "Platform: ${RAW_PLATFORM:-current}"
}

install_unzip(){
	if ! command -v unzip &> /dev/null; then
		echo "Installing unzip ..."
		yum -y install unzip
		if [ $? -ne 0 ]; then
			echo "Install unzip failed."
			exit 1
		fi
	fi
}

print_usage() {
	echo "usage: $0 [-p platform] [-s package_suffix] [-R] {market|github|local}"
	echo "-p platform: python packages' platform. Using for crossing repacking.
        For example: -p manylinux2014_x86_64 or -p manylinux2014_aarch64"
	echo "-s package_suffix: The suffix name of the output offline package.
        For example: -s linux-amd64 or -s linux-arm64"
	echo "-R: allow pre-release versions during uv resolution (maps to --prerelease=allow)"
	exit 1
}

while getopts "p:s:R" opt; do
  case "$opt" in
    p)
      RAW_PLATFORM="${OPTARG}"
      PIP_PLATFORM=""
      IFS=',' read -ra PLATFORMS <<< "$RAW_PLATFORM"
      for p in "${PLATFORMS[@]}"; do
          p=$(echo "$p" | xargs)
          PIP_PLATFORM+=" --platform ${p}"
      done
      ;;
    s) PACKAGE_SUFFIX="${OPTARG}" ;;
    R) PRERELEASE_ALLOW=1 ;;
    *) print_usage; exit 1 ;;
  esac
done


shift $((OPTIND - 1))

echo "$1"
case "$1" in
	'market')
	market $@
	;;
	'github')
	github $@
	;;
	'local')
	_local $@
	;;
	*)

print_usage
exit 1
esac
exit 0
