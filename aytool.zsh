#!/usr/bin/env zsh
# aytool - Docker build helper

_AYTOOL_VERSION="4.0.2"
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

# ══════════════════════════════════════════════════════
# 核心：项目解析 / 序列化
# ══════════════════════════════════════════════════════

# 解析一行项目配置 → 全局变量 _P_*
# 格式: 别名|ENV变量名|镜像名|构建目录|Dockerfile路径|构建上下文
_aytool_parse_project() {
    local line="$1"
    _P_ALIAS="${line%%|*}"
    local rest="${line#*|}"
    _P_ENV_VAR="${rest%%|*}"
    rest="${rest#*|}"
    _P_IMAGE="${rest%%|*}"
    rest="${rest#*|}"
    _P_BUILD_DIR="${rest%%|*}"
    rest="${rest#*|}"
    _P_DOCKERFILE="${rest%%|*}"
    _P_BUILD_CONTEXTS="${rest#*|}"
    _P_BUILD_DIR="${_P_BUILD_DIR/#\~/$HOME}"
}

# 序列化 _P_* → 管道分隔行
_aytool_serialize_project() {
    local dir="${_P_BUILD_DIR/#$HOME/~}"
    echo "${_P_ALIAS}|${_P_ENV_VAR}|${_P_IMAGE}|${dir}|${_P_DOCKERFILE}|${_P_BUILD_CONTEXTS}"
}

# ══════════════════════════════════════════════════════
# 核心：数据访问
# ══════════════════════════════════════════════════════

_aytool_load_config() {
    if [[ ! -f "$_AYTOOL_CONFIG" ]]; then
        echo "${_C_RED}错误: 配置文件不存在 $_AYTOOL_CONFIG${_C_RESET}"
        echo "运行 ${_C_CYAN}aytool init${_C_RESET} 生成默认配置"
        return 1
    fi
    source "$_AYTOOL_CONFIG"
}

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

_aytool_load_projects() {
    _PROJECTS=()
    [[ ! -f "$_AYTOOL_PROJECTS" ]] && return
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        _PROJECTS+=("$line")
    done < "$_AYTOOL_PROJECTS"
}

_aytool_save_projects() {
    printf '%s\n' "${_PROJECTS[@]}" > "$_AYTOOL_PROJECTS"
}

_aytool_find_project() {
    local alias_name="$1"
    for entry in "${_PROJECTS[@]}"; do
        _aytool_parse_project "$entry"
        [[ "$_P_ALIAS" == "$alias_name" ]] && return 0
    done
    return 1
}

_aytool_read_version() {
    local var_name="$1"
    local val
    val=$(grep "^${var_name}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '\r')
    echo "${val:-0}"
}

_aytool_update_version() {
    local var_name="$1" new_ver="$2"
    if grep -q "^${var_name}=" "$ENV_FILE" 2>/dev/null; then
        sed -i '' "s/^${var_name}=.*/${var_name}=${new_ver}/" "$ENV_FILE"
    else
        echo "${var_name}=${new_ver}" >> "$ENV_FILE"
    fi
}

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

# ══════════════════════════════════════════════════════
# 核心：TUI 通用选择器
# 参数: $1=总数 $2=渲染回调(接收 selected is_redraw)
# 返回: 选中索引存入 _TUI_SELECTED，取消返回 1
# ══════════════════════════════════════════════════════

_aytool_tui_select() {
    local total=$1 render_fn=$2

    if (( total == 0 )); then
        echo "  ${_C_RED}没有可选项${_C_RESET}"
        return 1
    fi

    local selected=1 key

    printf "\033[?25l"
    $render_fn $selected 0

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
            $'\n'|$'\r')
                printf "\033[?25h"
                echo ""
                _TUI_SELECTED=$selected
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
        $render_fn $selected 1
    done
}

# ══════════════════════════════════════════════════════
# TUI 渲染器（策略：每种列表一个渲染回调）
# ══════════════════════════════════════════════════════

_aytool_render_projects() {
    local selected=$1 redraw=$2
    local total=${#_PROJECTS[@]}
    (( redraw )) && printf "\033[${total}A"

    local i
    for (( i=1; i<=total; i++ )); do
        _aytool_parse_project "${_PROJECTS[$i]}"
        local ver=$(_aytool_read_version "$_P_ENV_VAR")
        printf "\033[2K"
        if (( i == selected )); then
            printf "  ${_C_GREEN}▸${_C_RESET} ${_C_BOLD}%-8s${_C_RESET}  %-20s  ${_C_GREEN}v%s${_C_RESET}\n" "$_P_ALIAS" "$_P_IMAGE" "$ver"
        else
            printf "    ${_C_DIM}%-8s  %-20s  v%s${_C_RESET}\n" "$_P_ALIAS" "$_P_IMAGE" "$ver"
        fi
    done
}

_aytool_render_config_fields() {
    local selected=$1 redraw=$2
    local total=${#_CONFIG_FIELDS[@]}
    (( redraw )) && printf "\033[${total}A"

    local i
    for (( i=1; i<=total; i++ )); do
        local entry="${_CONFIG_FIELDS[$i]}"
        local fname="${entry%%|*}"
        local display="${${entry#*|}%%|*}"
        local val="${(P)fname}"
        [[ "$fname" == "REGISTRY_PASS" && -n "$val" && "$val" != "your_password" ]] && val="******"

        printf "\033[2K"
        if (( i == selected )); then
            printf "  ${_C_GREEN}▸${_C_RESET} ${_C_BOLD}%-16s${_C_RESET} ${_C_CYAN}%s${_C_RESET}\n" "$display" "$val"
        else
            printf "    ${_C_DIM}%-16s %s${_C_RESET}\n" "$display" "$val"
        fi
    done
}

_aytool_render_edit_fields() {
    local selected=$1 redraw=$2
    local total=${#_EDIT_FIELDS[@]}
    (( redraw )) && printf "\033[${total}A"

    local i
    for (( i=1; i<=total; i++ )); do
        local entry="${_EDIT_FIELDS[$i]}"
        local fname="${entry%%|*}"
        local display="${${entry#*|}%%|*}"
        local val="${(P)fname}"

        printf "\033[2K"
        if (( i == selected )); then
            if [[ -z "$val" ]]; then
                printf "  ${_C_GREEN}▸${_C_RESET} ${_C_BOLD}%-12s${_C_RESET} ${_C_DIM}(空)${_C_RESET}\n" "$display"
            else
                printf "  ${_C_GREEN}▸${_C_RESET} ${_C_BOLD}%-12s${_C_RESET} ${_C_CYAN}%s${_C_RESET}\n" "$display" "$val"
            fi
        else
            if [[ -z "$val" ]]; then
                printf "    ${_C_DIM}%-12s (空)${_C_RESET}\n" "$display"
            else
                printf "    ${_C_DIM}%-12s %s${_C_RESET}\n" "$display" "$val"
            fi
        fi
    done
}

_aytool_render_platforms() {
    local selected=$1 redraw=$2
    local total=${#_PLATFORM_OPTIONS[@]}
    (( redraw )) && printf "\033[${total}A"

    local i
    for (( i=1; i<=total; i++ )); do
        local mark=" "
        (( _PLATFORM_CHECKED[i] )) && mark="✓"
        printf "\033[2K"
        if (( i == selected )); then
            printf "  ${_C_GREEN}▸${_C_RESET} [${_C_GREEN}%s${_C_RESET}] ${_C_BOLD}%s${_C_RESET}\n" "$mark" "${_PLATFORM_OPTIONS[$i]}"
        else
            printf "    ${_C_DIM}[%s] %s${_C_RESET}\n" "$mark" "${_PLATFORM_OPTIONS[$i]}"
        fi
    done
}

# ══════════════════════════════════════════════════════
# 平台多选（Space 切换，不能复用 tui_select）
# ══════════════════════════════════════════════════════

_aytool_multi_select_platform() {
    _PLATFORM_OPTIONS=("linux/x86_64" "linux/arm64/v8" "自定义...")
    local total=${#_PLATFORM_OPTIONS[@]}
    local selected=1 key

    _PLATFORM_CHECKED=(0 0 0)
    local IFS=','
    for p in ${=PLATFORM}; do
        case "$p" in
            linux/x86_64)    _PLATFORM_CHECKED[1]=1 ;;
            linux/arm64/v8)  _PLATFORM_CHECKED[2]=1 ;;
            *)               _PLATFORM_CHECKED[3]=1 ;;
        esac
    done

    echo ""
    echo "  ${_C_BOLD}选择构建平台${_C_RESET} ${_C_DIM}(↑↓ 移动  Space 切换  Enter 确认  q 取消)${_C_RESET}"
    echo ""

    printf "\033[?25l"
    _aytool_render_platforms $selected 0

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
                    printf "\033[?25h"; echo ""
                    echo "  ${_C_YELLOW}已取消${_C_RESET}"
                    return 1
                fi
                ;;
            " ") (( _PLATFORM_CHECKED[selected] = !_PLATFORM_CHECKED[selected] )) ;;
            $'\n'|$'\r')
                local has=0
                local i
                for (( i=1; i<=total; i++ )); do (( _PLATFORM_CHECKED[i] )) && has=1; done
                if (( !has )); then
                    printf "\033[1A\033[2K"
                    printf "  ${_C_RED}至少选择一个平台${_C_RESET}\n"
                    _aytool_render_platforms $selected 0
                    continue
                fi
                printf "\033[?25h"; echo ""
                local result=""
                (( _PLATFORM_CHECKED[1] )) && result="linux/x86_64"
                (( _PLATFORM_CHECKED[2] )) && { [[ -n "$result" ]] && result="${result},"; result="${result}linux/arm64/v8"; }
                if (( _PLATFORM_CHECKED[3] )); then
                    printf "  ${_C_BOLD}输入自定义平台${_C_RESET} ${_C_DIM}(例: linux/s390x)${_C_RESET}: "
                    printf "\033[?25h"
                    local custom_val; read -r custom_val
                    [[ -n "$custom_val" ]] && { [[ -n "$result" ]] && result="${result},"; result="${result}${custom_val}"; }
                fi
                [[ -z "$result" ]] && { echo "  ${_C_RED}未选择任何平台${_C_RESET}"; return 1; }
                PLATFORM="$result"
                return 0
                ;;
            q|Q) printf "\033[?25h"; echo ""; echo "  ${_C_YELLOW}已取消${_C_RESET}"; return 1 ;;
            k) (( selected > 1 )) && ((selected--)) ;;
            j) (( selected < total )) && ((selected++)) ;;
        esac
        _aytool_render_platforms $selected 1
    done
}

# ══════════════════════════════════════════════════════
# 通用字段编辑器（模板方法：选择字段 → 编辑 → 保存）
# 参数: $1=字段数组名 $2=渲染回调 $3=保存回调 $4=标题
# 字段数组格式: "变量名|显示名|提示"
# ══════════════════════════════════════════════════════

_aytool_edit_fields() {
    local fields_var=$1 render_fn=$2 save_fn=$3 title=$4
    local total
    eval "total=\${#${fields_var}[@]}"

    while true; do
        echo ""
        echo "  ${_C_BOLD}${title}${_C_RESET} ${_C_DIM}(↑↓ 选择  Enter 编辑  q 返回)${_C_RESET}"
        echo ""

        _aytool_tui_select $total $render_fn || return 0

        local entry
        eval "entry=\"\${${fields_var}[$_TUI_SELECTED]}\""
        local fname="${entry%%|*}"
        local rest="${entry#*|}"
        local display="${rest%%|*}"
        local hint="${rest#*|}"

        # PLATFORM 走多选
        if [[ "$fname" == "PLATFORM" ]]; then
            if _aytool_multi_select_platform; then
                $save_fn
                echo "  ${_C_GREEN}已保存${_C_RESET} PLATFORM=${PLATFORM}"
            fi
            continue
        fi

        local cur_val="${(P)fname}"
        echo "  ${_C_BOLD}${display}${_C_RESET}"
        if [[ "$fname" == "REGISTRY_PASS" ]]; then
            echo "  ${_C_DIM}当前值: ******${_C_RESET}"
        else
            echo "  ${_C_DIM}当前值: ${cur_val:-(空)}${_C_RESET}"
        fi
        [[ -n "$hint" ]] && printf "  ${_C_DIM}${hint}${_C_RESET}\n"
        if [[ -n "$cur_val" ]]; then
            printf "  ${_C_DIM}(空回车保持不变，输入 - 清空)${_C_RESET}\n"
        else
            printf "  ${_C_DIM}(空回车保持不变)${_C_RESET}\n"
        fi
        printf "  新值: "
        local new_val; read -r new_val
        if [[ "$new_val" == "-" ]]; then
            eval "${fname}=''"
            $save_fn
            echo "  ${_C_GREEN}已清空${_C_RESET}"
        elif [[ -n "$new_val" ]]; then
            eval "${fname}=\"\${new_val}\""
            $save_fn
            echo "  ${_C_GREEN}已保存${_C_RESET}"
        else
            echo "  ${_C_DIM}未修改${_C_RESET}"
        fi
    done
}

# ══════════════════════════════════════════════════════
# config 命令
# ══════════════════════════════════════════════════════

_aytool_config() {
    _aytool_load_config || return 1

    _CONFIG_FIELDS=(
        "REGISTRY|Registry 地址|例: ccr.ccs.tencentyun.com"
        "REGISTRY_USER|Registry 用户名|例: your_username"
        "REGISTRY_PASS|Registry 密码|例: your_password"
        "NAMESPACE|命名空间|例: my-namespace"
        "PLATFORM|构建平台|多选"
        "ENV_FILE|.env 文件路径|例: /home/user/.env"
    )

    _aytool_edit_fields _CONFIG_FIELDS _aytool_render_config_fields _aytool_save_config "配置编辑器"
}

# ══════════════════════════════════════════════════════
# project 子命令
# ══════════════════════════════════════════════════════

_aytool_project() {
    local subcmd="$1"

    _aytool_load_config || return 1
    _aytool_load_projects

    case "$subcmd" in
        add) _aytool_project_add ;;
        rm)  _aytool_project_rm "$2" ;;
        "")  _aytool_project_edit ;;
        *)
            echo "${_C_RED}未知子命令: project ${subcmd}${_C_RESET}"
            echo "用法: aytool project [add|rm <别名>]"
            return 1
            ;;
    esac
}

# 保存当前编辑中的项目（回调，被 edit_fields 调用）
_aytool_save_current_project() {
    _P_ALIAS="$_PE_ALIAS"
    _P_ENV_VAR="$_PE_ENV_VAR"
    _P_IMAGE="$_PE_IMAGE"
    _P_BUILD_DIR="${_PE_BUILD_DIR/#\~/$HOME}"
    _P_DOCKERFILE="$_PE_DOCKERFILE"
    _P_BUILD_CONTEXTS="$_PE_BUILD_CONTEXTS"
    _PROJECTS[$_EDIT_PROJECT_IDX]=$(_aytool_serialize_project)
    _aytool_save_projects
}

_aytool_project_edit() {
    local total=${#_PROJECTS[@]}
    if (( total == 0 )); then
        echo "  ${_C_RED}没有配置任何项目${_C_RESET}"
        echo "  运行 ${_C_CYAN}aytool project add${_C_RESET} 添加项目"
        return 1
    fi

    echo ""
    echo "  ${_C_BOLD}选择项目${_C_RESET} ${_C_DIM}(↑↓ 选择  Enter 编辑  q 退出)${_C_RESET}"
    echo ""

    _aytool_tui_select $total _aytool_render_projects || return 0

    _EDIT_PROJECT_IDX=$_TUI_SELECTED
    _aytool_parse_project "${_PROJECTS[$_EDIT_PROJECT_IDX]}"

    # 映射到可编辑变量（BUILD_DIR 显示为 ~ 格式）
    _PE_ALIAS="$_P_ALIAS"
    _PE_ENV_VAR="$_P_ENV_VAR"
    _PE_IMAGE="$_P_IMAGE"
    _PE_BUILD_DIR="${_P_BUILD_DIR/#$HOME/~}"
    _PE_DOCKERFILE="$_P_DOCKERFILE"
    _PE_BUILD_CONTEXTS="$_P_BUILD_CONTEXTS"

    _EDIT_FIELDS=(
        "_PE_ALIAS|别名|项目简称，用于 aytool build <别名>"
        "_PE_ENV_VAR|ENV变量名|.env 中的版本变量名"
        "_PE_IMAGE|镜像名|Docker 镜像名称"
        "_PE_BUILD_DIR|构建目录|Dockerfile 所在目录"
        "_PE_DOCKERFILE|Dockerfile|相对路径，空=默认 Dockerfile"
        "_PE_BUILD_CONTEXTS|构建上下文|逗号分隔，如 name=path，空=无"
    )

    _aytool_edit_fields _EDIT_FIELDS _aytool_render_edit_fields _aytool_save_current_project "编辑项目: ${_PE_ALIAS}"
}

_aytool_project_add() {
    echo ""
    echo "  ${_C_BOLD}添加新项目${_C_RESET}"
    echo ""

    local alias env_var image build_dir dockerfile contexts

    printf "  ${_C_BOLD}别名${_C_RESET} ${_C_DIM}(项目简称，如 myapp)${_C_RESET}: "; read -r alias
    [[ -z "$alias" ]] && { echo "  ${_C_RED}别名不能为空${_C_RESET}"; return 1; }

    # 检查重复
    for entry in "${_PROJECTS[@]}"; do
        [[ "${entry%%|*}" == "$alias" ]] && { echo "  ${_C_RED}别名已存在: $alias${_C_RESET}"; return 1; }
    done

    printf "  ${_C_BOLD}ENV变量名${_C_RESET} ${_C_DIM}(.env 中的版本变量名)${_C_RESET}: "; read -r env_var
    [[ -z "$env_var" ]] && { echo "  ${_C_RED}ENV变量名不能为空${_C_RESET}"; return 1; }

    printf "  ${_C_BOLD}镜像名${_C_RESET} ${_C_DIM}(Docker 镜像名称)${_C_RESET}: "; read -r image
    [[ -z "$image" ]] && { echo "  ${_C_RED}镜像名不能为空${_C_RESET}"; return 1; }

    printf "  ${_C_BOLD}构建目录${_C_RESET} ${_C_DIM}(Dockerfile 所在目录)${_C_RESET}: "; read -r build_dir
    [[ -z "$build_dir" ]] && { echo "  ${_C_RED}构建目录不能为空${_C_RESET}"; return 1; }

    printf "  ${_C_BOLD}Dockerfile${_C_RESET} ${_C_DIM}(相对路径，空=默认)${_C_RESET}: "; read -r dockerfile
    printf "  ${_C_BOLD}构建上下文${_C_RESET} ${_C_DIM}(逗号分隔 name=path，空=无)${_C_RESET}: "; read -r contexts

    _PROJECTS+=("${alias}|${env_var}|${image}|${build_dir}|${dockerfile}|${contexts}")
    _aytool_save_projects

    echo ""
    echo "  ${_C_GREEN}已添加项目: ${alias}${_C_RESET}"
    _aytool_list
}

_aytool_project_rm() {
    local alias_name="$1"

    if [[ -z "$alias_name" ]]; then
        echo "${_C_RED}用法: aytool project rm <别名>${_C_RESET}"
        return 1
    fi

    local found=0
    local -a new_projects=()
    for entry in "${_PROJECTS[@]}"; do
        if [[ "${entry%%|*}" == "$alias_name" ]]; then
            found=1
        else
            new_projects+=("$entry")
        fi
    done

    if (( !found )); then
        echo "  ${_C_RED}未找到项目: $alias_name${_C_RESET}"
        return 1
    fi

    printf "  确认删除项目 ${_C_BOLD}${alias_name}${_C_RESET}? [y/N] "
    read -rsk1 confirm 2>/dev/null
    echo ""
    if [[ "$confirm" =~ ^[yY] ]]; then
        _PROJECTS=("${new_projects[@]}")
        _aytool_save_projects
        echo "  ${_C_GREEN}已删除项目: ${alias_name}${_C_RESET}"
    else
        echo "  ${_C_YELLOW}已取消${_C_RESET}"
    fi
}

# ══════════════════════════════════════════════════════
# build 命令
# ══════════════════════════════════════════════════════

_aytool_build() {
    local alias_name="$1"
    local manual_ver="$2"

    _aytool_load_config || return 1
    _aytool_load_projects

    # 无参数 → 交互模式
    if [[ -z "$alias_name" ]]; then
        echo ""
        echo "  ${_C_BOLD}选择项目${_C_RESET} ${_C_DIM}(↑↓ 选择  Enter 确认  q 取消)${_C_RESET}"
        echo ""
        _aytool_tui_select ${#_PROJECTS[@]} _aytool_render_projects || return 0
        _aytool_parse_project "${_PROJECTS[$_TUI_SELECTED]}"
        alias_name="$_P_ALIAS"
    fi

    _aytool_login_check || return 1

    if ! _aytool_find_project "$alias_name"; then
        echo "${_C_RED}未找到项目: $alias_name${_C_RESET}"
        return 1
    fi

    local cur_ver=$(_aytool_read_version "$_P_ENV_VAR")
    local new_ver
    if [[ -n "$manual_ver" ]]; then
        new_ver="$manual_ver"
    else
        new_ver=$((cur_ver + 1))
    fi

    local full_image="${REGISTRY}/${NAMESPACE}/${_P_IMAGE}:${new_ver}"

    echo ""
    echo "  ${_C_DIM}───────────────────────────────────────────${_C_RESET}"
    echo "  ${_C_BOLD}项目:${_C_RESET}  ${_C_CYAN}${_P_IMAGE}${_C_RESET}"
    echo "  ${_C_BOLD}目录:${_C_RESET}  ${_P_BUILD_DIR}"
    [[ -n "$_P_DOCKERFILE" ]] && echo "  ${_C_BOLD}文件:${_C_RESET}  ${_P_DOCKERFILE}"
    echo "  ${_C_BOLD}版本:${_C_RESET}  ${_C_YELLOW}v${cur_ver}${_C_RESET} → ${_C_GREEN}v${new_ver}${_C_RESET}"
    echo "  ${_C_BOLD}镜像:${_C_RESET}  ${full_image}"
    echo "  ${_C_BOLD}平台:${_C_RESET}  ${PLATFORM}"
    echo "  ${_C_DIM}───────────────────────────────────────────${_C_RESET}"
    echo ""

    printf "  确认构建? [Y/n] "
    read -rsk1 confirm 2>/dev/null
    echo ""
    [[ "$confirm" =~ ^[nN] ]] && { echo "  ${_C_YELLOW}已取消${_C_RESET}"; return 0; }

    echo ""
    echo "  ${_C_MAGENTA}开始构建...${_C_RESET}"
    echo ""

    local cmd="docker buildx build --platform ${PLATFORM} --push -t ${full_image}"
    [[ -n "$_P_DOCKERFILE" ]] && cmd="${cmd} -f ${_P_BUILD_DIR}/${_P_DOCKERFILE}"
    if [[ -n "$_P_BUILD_CONTEXTS" ]]; then
        local IFS=','
        for ctx in ${=_P_BUILD_CONTEXTS}; do
            local ctx_name="${ctx%%=*}"
            local ctx_path="${ctx#*=}"
            ctx_path="${ctx_path/#\~/$HOME}"
            cmd="${cmd} --build-context ${ctx_name}=${ctx_path}"
        done
    fi
    cmd="${cmd} ${_P_BUILD_DIR}"

    echo "  ${_C_DIM}$ ${cmd}${_C_RESET}"
    echo ""

    eval "$cmd"

    if [[ $? -ne 0 ]]; then
        echo ""
        echo "  ${_C_RED}构建失败${_C_RESET}"
        return 1
    fi

    _aytool_update_version "$_P_ENV_VAR" "$new_ver"

    echo ""
    echo "  ${_C_GREEN}构建成功!${_C_RESET}"
    echo "  ${_C_DIM}───────────────────────────────────────────${_C_RESET}"
    echo "  ${_C_BOLD}版本已更新:${_C_RESET} ${_P_ENV_VAR}=${new_ver}"
    echo "  ${_C_BOLD}Pull 命令:${_C_RESET}  ${_C_CYAN}docker pull ${full_image}${_C_RESET}"
    echo "  ${_C_DIM}───────────────────────────────────────────${_C_RESET}"
    echo ""
}

# ══════════════════════════════════════════════════════
# list / pull 命令
# ══════════════════════════════════════════════════════

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
        _aytool_parse_project "$entry"
        local ver=$(_aytool_read_version "$_P_ENV_VAR")
        local dir="${_P_BUILD_DIR/#$HOME/~}"
        printf "  %-4s ${_C_CYAN}%-10s${_C_RESET} %-24s ${_C_GREEN}v%-9s${_C_RESET} %s\n" "$i" "$_P_ALIAS" "$_P_IMAGE" "$ver" "$dir"
        ((i++))
    done
    echo "  ${_C_DIM}──────────────────────────────────────────────────────────────────${_C_RESET}"
    echo ""
}

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

    local ver=$(_aytool_read_version "$_P_ENV_VAR")
    local full_image="${REGISTRY}/${NAMESPACE}/${_P_IMAGE}:${ver}"

    echo ""
    echo "  ${_C_BOLD}Pull 命令:${_C_RESET}"
    echo ""
    echo "  ${_C_CYAN}docker pull ${full_image}${_C_RESET}"
    echo ""
}

# ══════════════════════════════════════════════════════
# import / init 命令
# ══════════════════════════════════════════════════════

_aytool_import() {
    local file="$1"

    if [[ -z "$file" ]]; then
        echo "${_C_RED}用法: aytool import <文件路径>${_C_RESET}"
        echo "文件格式:"
        echo "  ${_C_DIM}[config]${_C_RESET}"
        echo "  ${_C_DIM}KEY=VALUE${_C_RESET}"
        echo "  ${_C_DIM}[projects]${_C_RESET}"
        echo "  ${_C_DIM}别名|ENV变量名|镜像名|构建目录|Dockerfile|构建上下文${_C_RESET}"
        return 1
    fi

    file="${file/#\~/$HOME}"
    [[ ! -f "$file" ]] && { echo "${_C_RED}文件不存在: $file${_C_RESET}"; return 1; }

    mkdir -p "$_AYTOOL_DIR"

    local section=""
    local config_lines=()
    local project_lines=()

    while IFS= read -r line; do
        local trimmed="${line## }"; trimmed="${trimmed%% }"
        [[ -z "$trimmed" ]] && continue
        if [[ "$trimmed" == "[config]" ]]; then section="config"; continue; fi
        if [[ "$trimmed" == "[projects]" ]]; then section="projects"; continue; fi
        case "$section" in
            config)   config_lines+=("$trimmed") ;;
            projects) project_lines+=("$trimmed") ;;
        esac
    done < "$file"

    if (( ${#config_lines[@]} == 0 && ${#project_lines[@]} == 0 )); then
        echo "${_C_RED}文件中未找到 [config] 或 [projects] 段${_C_RESET}"
        return 1
    fi

    (( ${#config_lines[@]} > 0 )) && {
        printf '%s\n' "${config_lines[@]}" > "$_AYTOOL_CONFIG"
        echo "${_C_GREEN}已导入 config${_C_RESET} (${#config_lines[@]} 行)"
    }
    (( ${#project_lines[@]} > 0 )) && {
        printf '%s\n' "${project_lines[@]}" > "$_AYTOOL_PROJECTS"
        echo "${_C_GREEN}已导入 projects.conf${_C_RESET} (${#project_lines[@]} 行)"
    }

    echo ""
    echo "  ${_C_BOLD}导入完成${_C_RESET}"
    _aytool_list
}

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
# 别名|ENV变量名|镜像名|构建目录|Dockerfile路径(可选)|构建上下文(可选)
# 示例:
# myapp|MYAPP_VERSION|myapp_image|~/projects/myapp||
# frontend|FRONTEND_VERSION|frontend_image|~/projects|frontend/Dockerfile|shared=~/libs
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

# ══════════════════════════════════════════════════════
# 自动更新
# ══════════════════════════════════════════════════════

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

_aytool_check_update_bg() {
    local notice_file="${_AYTOOL_DIR}/update_notice"
    mkdir -p "$_AYTOOL_DIR"
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
    [[ -z "$new_ver" ]] && { rm -f "$tmp_file"; echo "  ${_C_RED}下载文件异常${_C_RESET}"; return 1; }

    if [[ "$new_ver" == "$old_ver" ]]; then
        rm -f "$tmp_file"
        echo "  ${_C_GREEN}已是最新版本 v${old_ver}${_C_RESET}"
        echo ""
        return 0
    fi

    mv "$tmp_file" "$install_path"
    echo "$(date +%s)" > "${_AYTOOL_DIR}/last_update_check"
    rm -f "${_AYTOOL_DIR}/update_notice"

    echo "  ${_C_GREEN}更新成功!${_C_RESET} ${_C_YELLOW}v${old_ver}${_C_RESET} → ${_C_GREEN}v${new_ver}${_C_RESET}"
    echo ""
    source "$install_path"
    echo "  已自动加载新版本 ${_C_GREEN}v${_AYTOOL_VERSION}${_C_RESET}"
    echo ""
}

_aytool_version() {
    echo "aytool v${_AYTOOL_VERSION}"
}

# ══════════════════════════════════════════════════════
# 主入口
# ══════════════════════════════════════════════════════

aytool() {
    local subcmd="$1"
    shift 2>/dev/null

    _aytool_show_update_notice

    case "$subcmd" in
        build)    _aytool_build "$@" ;;
        project)  _aytool_project "$@" ;;
        list|ls)  _aytool_list ;;
        pull)     _aytool_pull "$@" ;;
        init)     _aytool_init ;;
        import)   _aytool_import "$@" ;;
        config)   _aytool_config ;;
        update)   _aytool_update ;;
        version|--version|-v) _aytool_version ;;
        help|--help|-h|"")
            echo ""
            echo "  ${_C_BOLD}aytool${_C_RESET} - Docker 构建工具 ${_C_DIM}v${_AYTOOL_VERSION}${_C_RESET}"
            echo ""
            echo "  ${_C_BOLD}用法:${_C_RESET}"
            echo "    aytool init                 生成默认配置文件"
            echo "    aytool import <文件>        从文件导入配置"
            echo "    aytool config               交互式编辑全局配置"
            echo "    aytool project              交互式编辑项目配置"
            echo "    aytool project add          添加新项目"
            echo "    aytool project rm <别名>    删除项目"
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

    () {
        setopt LOCAL_OPTIONS NO_MONITOR
        _aytool_check_update_bg &>/dev/null &
        disown 2>/dev/null
    }
}
