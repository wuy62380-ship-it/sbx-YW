#!/usr/bin/env bash
# ============================================================================
# Sing-Box YW一键管理脚本
# 1. 安装/更新核心  2. 极简中转管理器
# ============================================================================

# --- 颜色定义 ---
: "${gl_bai:=\033[0m}"
: "${gl_lv:=\033[32m}"
: "${gl_huang:=\033[33m}"
: "${gl_hui:=\033[90m}"
: "${gl_red:=\033[31m}"
: "${gl_kjlan:=\033[32m}"

# --- 核心路径 ---
RULE_FILE="/etc/sing-box/sb-relay.rules"
CONF_FILE="/etc/sing-box/config.json"
TMP_FILE="/tmp/sb-relay-tmp.json"

# ============================================================================
# 基础环境准备 (仅检查 jq 和创建目录)
# ============================================================================

check_basic_env() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${gl_red}错误：请使用 root 用户运行${gl_bai}"
        exit 1
    fi

    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${gl_huang}[环境] 缺少 jq 工具，正在自动安装...${gl_bai}"
        if command -v apt >/dev/null 2>&1; then apt-get update -qq && apt-get install -y jq -qq
        elif command -v yum >/dev/null 2>&1; then yum install -y jq -q
        fi
        [ $? -ne 0 ] && echo -e "${gl_red}jq 安装失败${gl_bai}" && exit 1
    fi

    mkdir -p /etc/sing-box
    [ ! -f "$RULE_FILE" ] && touch "$RULE_FILE"
}

# ============================================================================
# 模块 1：安装/更新 Sing-Box 核心
# ============================================================================

install_singbox() {
    echo -e "${gl_huang}========================================${gl_bai}"
    echo -e "${gl_huang}       安装/更新 Sing-Box 核心            ${gl_bai}"
    echo -e "${gl_huang}========================================${gl_bai}"
    
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        echo -e "${gl_huang}[准备] 安装下载工具 curl...${gl_bai}"
        if command -v apt >/dev/null 2>&1; then apt-get install -y curl -qq
        elif command -v yum >/dev/null 2>&1; then yum install -y curl -q
        fi
    fi

    echo -e "${gl_lv}[核心] 正在连接官方源执行安装/更新...${gl_bai}"
    local install_success=0

    if command -v apt >/dev/null 2>&1; then
        if command -v curl >/dev/null 2>&1; then curl -fsSL https://sing-box.app/deb-install.sh | bash && install_success=1
        else wget -qO- https://sing-box.app/deb-install.sh | bash && install_success=1; fi
    elif command -v yum >/dev/null 2>&1; then
        if command -v curl >/dev/null 2>&1; then curl -fsSL https://sing-box.app/rpm-install.sh | bash && install_success=1
        else wget -qO- https://sing-box.app/rpm-install.sh | bash && install_success=1; fi
    else
        echo -e "${gl_red}[核心] 无法识别系统，请手动安装 sing-box${gl_bai}"
        read -rs -n 1 -p "按任意键返回..."
        return 1
    fi

    if [ "$install_success" -eq 1 ] && command -v sing-box >/dev/null 2>&1; then
        local version=$(sing-box version | head -n 1)
        echo -e "${gl_lv}========================================${gl_bai}"
        echo -e "${gl_lv}✅ Sing-Box 安装/更新成功！${gl_bai}"
        echo -e "${gl_lv}版本: ${version}${gl_bai}"
        echo -e "${gl_lv}========================================${gl_bai}"
    else
        echo -e "${gl_red}❌ 安装失败，请检查网络环境。${gl_bai}"
    fi
    read -rs -n 1 -p "按任意键返回主菜单..."
}

# ============================================================================
# 模块 2：中转管理器 (子菜单)
# ============================================================================

relay_manager_menu() {
    while true; do
        clear
        
        # 子菜单前置检查：必须装了核心才能用
        if ! command -v sing-box >/dev/null 2>&1; then
            echo -e "${gl_red}========================================${gl_bai}"
            echo -e "${gl_red}❌ 错误：未检测到 sing-box 核心！${gl_bai}"
            echo -e "${gl_red}========================================${gl_bai}"
            echo -e "${gl_huang}请先返回主菜单选择 [1] 安装核心。${gl_bai}"
            read -rs -n 1 -p "按任意键返回主菜单..."
            return 0 # 直接跳出子菜单，回到主菜单
        fi

        local service_status="${gl_red}未运行${gl_bai}"
        systemctl is-active --quiet sing-box && service_status="${gl_lv}运行中 ✅${gl_bai}"
        
        echo -e "${gl_kjlan}========================================${gl_bai}"
        echo -e "${gl_kjlan}    Sing-Box 极简中转管理器 (0内存面板)  "
        echo -e "${gl_kjlan}========================================${gl_bai}"
        echo -e "当前服务状态: ${service_status}"
        echo -e "当前规则数量: $(grep -vE '^$|#' "$RULE_FILE" | wc -l) 条"
        echo -e "----------------------------------------"
        echo -e "${gl_lv}1. 添加中转规则 (VLESS纯转发)${gl_bai}"
        echo -e "${gl_huang}2. 查看当前规则列表${gl_bai}"
        echo -e "${gl_red}3. 删除指定规则${gl_bai}"
        echo -e "----------------------------------------"
        echo -e "${gl_lv}4. 🧨 校验并应用配置 (热重载) ${gl_huang}★${gl_bai}"
        echo -e "${gl_hui}5. 停止中转服务${gl_bai}"
        echo -e "----------------------------------------"
        echo -e "0. 返回主菜单"
        echo -e "${gl_kjlan}========================================${gl_bai}"
        read -e -p "请输入你的选择: " choice
        
        case $choice in
            1) add_rule; read -rs -n 1 -p "按任意键继续..." ;;
            2) view_rules; read -rs -n 1 -p "按任意键继续..." ;;
            3) del_rule; read -rs -n 1 -p "按任意键继续..." ;;
            4) apply_config; read -rs -n 1 -p "按任意键继续..." ;;
            5) stop_relay; read -rs -n 1 -p "按任意键继续..." ;;
            0|"") break ;; # 返回主菜单
            *) echo -e "${gl_red}无效选择${gl_bai}"; sleep 1 ;;
        esac
    done
}

# ============================================================================
# 核心黑科技：用 jq 从零构建完美格式的 JSON
# ============================================================================

build_json() {
    local json=$(jq -n '{log:{level:"error"}, inbounds:[], outbounds:[], route:{rules:[]}}')
    
    while IFS=: read -r port ip bport; do
        [[ -z "$port" || "$port" == "#" ]] && continue
        local in_tag="in-${port}"
        local out_tag="out-${port}"
        
        json=$(echo "$json" | jq --arg tag "$in_tag" --argjson p "$port" \
            '.inbounds += [{type:"vless", tag:$tag, listen:"::", listen_port:$p}]')
        json=$(echo "$json" | jq --arg tag "$out_tag" --arg ip "$ip" --argjson p "$bport" \
            '.outbounds += [{type:"vless", tag:$tag, server:$ip, server_port:$p}]')
        json=$(echo "$json" | jq --arg in "$in_tag" --arg out "$out_tag" \
            '.route.rules += [{inbound:[$in], outbound:$out}]')
    done < "$RULE_FILE"
    
    echo "$json" > "$TMP_FILE"
}

# ============================================================================
# 中转功能模块实现
# ============================================================================

add_rule() {
    echo -e "${gl_huang}----------------------------------------${gl_bai}"
    echo -e "${gl_huang}       添加 VLESS 纯转发规则${gl_bai}"
    echo -e "${gl_huang}----------------------------------------${gl_bai}"
    
    read -e -p "请输入 本机监听端口 (如 10000): " port
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${gl_red}端口格式错误${gl_bai}"; return 1
    fi
    if ss -tulnp | grep -q ":${port} "; then
        echo -e "${gl_red}错误: 端口 ${port} 已被占用！${gl_bai}"; return 1
    fi
    read -e -p "请输入 后端落地 IP: " ip
    if [[ -z "$ip" ]]; then echo -e "${gl_red}IP不能为空${gl_bai}"; return 1; fi
    read -e -p "请输入 后端落地端口 (如 443): " bport
    if ! [[ "$bport" =~ ^[0-9]+$ ]] || [ "$bport" -lt 1 ] || [ "$bport" -gt 65535 ]; then
        echo -e "${gl_red}端口格式错误${gl_bai}"; return 1
    fi
    
    echo "${port}:${ip}:${bport}" >> "$RULE_FILE"
    echo -e "${gl_lv}✅ 规则添加成功: 本机 ${port} -> ${ip}:${bport}${gl_bai}"
}

view_rules() {
    echo -e "${gl_huang}----------------------------------------${gl_bai}"
    echo -e "${gl_huang}       当前中转规则列表${gl_bai}"
    echo -e "${gl_huang}----------------------------------------${gl_bai}"
    if [ ! -s "$RULE_FILE" ]; then
        echo -e "${gl_hui}暂无任何规则${gl_bai}"; return 0
    fi
    printf "${gl_lv}%-8s %-20s %-8s${gl_bai}\n" "本机端口" "后端IP" "后端端口"
    echo "----------------------------------------"
    while IFS=: read -r port ip bport; do
        [[ -z "$port" || "$port" == "#" ]] && continue
        printf "%-8s %-20s %-8s\n" "$port" "$ip" "$bport"
    done < "$RULE_FILE"
}

del_rule() {
    view_rules
    [ ! -s "$RULE_FILE" ] && return 0
    echo "----------------------------------------"
    read -e -p "请输入要删除的 本机监听端口: " port
    if grep -q "^${port}:" "$RULE_FILE"; then
        sed -i "/^${port}:/d" "$RULE_FILE"
        echo -e "${gl_lv}✅ 已删除端口 ${port} 的规则${gl_bai}"
    else
        echo -e "${gl_red}未找到该端口的规则${gl_bai}"
    fi
}

apply_config() {
    if [ ! -s "$RULE_FILE" ]; then
        echo -e "${gl_red}错误：规则列表为空，请先添加规则！${gl_bai}"; return 1
    fi
    echo -e "${gl_lv}[1/3] 正在生成 JSON 配置...${gl_bai}"
    build_json
    echo -e "${gl_lv}[2/3] 正在进行安全校验...${gl_bai}"
    local check_err=$(sing-box check -c "$TMP_FILE" 2>&1)
    if [ $? -ne 0 ]; then
        echo -e "${gl_red}❌ 校验失败！已拦截写入，当前中转不受影响。${gl_bai}"
        echo -e "${gl_red}错误详情: ${check_err}${gl_bai}"
        rm -f "$TMP_FILE"
        return 1
    fi
    echo -e "${gl_lv}[3/3] 校验通过，正在无缝热重载...${gl_bai}"
    cp -f "$TMP_FILE" "$CONF_FILE"
    rm -f "$TMP_FILE"
    
    if systemctl is-active --quiet sing-box; then
        systemctl reload sing-box 2>/dev/null || systemctl restart sing-box
    else
        systemctl restart sing-box
    fi
    
    if [ $? -eq 0 ]; then
        echo -e "${gl_lv}✅ 惊艳！配置已热重载，现有连接未断开。${gl_bai}"
    else
        echo -e "${gl_red}❌ sing-box 服务启动失败，请检查日志: journalctl -u sing-box -n 20${gl_bai}"
    fi
}

stop_relay() {
    echo -e "${gl_huang}正在停止 sing-box 中转服务...${gl_bai}"
    systemctl stop sing-box
    echo -e "${gl_lv}已停止。${gl_bai}"
}

# ============================================================================
# 主入口：一级菜单
# ============================================================================

main_menu() {
    check_basic_env # 仅初始化 jq 和目录，不管 sing-box
    while true; do
        clear
        
        # 主菜单状态显示
        local core_status="${gl_red}未安装${gl_bai}"
        local core_version=""
        if command -v sing-box >/dev/null 2>&1; then
            core_status="${gl_lv}已安装 ✅${gl_bai}"
            core_version=$(sing-box version 2>/dev/null | head -n 1 | awk '{print $3}')
        fi
        
        echo -e "${gl_kjlan}========================================${gl_bai}"
        echo -e "${gl_kjlan}       Sing-Box 一键管理脚本             "
        echo -e "${gl_kjlan}========================================${gl_bai}"
        echo -e "核心状态: ${core_status} ${gl_hui}${core_version}${gl_bai}"
        echo -e "----------------------------------------"
        echo -e "${gl_lv}1. 安装/更新 Sing-Box 核心${gl_bai}"
        echo -e "${gl_huang}2. 进入中转管理器 (VLESS纯转发) ${gl_huang}★${gl_bai}"
        echo -e "----------------------------------------"
        echo -e "0. 退出脚本"
        echo -e "${gl_kjlan}========================================${gl_bai}"
        read -e -p "请输入你的选择: " choice
        
        case $choice in
            1) install_singbox ;;
            2) relay_manager_menu ;;
            0|"") echo -e "${gl_lv}再见！${gl_bai}"; break ;;
            *) echo -e "${gl_red}无效选择${gl_bai}"; sleep 1 ;;
        esac
    done
}

# 启动主菜单
main_menu
