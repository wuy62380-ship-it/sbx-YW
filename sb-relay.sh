#!/usr/bin/env bash
# ============================================================================
# Sing-Box 纯终端极简中转管理脚本
# 特性：0内存占用、0端口暴露、jq动态拼装JSON、失败防崩溃拦截
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
# 初始化环境
# ============================================================================

init_env() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${gl_red}错误：请使用 root 用户运行${gl_bai}"
        exit 1
    fi

    # 检查 jq 依赖 (拼装 JSON 的神器)
    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${gl_huang}检测到缺少 jq 工具，正在自动安装...${gl_bai}"
        if command -v apt >/dev/null 2>&1; then apt-get install -y jq -qq
        elif command -v yum >/dev/null 2>&1; then yum install -y jq -q
        fi
        [ $? -ne 0 ] && echo -e "${gl_red}jq 安装失败，脚本无法继续${gl_bai}" && exit 1
    fi

    # 检查 sing-box
    if ! command -v sing-box >/dev/null 2>&1; then
        echo -e "${gl_red}错误：未检测到 sing-box，请先安装 sing-box 核心${gl_bai}"
        exit 1
    fi

    # 初始化规则文件
    mkdir -p /etc/sing-box
    [ ! -f "$RULE_FILE" ] && touch "$RULE_FILE"
}

# ============================================================================
# 核心黑科技：用 jq 从零构建完美格式的 JSON
# ============================================================================

build_json() {
    # 1. 初始化基础骨架 (关闭无用日志降IO)
    local json=$(jq -n '{log:{level:"error"}, inbounds:[], outbounds:[], route:{rules:[]}}')
    
    # 2. 读取规则文件并动态拼接
    while IFS=: read -r port ip bport; do
        # 跳过空行和注释
        [[ -z "$port" || "$port" == "#" ]] && continue
        
        local in_tag="in-${port}"
        local out_tag="out-${port}"
        
        # 拼接入站
        json=$(echo "$json" | jq --arg tag "$in_tag" --argjson p "$port" \
            '.inbounds += [{type:"vless", tag:$tag, listen:"::", listen_port:$p}]')
            
        # 拼接出站
        json=$(echo "$json" | jq --arg tag "$out_tag" --arg ip "$ip" --argjson p "$bport" \
            '.outbounds += [{type:"vless", tag:$tag, server:$ip, server_port:$p}]')
            
        # 拼接精准路由规则
        json=$(echo "$json" | jq --arg in "$in_tag" --arg out "$out_tag" \
            '.route.rules += [{inbound:[$in], outbound:$out}]')
            
    done < "$RULE_FILE"
    
    # 3. 写入临时文件
    echo "$json" > "$TMP_FILE"
}

# ============================================================================
# 功能模块
# ============================================================================

add_rule() {
    echo -e "${gl_huang}----------------------------------------${gl_bai}"
    echo -e "${gl_huang}       添加 VLESS 纯转发规则${gl_bai}"
    echo -e "${gl_huang}----------------------------------------${gl_bai}"
    
    read -e -p "请输入 本机监听端口 (如 10000): " port
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo -e "${gl_red}端口格式错误${gl_bai}"; return 1
    fi
    
    # 防呆：检测端口是否被占用
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
    # 核心防崩溃拦截
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
    
    # 优先 reload 不断连，失败才 restart
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
# 交互主菜单
# ============================================================================

main_menu() {
    init_env
    while true; do
        clear
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
        echo -e "0. 退出脚本"
        echo -e "${gl_kjlan}========================================${gl_bai}"
        read -e -p "请输入你的选择: " choice
        
        case $choice in
            1) add_rule; read -rs -n 1 -p "按任意键继续..." ;;
            2) view_rules; read -rs -n 1 -p "按任意键继续..." ;;
            3) del_rule; read -rs -n 1 -p "按任意键继续..." ;;
            4) apply_config; read -rs -n 1 -p "按任意键继续..." ;;
            5) stop_relay; read -rs -n 1 -p "按任意键继续..." ;;
            0|"") echo -e "${gl_lv}再见！${gl_bai}"; break ;;
            *) echo -e "${gl_red}无效选择${gl_bai}"; sleep 1 ;;
        esac
    done
}

main_menu
