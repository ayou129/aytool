#!/usr/bin/env zsh
# aytool - Docker build helper

_AYTOOL_VERSION="3.2.0"
_AYTOOL_REPO_RAW="https://raw.githubusercontent.com/ayou129/aytool/master"
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
            rest="${rest#*|}"
            P_DOCKERFILE="${rest%%|*}"
            P_BUILD_CONTEXTS="${rest#*|}"
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
    val=$(grep "^${var_name}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '\r')
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
    echo "  ${_C_BOLD}Docker Build Tool${_C_RESET} ${_C_DIM}v${_AYTOOL_VERSION}${_C_RESET}"
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

# ── 交互选择器 (↑↓选择 Enter确认 q/Esc取消) ────────
_aytool_select_project() {
    local total=${#_PROJECTS[@]}
    if (( total == 0 )); then
        echo "  ${_C_RED}没有配置任何项目${_C_RESET}"
        return 1
    fi

    local selected=1
    local key

    # 绘制菜单
    _aytool_draw_menu() {
        local redraw=$1
        # 重绘时光标上移
        if (( redraw )); then
            printf "\033[${total}A"
        fi

        local i
        for (( i=1; i<=total; i++ )); do
            local entry="${_PROJECTS[$i]}"
            local a="${entry%%|*}"
            local rest="${entry#*|}"
            local env_var="${rest%%|*}"
            rest="${rest#*|}"
            local image="${rest%%|*}"
            local ver=$(_aytool_read_version "$env_var")

            # 清行并绘制
            printf "\033[2K"
            if (( i == selected )); then
                printf "  ${_C_GREEN}▸${_C_RESET} ${_C_BOLD}%-8s${_C_RESET}  %-20s  ${_C_GREEN}v%s${_C_RESET}\n" "$a" "$image" "$ver"
            else
                printf "    ${_C_DIM}%-8s  %-20s  v%s${_C_RESET}\n" "$a" "$image" "$ver"
            fi
        done
    }

    echo ""
    echo "  ${_C_BOLD}选择项目${_C_RESET} ${_C_DIM}(↑↓ 选择  Enter 确认  q 取消)${_C_RESET}"
    echo ""

    # 隐藏光标
    printf "\033[?25l"

    _aytool_draw_menu 0

    while true; do
        # 读取单个按键
        read -rsk1 key 2>/dev/null
        case "$key" in
            $'\e')
                # 读取转义序列
                read -rsk1 -t 0.1 key 2>/dev/null
                if [[ "$key" == "[" ]]; then
                    read -rsk1 -t 0.1 key 2>/dev/null
                    case "$key" in
                        A) (( selected > 1 )) && ((selected--)) ;;     # ↑
                        B) (( selected < total )) && ((selected++)) ;;  # ↓
                    esac
                else
                    # 单独 Esc 键
                    printf "\033[?25h"
                    echo ""
                    echo "  ${_C_YELLOW}已取消${_C_RESET}"
                    _SELECTED_ALIAS=""
                    return 1
                fi
                ;;
            $'\n'|$'\r')
                # Enter 确认
                printf "\033[?25h"
                echo ""
                local entry="${_PROJECTS[$selected]}"
                _SELECTED_ALIAS="${entry%%|*}"
                return 0
                ;;
            q|Q)
                printf "\033[?25h"
                echo ""
                echo "  ${_C_YELLOW}已取消${_C_RESET}"
                _SELECTED_ALIAS=""
                return 1
                ;;
            k) (( selected > 1 )) && ((selected--)) ;;     # vim 上
            j) (( selected < total )) && ((selected++)) ;;  # vim 下
        esac

        _aytool_draw_menu 1
    done
}

# ── build 交互选择 ──────────────────────────────────
_aytool_build_interactive() {
    _aytool_select_project || return 1
    _aytool_build "$_SELECTED_ALIAS"
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

    printf "  确认构建? [Y/n] "
    read -rsk1 confirm 2>/dev/null
    echo ""
    if [[ "$confirm" =~ ^[nN] ]]; then
        echo "  ${_C_YELLOW}已取消${_C_RESET}"
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
    # 额外构建上下文（逗号分隔，如 shared-core=~/path）
    if [[ -n "$P_BUILD_CONTEXTS" ]]; then
        local IFS=','
        for ctx in ${=P_BUILD_CONTEXTS}; do
            # 展开值部分的 ~
            local ctx_name="${ctx%%=*}"
            local ctx_path="${ctx#*=}"
            ctx_path="${ctx_path/#\~/$HOME}"
            cmd="${cmd} --build-context ${ctx_name}=${ctx_path}"
        done
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

# ── 版本比较 (返回 0 表示 v1 > v2) ──────────────────
_aytool_version_gt() {
    local v1="$1" v2="$2"
    local -a a=(${(s/./)v1}) b=(${(s/./)v2})
    local i
    for ((i=1; i<=${#a[@]} || i<=${#b[@]}; i++)); do
        local n1=${a[i]:-0} n2=${b[i]:-0}
        (( n1 > n2 )) && return 0
        (( n1 < n2 )) && return 1
    done
    return 1
}

# ── 后台检查更新 (source 时调用，结果写文件) ──────────
_aytool_check_update_bg() {
    local notice_file="${_AYTOOL_DIR}/update_notice"

    mkdir -p "$_AYTOOL_DIR"

    # 每次命令都检查远程版本 (超时 3 秒)
    local remote_ver
    remote_ver=$(curl -fsSL --connect-timeout 3 --max-time 5 \
        "${_AYTOOL_REPO_RAW}/aytool.zsh" 2>/dev/null \
        | grep '^_AYTOOL_VERSION=' | head -1 | cut -d'"' -f2)

    [[ -z "$remote_ver" ]] && return 0

    if _aytool_version_gt "$remote_ver" "$_AYTOOL_VERSION"; then
        echo "$remote_ver" > "$notice_file"
    else
        rm -f "$notice_file"
    fi
}

# ── 展示更新提示 (命令执行时调用) ────────────────────
_aytool_show_update_notice() {
    local notice_file="${_AYTOOL_DIR}/update_notice"
    if [[ -f "$notice_file" ]]; then
        local remote_ver=$(<"$notice_file")
        echo ""
        echo "  ${_C_YELLOW}[aytool] 新版本 v${remote_ver} 可用 (当前 v${_AYTOOL_VERSION})${_C_RESET}"
        echo "  运行 ${_C_CYAN}aytool update${_C_RESET} 更新"
        rm -f "$notice_file"
    fi
}

# ── update 命令 ────────────────────────────────────
_aytool_update() {
    local install_path="${_AYTOOL_DIR}/aytool.zsh"
    local old_ver="$_AYTOOL_VERSION"

    echo ""
    echo "  ${_C_BOLD}检查更新...${_C_RESET}"

    local tmp_file=$(mktemp)
    if ! curl -fsSL --connect-timeout 5 --max-time 30 \
        "${_AYTOOL_REPO_RAW}/aytool.zsh" -o "$tmp_file" 2>/dev/null; then
        rm -f "$tmp_file"
        echo "  ${_C_RED}下载失败，请检查网络连接${_C_RESET}"
        return 1
    fi

    local new_ver
    new_ver=$(grep '^_AYTOOL_VERSION=' "$tmp_file" | head -1 | cut -d'"' -f2)

    if [[ -z "$new_ver" ]]; then
        rm -f "$tmp_file"
        echo "  ${_C_RED}下载文件异常，请稍后重试${_C_RESET}"
        return 1
    fi

    if [[ "$new_ver" == "$old_ver" ]]; then
        rm -f "$tmp_file"
        echo "  ${_C_GREEN}已是最新版本 v${old_ver}${_C_RESET}"
        echo ""
        return 0
    fi

    mv "$tmp_file" "$install_path"

    # 更新检查时间 & 清除更新提示
    echo "$(date +%s)" > "${_AYTOOL_DIR}/last_update_check"
    rm -f "${_AYTOOL_DIR}/update_notice"

    echo "  ${_C_GREEN}更新成功!${_C_RESET} ${_C_YELLOW}v${old_ver}${_C_RESET} → ${_C_GREEN}v${new_ver}${_C_RESET}"
    echo ""

    # 自动加载新版本
    source "$install_path"
    echo "  已自动加载新版本 ${_C_GREEN}v${_AYTOOL_VERSION}${_C_RESET}"
    echo ""
}

# ── version 命令 ───────────────────────────────────
_aytool_version() {
    echo "aytool v${_AYTOOL_VERSION}"
}

# ── 保存配置 ────────────────────────────────────────
_aytool_save_config() {
    cat > "$_AYTOOL_CONFIG" <<CONF
REGISTRY=${REGISTRY}
REGISTRY_USER=${REGISTRY_USER}
REGISTRY_PASS=${REGISTRY_PASS}
NAMESPACE=${NAMESPACE}
PLATFORM=${PLATFORM}
ENV_FILE=${ENV_FILE}
CONF
}

# ── 平台多选 (Space切换 Enter确认) ──────────────────
_aytool_multi_select_platform() {
    # 预置平台选项
    local -a options=("linux/x86_64" "linux/arm64/v8" "自定义...")
    local total=${#options[@]}
    local selected=1
    local key

    # 根据当前 PLATFORM 初始化选中状态 (1=选中 0=未选中)
    local -a checked=(0 0 0)
    local IFS=','
    for p in ${=PLATFORM}; do
        case "$p" in
            linux/x86_64)    checked[1]=1 ;;
            linux/arm64/v8)  checked[2]=1 ;;
            *)               checked[3]=1 ;;
        esac
    done

    _draw_platform_menu() {
        local redraw=$1
        if (( redraw )); then
            printf "\033[${total}A"
        fi

        local i
        for (( i=1; i<=total; i++ )); do
            printf "\033[2K"
            local mark=" "
            (( checked[i] )) && mark="✓"

            if (( i == selected )); then
                printf "  ${_C_GREEN}▸${_C_RESET} [${_C_GREEN}%s${_C_RESET}] ${_C_BOLD}%s${_C_RESET}\n" "$mark" "${options[$i]}"
            else
                printf "    ${_C_DIM}[%s] %s${_C_RESET}\n" "$mark" "${options[$i]}"
            fi
        done
    }

    echo ""
    echo "  ${_C_BOLD}选择构建平台${_C_RESET} ${_C_DIM}(↑↓ 移动  Space 切换  Enter 确认  q 取消)${_C_RESET}"
    echo ""

    printf "\033[?25l"
    _draw_platform_menu 0

    while true; do
        read -rsk1 key 2>/dev/null
        case "$key" in
            $'\e')
                read -rsk1 -t 0.1 key 2>/dev/null
                if [[ "$key" == "[" ]]; then
                    read -rsk1 -t 0.1 key 2>/dev/null
                    case "$key" in
                        A) (( selected > 1 )) && ((selected--)) ;;
                        B) (( selected < total )) && ((selected++)) ;;
                    esac
                else
                    printf "\033[?25h"
                    echo ""
                    echo "  ${_C_YELLOW}已取消${_C_RESET}"
                    return 1
                fi
                ;;
            " ")
                # Space 切换选中
                (( checked[selected] = !checked[selected] ))
                ;;
            $'\n'|$'\r')
                # 检查至少选一项（自定义单独不算，除非有输入）
                local has_selection=0
                (( checked[1] )) && has_selection=1
                (( checked[2] )) && has_selection=1
                (( checked[3] )) && has_selection=1

                if (( !has_selection )); then
                    # 提示至少选一项，不退出
                    printf "\033[1A\033[2K"
                    printf "  ${_C_RED}至少选择一个平台${_C_RESET}\n"
                    # 重绘
                    _draw_platform_menu 0
                    continue
                fi

                printf "\033[?25h"
                echo ""

                # 组装结果
                local result=""
                (( checked[1] )) && result="linux/x86_64"
                (( checked[2] )) && { [[ -n "$result" ]] && result="${result},"; result="${result}linux/arm64/v8"; }

                # 自定义输入
                if (( checked[3] )); then
                    printf "  ${_C_BOLD}输入自定义平台${_C_RESET} ${_C_DIM}(例: linux/s390x)${_C_RESET}: "
                    printf "\033[?25h"
                    local custom_val
                    read -r custom_val
                    if [[ -n "$custom_val" ]]; then
                        [[ -n "$result" ]] && result="${result},"
                        result="${result}${custom_val}"
                    fi
                fi

                if [[ -z "$result" ]]; then
                    echo "  ${_C_RED}未选择任何平台${_C_RESET}"
                    return 1
                fi

                PLATFORM="$result"
                return 0
                ;;
            q|Q)
                printf "\033[?25h"
                echo ""
                echo "  ${_C_YELLOW}已取消${_C_RESET}"
                return 1
                ;;
            k) (( selected > 1 )) && ((selected--)) ;;
            j) (( selected < total )) && ((selected++)) ;;
        esac

        _draw_platform_menu 1
    done
}

# ── config 命令 ──────────────────────────────────────
_aytool_config() {
    _aytool_load_config || return 1

    # 字段定义: name|display_name|example
    local -a fields=(
        "REGISTRY|Registry 地址|例: ccr.ccs.tencentyun.com"
        "REGISTRY_USER|Registry 用户名|例: your_username"
        "REGISTRY_PASS|Registry 密码|例: your_password"
        "NAMESPACE|命名空间|例: my-namespace"
        "PLATFORM|构建平台|多选"
        "ENV_FILE|.env 文件路径|例: /home/user/.env"
    )
    local total=${#fields[@]}

    while true; do
        local selected=1
        local key

        _draw_config_menu() {
            local redraw=$1
            if (( redraw )); then
                printf "\033[${total}A"
            fi

            local i
            for (( i=1; i<=total; i++ )); do
                local entry="${fields[$i]}"
                local fname="${entry%%|*}"
                local rest="${entry#*|}"
                local display="${rest%%|*}"

                # 获取当前值
                local val="${(P)fname}"
                # 密码字段脱敏
                if [[ "$fname" == "REGISTRY_PASS" && -n "$val" && "$val" != "your_password" ]]; then
                    val="******"
                fi

                printf "\033[2K"
                if (( i == selected )); then
                    printf "  ${_C_GREEN}▸${_C_RESET} ${_C_BOLD}%-16s${_C_RESET} ${_C_CYAN}%s${_C_RESET}\n" "$display" "$val"
                else
                    printf "    ${_C_DIM}%-16s %s${_C_RESET}\n" "$display" "$val"
                fi
            done
        }

        echo ""
        echo "  ${_C_BOLD}配置编辑器${_C_RESET} ${_C_DIM}(↑↓ 选择  Enter 编辑  q 退出)${_C_RESET}"
        echo ""

        printf "\033[?25l"
        _draw_config_menu 0

        local done_editing=0
        while true; do
            read -rsk1 key 2>/dev/null
            case "$key" in
                $'\e')
                    read -rsk1 -t 0.1 key 2>/dev/null
                    if [[ "$key" == "[" ]]; then
                        read -rsk1 -t 0.1 key 2>/dev/null
                        case "$key" in
                            A) (( selected > 1 )) && ((selected--)) ;;
                            B) (( selected < total )) && ((selected++)) ;;
                        esac
                    else
                        printf "\033[?25h"
                        echo ""
                        return 0
                    fi
                    ;;
                $'\n'|$'\r')
                    printf "\033[?25h"
                    echo ""

                    local entry="${fields[$selected]}"
                    local fname="${entry%%|*}"
                    local rest="${entry#*|}"
                    local display="${rest%%|*}"
                    local example="${rest#*|}"

                    if [[ "$fname" == "PLATFORM" ]]; then
                        # 平台多选
                        if _aytool_multi_select_platform; then
                            _aytool_save_config
                            echo "  ${_C_GREEN}已保存${_C_RESET} PLATFORM=${PLATFORM}"
                        fi
                    else
                        # 文本输入
                        local cur_val="${(P)fname}"
                        echo "  ${_C_BOLD}${display}${_C_RESET}"
                        if [[ "$fname" == "REGISTRY_PASS" ]]; then
                            echo "  ${_C_DIM}当前值: ******${_C_RESET}"
                        else
                            echo "  ${_C_DIM}当前值: ${cur_val}${_C_RESET}"
                        fi
                        printf "  ${_C_DIM}${example}${_C_RESET}\n"
                        printf "  ${_C_DIM}(空回车保持不变)${_C_RESET}\n"
                        printf "  新值: "
                        local new_val
                        read -r new_val
                        if [[ -n "$new_val" ]]; then
                            eval "${fname}=\"\${new_val}\""
                            _aytool_save_config
                            echo "  ${_C_GREEN}已保存${_C_RESET} ${fname}=${new_val}"
                        else
                            echo "  ${_C_DIM}未修改${_C_RESET}"
                        fi
                    fi

                    # 编辑完一个字段后回到菜单
                    done_editing=1
                    break
                    ;;
                q|Q)
                    printf "\033[?25h"
                    echo ""
                    return 0
                    ;;
                k) (( selected > 1 )) && ((selected--)) ;;
                j) (( selected < total )) && ((selected++)) ;;
            esac

            _draw_config_menu 1
        done

        # 编辑完一个字段后继续显示菜单
        (( done_editing )) && continue
    done
}

# ── 主入口 ───────────────────────────────────────────
aytool() {
    local subcmd="$1"
    shift 2>/dev/null

    # 展示更新提示（如果有）
    _aytool_show_update_notice

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
        config)
            _aytool_config
            ;;
        update)
            _aytool_update
            ;;
        version|--version|-v)
            _aytool_version
            ;;
        help|--help|-h|"")
            echo ""
            echo "  ${_C_BOLD}aytool${_C_RESET} - Docker 构建工具 ${_C_DIM}v${_AYTOOL_VERSION}${_C_RESET}"
            echo ""
            echo "  ${_C_BOLD}用法:${_C_RESET}"
            echo "    aytool init                 生成默认配置文件"
            echo "    aytool import <文件>        从文件导入配置"
            echo "    aytool config               交互式编辑配置"
            echo "    aytool build                交互选择项目构建"
            echo "    aytool build <别名>         自动版本+1构建"
            echo "    aytool build <别名> <版本>   指定版本构建"
            echo "    aytool list|ls              列出所有项目+版本"
            echo "    aytool pull <别名>          输出 pull 命令"
            echo "    aytool update               检查并更新到最新版本"
            echo "    aytool version              显示当前版本"
            echo "    aytool help                 显示帮助"
            echo ""
            echo "  ${_C_DIM}https://github.com/ayou129/aytool${_C_RESET}"
            echo ""
            ;;
        *)
            echo "${_C_RED}未知命令: ${subcmd}${_C_RESET}"
            echo "运行 ${_C_BOLD}aytool help${_C_RESET} 查看可用命令"
            return 1
            ;;
    esac

    # 命令执行后异步检查更新
    () {
        setopt LOCAL_OPTIONS NO_MONITOR
        _aytool_check_update_bg &>/dev/null &
        disown 2>/dev/null
    }
}
