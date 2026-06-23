#!/usr/bin/env bash
# ============================================================================
# Sing-Box 多协议中转管理脚本
# 支持：VLESS-Reality / Hysteria2 / 纯端口转发
# ============================================================================

# --- 颜色定义 ---
: "${gl_bai:=\033[0m}"
: "${gl_lv:=\033[32m}"
: "${gl_huang:=\033[33m}"
: "${gl_hui:=\033[90m}"
: "${gl_red:=\033[31m}"
: "${gl_kjlan:=\033[32m}"

# --- 核心路径 ---
RULES_JSON="/etc/sing-box/sb-relay-rules.json" # 规则数据库
CONF_FILE="/etc/sing-box/config.json"
TMP_FILE="/tmp/sb-relay-tmp.json"

# ============================================================================
# 基础环境准备
# ============================================================================

check_basic_env() {
    if [ "$(id -u)" -ne 0 ]; then echo -e "${gl_red}错误：请使用 root 用户运行${gl_bai}"; exit 1; fi
    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${gl_huang}[环境] 安装 jq...${gl_bai}"
        if command -v apt >/dev/null 2>&1; then apt-get update -qq && apt-get install -y jq -qq
        elif command -v yum >/dev/null 2>&1; then yum install -y jq -q; fi
        [ $? -ne 0 ] && echo -e "${gl_red}jq 安装失败${gl_bai}" && exit 1
    fi
    mkdir -p /etc/sing-box
    # 初始化 JSON 数据库
    [ ! -f "$RULES_JSON" ] && echo '[]' > "$RULES_JSON"
}

# ============================================================================
# 模块 1：安装核心 (保持不变)
# ============================================================================

install_singbox() {
    echo -e "${gl_huang}========================================${gl_bai}"
    echo -e "${gl_huang}       安装/更新 Sing-Box 核心            ${gl_bai}"
    echo -e "${gl_huang}========================================${gl_bai}"
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        if command -v apt >/dev/null 2>&1; then apt-get install -y curl -qq
        elif command -v yum >/dev/null 2>&1; then yum install -y curl -q; fi
    fi
    echo -e "${gl_lv}[核心] 正在连接官方源...${gl_bai}"
    local success=0
    if command -v apt >/dev/null 2>&1; then
        curl -fsSL https://sing-box.app/deb-install.sh | bash && success=1
    elif command -v yum >/dev/null 2>&1; then
        curl -fsSL https://sing-box.app/rpm-install.sh | bash && success=1
    else
        echo -e "${gl_red}无法识别系统${gl_bai}"; read -rs -n 1 -p "按任意键返回..."; return 1
    fi
    if [ "$success" -eq 1 ] && command -v sing-box >/dev/null 2>&1; then
        echo -e "${gl_lv}✅ 安装成功: $(sing-box version | head -n 1)${gl_bai}"
    else
        echo -e "${gl_red}❌ 安装失败${gl_bai}"
    fi
    read -rs -n 1 -p "按任意键返回主菜单..."
}

# ============================================================================
# 模块 2：中转管理器主菜单
# ============================================================================

relay_manager_menu() {
    while true; do
        clear
        if ! command -v sing-box >/dev/null 2>&1; then
            echo -e "${gl_red}❌ 未检测到 sing-box 核心！请先返回主菜单安装。${gl_bai}"
            read -rs -n 1 -p "按任意键返回..."; return 0
        fi
        local status="${gl_red}未运行${gl_bai}"; systemctl is-active --quiet sing-box && status="${gl_lv}运行中 ✅${gl_bai}"
        local count=$(jq 'length' "$RULES_JSON")
        
        echo -e "${gl_kjlan}========================================${gl_bai}"
        echo -e "${gl_kjlan}       Sing-Box 多协议中转管理器          "
        echo -e "${gl_kjlan}========================================${gl_bai}"
        echo -e "服务状态: ${status}  |  规则数量: ${gl_lv}${count}${gl_bai} 条"
        echo -e "----------------------------------------"
        echo -e "${gl_lv}1. 添加中转规则 (Reality/Hy2/纯转发)${gl_bai}"
        echo -e "${gl_huang}2. 查看当前规则列表${gl_bai}"
        echo -e "${gl_red}3. 删除指定规则${gl_bai}"
        echo -e "----------------------------------------"
        echo -e "${gl_lv}4. 🧨 校验并应用配置 (热重载) ${gl_huang}★${gl_bai}"
        echo -e "${gl_hui}5. 停止中转服务${gl_bai}"
        echo -e "----------------------------------------"
        echo -e "0. 返回主菜单"
        echo -e "${gl_kjlan}========================================${gl_bai}"
        read -e -p "请输入选择: " choice
        
        case $choice in
            1) add_rule_menu; read -rs -n 1 -p "按任意键继续..." ;;
            2) view_rules; read -rs -n 1 -p "按任意键继续..." ;;
            3) del_rule; read -rs -n 1 -p "按任意键继续..." ;;
            4) apply_config; read -rs -n 1 -p "按任意键继续..." ;;
            5) systemctl stop sing-box && echo -e "${gl_lv}已停止${gl_bai}"; read -rs -n 1 -p "按任意键继续..." ;;
            0|"") break ;;
            *) echo -e "${gl_red}无效选择${gl_bai}"; sleep 1 ;;
        esac
    done
}

# ============================================================================
# 协议选择子菜单与参数收集
# ============================================================================

add_rule_menu() {
    echo -e "${gl_huang}========================================${gl_bai}"
    echo -e "${gl_huang}       选择中转协议类型                   ${gl_bai}"
    echo -e "${gl_huang}========================================${gl_bai}"
    echo -e "${gl_lv}1. VLESS-Reality (推荐，抗封锁最强)${gl_bai}"
    echo -e "${gl_huang}2. Hysteria2 (极速，需支持UDP的机场)${gl_bai}"
    echo -e "${gl_hui}3. 纯 TCP/UDP 端口转发 (无加密，极简)${gl_bai}"
    echo -e "0. 返回"
    read -e -p "请选择协议: " proto_choice
    
    case $proto_choice in
        1) add_reality ;;
        2) add_hysteria2 ;;
        3) add_direct ;;
        *) return 0 ;;
    esac
}

# 通用端口检测
check_port() {
    if ! [[ "$1" =~ ^[0-9]+$ ]] || [ "$1" -lt 1 ] || [ "$1" -gt 65535 ]; then echo -e "${gl_red}端口错误${gl_bai}"; return 1; fi
    if ss -tulnp | grep -q ":${1} "; then echo -e "${gl_red}端口 $1 已被占用${gl_bai}"; return 1; fi
}

add_reality() {
    echo -e "\n--- VLESS-Reality 规则配置 ---"
    read -e -p "本机监听端口: " port; check_port "$port" || return 1
    read -e -p "后端落地 IP: " ip; [[ -z "$ip" ]] && echo -e "${gl_red}IP为空${gl_bai}" && return 1
    read -e -p "后端落地端口 (如 443): " bport; check_port "$bport" || return 1
    read -e -p "Reality 公钥: " pubkey; [[ -z "$pubkey" ]] && echo -e "${gl_red}公钥必填${gl_bai}" && return 1
    read -e -p "Reality 短ID (Short ID, 可留空): " short_id
    read -e -p "伪装域名 (SNI, 如 www.microsoft.com): " sni; [[ -z "$sni" ]] && sni="www.microsoft.com"
    read -e -p "TLS 指纹 (如 chrome, firefox): " fp; [[ -z "$fp" ]] && fp="chrome"

    # 用 jq 将新规则追加到 JSON 数组
    jq --arg type "vless-reality" --argjson port "$port" --arg ip "$ip" --argjson bport "$bport" \
       --arg pubkey "$pubkey" --arg short_id "${short_id:-""}" --arg sni "$sni" --arg fp "$fp" \
       '. += [{"type": $type, "listen_port": $port, "server": $ip, "server_port": $bport, "public_key": $pubkey, "short_id": $short_id, "sni": $sni, "fingerprint": $fp}]' \
       "$RULES_JSON" > "${RULES_JSON}.tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
       
    echo -e "${gl_lv}✅ Reality 规则添加成功${gl_bai}"
}

add_hysteria2() {
    echo -e "\n--- Hysteria2 规则配置 ---"
    read -e -p "本机监听端口: " port; check_port "$port" || return 1
    read -e -p "后端落地 IP: " ip; [[ -z "$ip" ]] && echo -e "${gl_red}IP为空${gl_bai}" && return 1
    read -e -p "后端落地端口 (如 8443): " bport; check_port "$bport" || return 1
    read -e -p "Hysteria2 密码: " pass; [[ -z "$pass" ]] && echo -e "${gl_red}密码必填${gl_bai}" && return 1
    read -e -p "伪装域名 SNI (如 example.com, 可留空): " sni

    jq --arg type "hysteria2" --argjson port "$port" --arg ip "$ip" --argjson bport "$bport" \
       --arg pass "$pass" --arg sni "${sni:-""}" \
       '. += [{"type": $type, "listen_port": $port, "server": $ip, "server_port": $bport, "password": $pass, "sni": $sni}]' \
       "$RULES_JSON" > "${RULES_JSON}.tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
       
    echo -e "${gl_lv}✅ Hysteria2 规则添加成功${gl_bai}"
}

add_direct() {
    echo -e "\n--- 纯端口转发配置 ---"
    read -e -p "本机监听端口: " port; check_port "$port" || return 1
    read -e -p "后端目标 IP: " ip; [[ -z "$ip" ]] && echo -e "${gl_red}IP为空${gl_bai}" && return 1
    read -e -p "后端目标端口: " bport; check_port "$bport" || return 1

    jq --arg type "direct" --argjson port "$port" --arg ip "$ip" --argjson bport "$bport" \
       '. += [{"type": $type, "listen_port": $port, "server": $ip, "server_port": $bport}]' \
       "$RULES_JSON" > "${RULES_JSON}.tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
       
    echo -e "${gl_lv}✅ 纯转发规则添加成功${gl_bai}"
}

# ============================================================================
# 查看与删除
# ============================================================================

view_rules() {
    echo -e "${gl_huang}----------------------------------------${gl_bai}"
    echo -e "${gl_huang}       当前中转规则列表${gl_bai}"
    echo -e "${gl_huang}----------------------------------------${gl_bai}"
    local count=$(jq 'length' "$RULES_JSON")
    if [ "$count" -eq 0 ]; then echo -e "${gl_hui}暂无规则${gl_bai}"; return 0; fi
    
    for ((i=0; i<count; i++)); do
        local type=$(jq -r ".[$i].type" "$RULES_JSON")
        local port=$(jq -r ".[$i].listen_port" "$RULES_JSON")
        local ip=$(jq -r ".[$i].server" "$RULES_JSON")
        local bport=$(jq -r ".[$i].server_port" "$RULES_JSON")
        
        case $type in
            vless-reality) local info="Reality -> ${ip}:${bport}" ;;
            hysteria2) local info="Hy2 -> ${ip}:${bport}" ;;
            direct) local info="纯转发 -> ${ip}:${bport}" ;;
            *) local info="未知 -> ${ip}:${bport}" ;;
        esac
        printf "${gl_lv}[%d] 端口:%-6s %s${gl_bai}\n" "$i" "$port" "$info"
    done
}

del_rule() {
    view_rules
    [ $(jq 'length' "$RULES_JSON") -eq 0 ] && return 0
    echo "----------------------------------------"
    read -e -p "输入要删除的规则序号 (如 0): " idx
    if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -lt $(jq 'length' "$RULES_JSON") ]; then
        jq "del(.[$idx])" "$RULES_JSON" > "${RULES_JSON}.tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
        echo -e "${gl_lv}✅ 已删除序号 $idx 的规则${gl_bai}"
    else
        echo -e "${gl_red}序号无效${gl_bai}"
    fi
}

# ============================================================================
# 核心黑科技：动态 JSON 生成引擎
# ============================================================================

build_json() {
    # 初始化骨架
    local json=$(jq -n '{log:{level:"error"}, inbounds:[], outbounds:[], route:{rules:[]}}')
    local count=$(jq 'length' "$RULES_JSON")
    
    for ((i=0; i<count; i++)); do
        local rule=$(jq ".[$i]" "$RULES_JSON")
        local type=$(echo "$rule" | jq -r '.type')
        local port=$(echo "$rule" | jq -r '.listen_port')
        local in_tag="in-${port}"
        local out_tag="out-${port}"
        
        case "$type" in
            vless-reality)
                # Inbound: mixed (接受 socks5/http 请求)
                json=$(echo "$json" | jq --arg tag "$in_tag" --argjson p "$port" \
                    '.inbounds += [{type:"mixed", tag:$tag, listen:"::", listen_port:$p}]')
                # Outbound: vless-reality
                json=$(echo "$json" | jq --arg tag "$out_tag" --argjson rule "$rule" \
                    '.outbounds += [{
                        type: "vless", tag: $tag, server: $rule.server, server_port: $rule.server_port,
                        uuid: "00000000-0000-0000-0000-000000000000", flow: "xtls-rprx-vision",
                        tls: {
                            enabled: true, server_name: $rule.sni,
                            utls: { enabled: true, fingerprint: $rule.fingerprint },
                            reality: { enabled: true, public_key: $rule.public_key, short_id: $rule.short_id }
                        }
                    }]')
                ;;
                
            hysteria2)
                # Inbound: mixed
                json=$(echo "$json" | jq --arg tag "$in_tag" --argjson p "$port" \
                    '.inbounds += [{type:"mixed", tag:$tag, listen:"::", listen_port:$p}]')
                # Outbound: hysteria2
                json=$(echo "$json" | jq --arg tag "$out_tag" --argjson rule "$rule" \
                    '.outbounds += [{
                        type: "hysteria2", tag: $tag, server: $rule.server, server_port: $rule.server_port,
                        password: $rule.password,
                        tls: { enabled: true, server_name: $rule.sni, insecure: true }
                    }]')
                ;;
                
            direct)
                # 纯转发：使用 direct 入站的 override 特性，极简且性能最高，不需要 outbound！
                json=$(echo "$json" | jq --arg tag "$in_tag" --argjson p "$port" --argjson rule "$rule" \
                    '.inbounds += [{
                        type: "direct", tag: $tag, listen:"::", listen_port: $p,
                        override_address: $rule.server, override_port: $rule.server_port
                    }]')
                ;;
        esac
        
        # 拼接路由 (纯转发不需要路由，因为没有 outbound)
        if [ "$type" != "direct" ]; then
            json=$(echo "$json" | jq --arg in "$in_tag" --arg out "$out_tag" \
                '.route.rules += [{inbound:[$in], outbound:$out}]')
        fi
    done
    
    echo "$json" > "$TMP_FILE"
}

apply_config() {
    if [ $(jq 'length' "$RULES_JSON") -eq 0 ]; then
        echo -e "${gl_red}错误：规则为空！${gl_bai}"; return 1
    fi
    echo -e "${gl_lv}[1/3] 正在生成多协议 JSON...${gl_bai}"
    build_json
    
    echo -e "${gl_lv}[2/3] 安全校验中...${gl_bai}"
    local err=$(sing-box check -c "$TMP_FILE" 2>&1)
    if [ $? -ne 0 ]; then
        echo -e "${gl_red}❌ 校验失败！已拦截。${gl_bai}\n${err}"
        rm -f "$TMP_FILE"; return 1
    fi
    
    echo -e "${gl_lv}[3/3] 无缝热重载...${gl_bai}"
    cp -f "$TMP_FILE" "$CONF_FILE" && rm -f "$TMP_FILE"
    if systemctl is-active --quiet sing-box; then
        systemctl reload sing-box 2>/dev/null || systemctl restart sing-box
    else
        systemctl restart sing-box
    fi
    
    [ $? -eq 0 ] && echo -e "${gl_lv}✅ 多协议中转已热重载！${gl_bai}" || echo -e "${gl_red}❌ 启动失败${gl_bai}"
}

# ============================================================================
# 主入口
# ============================================================================

main_menu() {
    check_basic_env
    while true; do
        clear
        local core="${gl_red}未安装${gl_bai}"
        command -v sing-box >/dev/null 2>&1 && core="${gl_lv}已安装 ✅${gl_bai}"
        echo -e "${gl_kjlan}========================================${gl_bai}"
        echo -e "${gl_kjlan}       YW 多协议管理脚本           "
        echo -e "${gl_kjlan}========================================${gl_bai}"
        echo -e "核心状态: ${core}"
        echo -e "----------------------------------------"
        echo -e "${gl_lv}1. 安装/更新 Sing-Box 核心${gl_bai}"
        echo -e "${gl_huang}2. 进入中转管理器 ${gl_huang}★${gl_bai}"
        echo -e "----------------------------------------"
        echo -e "0. 退出"
        echo -e "${gl_kjlan}========================================${gl_bai}"
        read -e -p "选择: " choice
        case $choice in
            1) install_singbox ;;
            2) relay_manager_menu ;;
            0|"") break ;;
        esac
    done
}

main_menu
