#!/usr/bin/env zsh
# aytool - Docker build helper

_AYTOOL_DIR="${HOME}/.config/aytool"
_AYTOOL_CONFIG="${_AYTOOL_DIR}/config"
_AYTOOL_PROJECTS="${_AYTOOL_DIR}/projects.conf"

# ── 颜色 ──────────────────────────────────────────────
_C_RESET="\033[0m"
_C_BOLD="\033[1m"
_C_DIM="\033[2m"
_C_GREEN="\033[32m"
_C_YELLOW="\033[33m"
_C_CYAN="\033[36m"
_C_RED="\033[31m"
_C_MAGENTA="\033[35m"

# ── 加载配置 ──────────────────────────────────────────
_aytool_load_config() {
    if [[ ! -f "$_AYTOOL_CONFIG" ]]; then
        echo "${_C_RED}错误: 配置文件不存在 $_AYTOOL_CONFIG${_C_RESET}"
        echo "运行 ${_C_CYAN}aytool init${_C_RESET} 生成默认配置"
        return 1
    fi
    source "$_AYTOOL_CONFIG"
}

# ── 解析项目列表 ─────────────────────────────────────
# 返回: 全局数组 _PROJECTS=( "别名|ENV变量名|镜像名|构建目录|Dockerfile路径" ... )
_aytool_load_projects() {
    _PROJECTS=()
    while IFS= read -r line; do
        # 跳过空行和注释
        [[ -z "$line" || "$line" == \#* ]] && continue
        _PROJECTS+=("$line")
    done < "$_AYTOOL_PROJECTS"
}

# ── 按别名查找项目，返回各字段到全局变量 ────────────
_aytool_find_project() {
    local alias_name="$1"
    for entry in "${_PROJECTS[@]}"; do
        local a="${entry%%|*}"
        if [[ "$a" == "$alias_name" ]]; then
            P_ALIAS="$a"
            local rest="${entry#*|}"
            P_ENV_VAR="${rest%%|*}"
            rest="${rest#*|}"
            P_IMAGE="${rest%%|*}"
            rest="${rest#*|}"
            P_BUILD_DIR="${rest%%|*}"
            P_DOCKERFILE="${rest#*|}"
            # 展开 ~
            P_BUILD_DIR="${P_BUILD_DIR/#\~/$HOME}"
            return 0
        fi
    done
    return 1
}

# ── 从 .env 读取版本 ────────────────────────────────
_aytool_read_version() {
    local var_name="$1"
    local val
    val=$(grep "^${var_name}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2)
    echo "${val:-0}"
}

# ── 更新 .env 版本 ──────────────────────────────────
_aytool_update_version() {
    local var_name="$1"
    local new_ver="$2"
    if grep -q "^${var_name}=" "$ENV_FILE" 2>/dev/null; then
        sed -i '' "s/^${var_name}=.*/${var_name}=${new_ver}/" "$ENV_FILE"
    else
        echo "${var_name}=${new_ver}" >> "$ENV_FILE"
    fi
}

# ── 登录检测 ────────────────────────────────────────
_aytool_login_check() {
    if ! grep -q "$REGISTRY" ~/.docker/config.json 2>/dev/null; then
        echo "${_C_YELLOW}未登录 ${REGISTRY}，正在自动登录...${_C_RESET}"
        echo "$REGISTRY_PASS" | docker login "$REGISTRY" --username="$REGISTRY_USER" --password-stdin
        if [[ $? -ne 0 ]]; then
            echo "${_C_RED}登录失败${_C_RESET}"
            return 1
        fi
        echo "${_C_GREEN}登录成功${_C_RESET}"
    fi
}

# ── import 命令 ──────────────────────────────────────
_aytool_import() {
    local file="$1"

    if [[ -z "$file" ]]; then
        echo "${_C_RED}用法: aytool import <文件路径>${_C_RESET}"
        echo "文件格式:"
        echo "  ${_C_DIM}[config]${_C_RESET}"
        echo "  ${_C_DIM}KEY=VALUE${_C_RESET}"
        echo "  ${_C_DIM}[projects]${_C_RESET}"
        echo "  ${_C_DIM}别名|ENV变量名|镜像名|构建目录|Dockerfile${_C_RESET}"
        return 1
    fi

    # 展开 ~
    file="${file/#\~/$HOME}"

    if [[ ! -f "$file" ]]; then
        echo "${_C_RED}文件不存在: $file${_C_RESET}"
        return 1
    fi

    mkdir -p "$_AYTOOL_DIR"

    local section=""
    local config_lines=()
    local project_lines=()

    while IFS= read -r line; do
        # 去除行首尾空白
        local trimmed="${line## }"
        trimmed="${trimmed%% }"

        # 跳过空行
        [[ -z "$trimmed" ]] && continue

        # 检测 section 标记
        if [[ "$trimmed" == "[config]" ]]; then
            section="config"
            continue
        elif [[ "$trimmed" == "[projects]" ]]; then
            section="projects"
            continue
        fi

        # 按 section 归类
        case "$section" in
            config)   config_lines+=("$trimmed") ;;
            projects) project_lines+=("$trimmed") ;;
        esac
    done < "$file"

    if (( ${#config_lines[@]} == 0 && ${#project_lines[@]} == 0 )); then
        echo "${_C_RED}文件中未找到 [config] 或 [projects] 段${_C_RESET}"
        return 1
    fi

    # 写入 config
    if (( ${#config_lines[@]} > 0 )); then
        printf '%s\n' "${config_lines[@]}" > "$_AYTOOL_CONFIG"
        echo "${_C_GREEN}已导入 config${_C_RESET} (${#config_lines[@]} 行)"
    fi

    # 写入 projects.conf
    if (( ${#project_lines[@]} > 0 )); then
        printf '%s\n' "${project_lines[@]}" > "$_AYTOOL_PROJECTS"
        echo "${_C_GREEN}已导入 projects.conf${_C_RESET} (${#project_lines[@]} 行)"
    fi

    echo ""
    echo "  ${_C_BOLD}导入完成${_C_RESET}"

    # 导入后直接展示 list
    _aytool_list
}

# ── init 命令 ────────────────────────────────────────
_aytool_init() {
    mkdir -p "$_AYTOOL_DIR"

    if [[ ! -f "$_AYTOOL_CONFIG" ]]; then
        cat > "$_AYTOOL_CONFIG" <<'CONF'
REGISTRY=ccr.ccs.tencentyun.com
REGISTRY_USER=your_username
REGISTRY_PASS=your_password
NAMESPACE=your_namespace
PLATFORM=linux/x86_64,linux/arm64/v8
ENV_FILE=/path/to/your/.env
CONF
        echo "${_C_GREEN}已创建配置文件:${_C_RESET} $_AYTOOL_CONFIG"
    else
        echo "${_C_YELLOW}配置文件已存在:${_C_RESET} $_AYTOOL_CONFIG"
    fi

    if [[ ! -f "$_AYTOOL_PROJECTS" ]]; then
        cat > "$_AYTOOL_PROJECTS" <<'CONF'
# 别名|ENV变量名|镜像名|构建目录|Dockerfile相对路径(可选，空=默认Dockerfile)
# 示例:
# myapp|MYAPP_VERSION|myapp_image|~/projects/myapp|
# frontend|FRONTEND_VERSION|frontend_image|~/projects|frontend/Dockerfile
CONF
        echo "${_C_GREEN}已创建项目配置:${_C_RESET} $_AYTOOL_PROJECTS"
    else
        echo "${_C_YELLOW}项目配置已存在:${_C_RESET} $_AYTOOL_PROJECTS"
    fi

    echo ""
    echo "编辑以下文件完成配置:"
    echo "  ${_C_CYAN}$_AYTOOL_CONFIG${_C_RESET}      # Registry 凭据、平台、.env 路径"
    echo "  ${_C_CYAN}$_AYTOOL_PROJECTS${_C_RESET}  # 项目列表"
}

# ── list 命令 ────────────────────────────────────────
_aytool_list() {
    _aytool_load_config || return 1
    _aytool_load_projects

    echo ""
    echo "  ${_C_BOLD}Docker Build Tool${_C_RESET}"
    echo "  ${_C_DIM}──────────────────────────────────────────────────────────────────${_C_RESET}"
    printf "  ${_C_BOLD}%-4s %-10s %-24s %-10s %s${_C_RESET}\n" "#" "别名" "镜像" "版本" "构建目录"
    echo "  ${_C_DIM}──────────────────────────────────────────────────────────────────${_C_RESET}"

    local i=1
    for entry in "${_PROJECTS[@]}"; do
        local a="${entry%%|*}"
        local rest="${entry#*|}"
        local env_var="${rest%%|*}"
        rest="${rest#*|}"
        local image="${rest%%|*}"
        rest="${rest#*|}"
        local build_dir="${rest%%|*}"

        local ver=$(_aytool_read_version "$env_var")
        printf "  %-4s ${_C_CYAN}%-10s${_C_RESET} %-24s ${_C_GREEN}v%-9s${_C_RESET} %s\n" "$i" "$a" "$image" "$ver" "$build_dir"
        ((i++))
    done
    echo "  ${_C_DIM}──────────────────────────────────────────────────────────────────${_C_RESET}"
    echo ""
}

# ── pull 命令 ────────────────────────────────────────
_aytool_pull() {
    local alias_name="$1"
    _aytool_load_config || return 1
    _aytool_load_projects

    if [[ -z "$alias_name" ]]; then
        echo "${_C_RED}用法: aytool pull <别名>${_C_RESET}"
        return 1
    fi

    if ! _aytool_find_project "$alias_name"; then
        echo "${_C_RED}未找到项目: $alias_name${_C_RESET}"
        return 1
    fi

    local ver=$(_aytool_read_version "$P_ENV_VAR")
    local full_image="${REGISTRY}/${NAMESPACE}/${P_IMAGE}:${ver}"

    echo ""
    echo "  ${_C_BOLD}Pull 命令:${_C_RESET}"
    echo ""
    echo "  ${_C_CYAN}docker pull ${full_image}${_C_RESET}"
    echo ""
}

# ── build 交互选择 ──────────────────────────────────
_aytool_build_interactive() {
    _aytool_list

    local input
    printf "  选择项目 (别名或序号): "
    read input

    if [[ -z "$input" ]]; then
        echo "${_C_RED}已取消${_C_RESET}"
        return 1
    fi

    # 如果是数字，转换为别名
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        local idx=$input
        if (( idx < 1 || idx > ${#_PROJECTS[@]} )); then
            echo "${_C_RED}序号超出范围${_C_RESET}"
            return 1
        fi
        local entry="${_PROJECTS[$idx]}"
        input="${entry%%|*}"
    fi

    _aytool_build "$input"
}

# ── build 命令 ───────────────────────────────────────
_aytool_build() {
    local alias_name="$1"
    local manual_ver="$2"

    _aytool_load_config || return 1
    _aytool_load_projects

    # 无参数 → 交互模式
    if [[ -z "$alias_name" ]]; then
        _aytool_build_interactive
        return $?
    fi

    # 登录检测
    _aytool_login_check || return 1

    # 查找项目
    if ! _aytool_find_project "$alias_name"; then
        echo "${_C_RED}未找到项目: $alias_name${_C_RESET}"
        return 1
    fi

    # 版本计算
    local cur_ver=$(_aytool_read_version "$P_ENV_VAR")
    local new_ver
    if [[ -n "$manual_ver" ]]; then
        new_ver="$manual_ver"
    else
        new_ver=$((cur_ver + 1))
    fi

    local full_image="${REGISTRY}/${NAMESPACE}/${P_IMAGE}:${new_ver}"

    # Dockerfile 参数
    local dockerfile_arg=""
    if [[ -n "$P_DOCKERFILE" ]]; then
        dockerfile_arg="-f ${P_BUILD_DIR}/${P_DOCKERFILE}"
    fi

    # 确认面板
    echo ""
    echo "  ${_C_DIM}───────────────────────────────────────────${_C_RESET}"
    echo "  ${_C_BOLD}项目:${_C_RESET}  ${_C_CYAN}${P_IMAGE}${_C_RESET}"
    echo "  ${_C_BOLD}目录:${_C_RESET}  ${P_BUILD_DIR}"
    if [[ -n "$P_DOCKERFILE" ]]; then
        echo "  ${_C_BOLD}文件:${_C_RESET}  ${P_DOCKERFILE}"
    fi
    echo "  ${_C_BOLD}版本:${_C_RESET}  ${_C_YELLOW}v${cur_ver}${_C_RESET} → ${_C_GREEN}v${new_ver}${_C_RESET}"
    echo "  ${_C_BOLD}镜像:${_C_RESET}  ${full_image}"
    echo "  ${_C_BOLD}平台:${_C_RESET}  ${PLATFORM}"
    echo "  ${_C_DIM}───────────────────────────────────────────${_C_RESET}"
    echo ""

    local confirm
    printf "  确认构建? [Y/n] "
    read confirm
    if [[ "$confirm" =~ ^[nN] ]]; then
        echo "${_C_YELLOW}已取消${_C_RESET}"
        return 0
    fi

    echo ""
    echo "  ${_C_MAGENTA}开始构建...${_C_RESET}"
    echo ""

    # 构建命令
    local cmd="docker buildx build --platform ${PLATFORM} --push -t ${full_image}"
    if [[ -n "$P_DOCKERFILE" ]]; then
        cmd="${cmd} -f ${P_BUILD_DIR}/${P_DOCKERFILE}"
    fi
    cmd="${cmd} ${P_BUILD_DIR}"

    echo "  ${_C_DIM}$ ${cmd}${_C_RESET}"
    echo ""

    eval "$cmd"

    if [[ $? -ne 0 ]]; then
        echo ""
        echo "  ${_C_RED}构建失败${_C_RESET}"
        return 1
    fi

    # 更新 .env
    _aytool_update_version "$P_ENV_VAR" "$new_ver"

    echo ""
    echo "  ${_C_GREEN}构建成功!${_C_RESET}"
    echo "  ${_C_DIM}───────────────────────────────────────────${_C_RESET}"
    echo "  ${_C_BOLD}版本已更新:${_C_RESET} ${P_ENV_VAR}=${new_ver}"
    echo "  ${_C_BOLD}Pull 命令:${_C_RESET}  ${_C_CYAN}docker pull ${full_image}${_C_RESET}"
    echo "  ${_C_DIM}───────────────────────────────────────────${_C_RESET}"
    echo ""
}

# ── 主入口 ───────────────────────────────────────────
aytool() {
    local subcmd="$1"
    shift 2>/dev/null

    case "$subcmd" in
        build)
            _aytool_build "$@"
            ;;
        list|ls)
            _aytool_list
            ;;
        pull)
            _aytool_pull "$@"
            ;;
        init)
            _aytool_init
            ;;
        import)
            _aytool_import "$@"
            ;;
        help|--help|-h|"")
            echo ""
            echo "  ${_C_BOLD}aytool${_C_RESET} - Docker 构建工具"
            echo ""
            echo "  ${_C_BOLD}用法:${_C_RESET}"
            echo "    aytool init                 生成默认配置文件"
            echo "    aytool import <文件>        从文件导入配置"
            echo "    aytool build                交互选择项目构建"
            echo "    aytool build <别名>         自动版本+1构建"
            echo "    aytool build <别名> <版本>   指定版本构建"
            echo "    aytool list                 列出所有项目+版本"
            echo "    aytool pull <别名>          输出 pull 命令"
            echo "    aytool help                 显示帮助"
            echo ""
            ;;
        *)
            echo "${_C_RED}未知命令: $subcmd${_C_RESET}"
            echo "运行 ${_C_CYAN}aytool help${_C_RESET} 查看帮助"
            return 1
            ;;
    esac
}
