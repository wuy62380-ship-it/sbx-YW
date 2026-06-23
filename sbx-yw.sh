#!/usr/bin/env bash
# ============================================================================
# Sing-Box 多协议中转管理脚本 (全自动本机直连版)
# ============================================================================

# --- 颜色定义 ---
: "${gl_bai:=\033[0m}"
: "${gl_lv:=\033[32m}"
: "${gl_huang:=\033[33m}"
: "${gl_hui:=\033[90m}"
: "${gl_red:=\033[31m}"
: "${gl_kjlan:=\033[32m}"

# --- 核心路径 ---
RULES_JSON="/etc/sing-box/sb-relay-rules.json"
SERVERS_LIST="/etc/sing-box/sb-servers.list"
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
    [ ! -f "$RULES_JSON" ] && echo '[]' > "$RULES_JSON"
    [ ! -f "$SERVERS_LIST" ] && touch "$SERVER_IP"
fi

# ============================================================================
# 模块 1：安装核心
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
# 模块 2：节点管理
# ============================================================================

node_manager_menu() {
    if ! command -v sing-box >/dev/null 2>&1; then
        echo -e "${gl_red}❌ 未检测到 sing-box 核心！请先在主菜单安装。${gl_bai}"
        read -rs -n 1 -p "按任意键返回..."; return 0
    fi

    while true; do
        clear
        local status="${gl_red}未运行${gl_bai}"; systemctl is-active --quiet sing-box && status="${gl_lv}运行中 ✅${gl_bai}"
        local count=$(jq 'length' "$RULES_JSON")
        local server_count=$(grep -vE '^$|#' "$SERVERS_LIST" | wc -l)
        
        echo -e "${gl_kjlan}========================================${gl_bai}"
        echo -e "${gl_kjlan}             节 点 管 理                 "
        echo -e "${gl_kjlan}========================================${gl_bai}"
        echo -e "服务状态: ${status}  |  节点数量: ${gl_lv}${count}${gl_bai} 个  |  预设落地机: ${gl_lv}${server_count}${gl_bai} 台"
        echo -e "----------------------------------------"
        echo -e "${gl_lv}1. 添加节点 (选择模式与协议)${gl_bai}"
        echo -e "${gl_huang}2. 落地机管理 (预设外部服务器)${gl_bai}"
        echo -e "----------------------------------------"
        echo -e "3. 查看当前节点列表"
        echo -e "${gl_red}4. 删除指定节点${gl_bai}"
        echo -e "----------------------------------------"
        echo -e "${gl_lv}5. 🧨 校验并应用配置 (热重载) ${gl_huang}★${gl_bai}"
        echo -e "${gl_hui}6. 停止中转服务${gl_bai}"
        echo -e "----------------------------------------"
        echo -e "0. 返回主菜单"
        echo -e "${gl_kjlan}========================================${gl_bai}"
        read -e -p "请输入选择: " choice
        
        case $choice in
            1) add_node_selector ;;
            2) manage_servers ;;
            3) view_rules; read -rs -n 1 -p "按任意键继续..." ;;
            4) del_rule; read -rs -n 1 -p "按任意键继续..." ;;
            5) apply_config; read -rs -n 1 -p "按任意键继续..." ;;
            6) systemctl stop sing-box && echo -e "${gl_lv}已停止${gl_bai}"; read -rs -n 1 -p "按任意键继续..." ;;
            0|"") break ;;
            *) echo -e "${gl_red}无效选择${gl_bai}"; sleep 1 ;;
        esac
    done
}

# ============================================================================
# 落地机池管理
# ============================================================================

manage_servers() {
    while true; do
        clear
        local count=$(grep -vE '^$|#' "$SERVERS_LIST" | wc -l)
        echo -e "${gl_huang}========================================${gl_bai}"
        echo -e "${gl_huang}             落 地 机 管 理               "
        echo -e "${gl_huang}========================================${gl_bai}"
        echo -e "当前已预设: ${gl_lv}${count}${gl_bai} 台外部落地机"
        echo -e "----------------------------------------"
        echo -e "${gl_lv}1. 添加落地机 (名称 IP 端口)${gl_bai}"
        echo -e "${gl_huang}2. 查看落地机列表${gl_bai}"
        echo -e "${gl_red}3. 清空所有落地机${gl_bai}"
        echo -e "----------------------------------------"
        echo -e "0. 返回节点管理"
        echo -e "${gl_huang}========================================${gl_bai}"
        read -e -p "请输入选择: " choice
        
        case $choice in
            1) 
                echo -e "\n--- 添加落地机 ---"
                read -e -p "别名 (如 美国-01): " name
                read -e -p "IP 地址: " ip
                read -e -p "端口 (如 443): " port
                if [[ -n "$name" && -n "$ip" && -n "$port" ]]; then
                    echo "$name $ip $port" >> "$SERVERS_LIST"
                    echo -e "${gl_lv}✅ 落地机 [${name}] 添加成功${gl_bai}"
                else
                    echo -e "${gl_red}信息填写不完整${gl_bai}"
                fi
                read -rs -n 1 -p "按任意键继续..." ;;
            2) 
                echo -e "\n--- 落地机列表 ---"
                if [ "$count" -eq 0 ]; then echo -e "${gl_hui}暂无预设${gl_bai}"
                else
                    local idx=1
                    while IFS=' ' read -r name ip port; do
                        [[ -z "$name" || "$name" == "#" ]] && continue
                        echo -e "${gl_lv}[${idx}] ${name} \t ${gl_hui}(${ip}:${port})${gl_bai}"
                        idx=$((idx+1))
                    done < "$SERVERS_LIST"
                fi
                read -rs -n 1 -p "按任意键继续..." ;;
            3) 
                echo "" > "$SERVERS_LIST"
                echo -e "${gl_lv}✅ 已清空所有落地机预设${gl_bai}"
                read -rs -n 1 -p "按任意键继续..." ;;
            0|"") break ;;
            *) echo -e "${gl_red}无效选择${gl_bai}"; sleep 1 ;;
        esac
    done
}

# ============================================================================
# 核心黑科技：三种模式选择器 (支持自动获取本机IP直连)
# ============================================================================

SERVER_IP=""
SERVER_PORT="-1" # -1 代表自动使用本机监听端口
select_server() {
    echo -e "\n----------------------------------------"
    echo -e "${gl_huang}请选择后端获取方式:${gl_bai}"
    echo -e "----------------------------------------"
    echo -e "${gl_lv}1. 从预设列表选择外部落地机${gl_bai}"
    echo -e "${gl_hui}2. 手动输入外部 IP 和端口${gl_bai}"
    echo -e "${gl_kjlan}3. 不用落地机 (自动获取本机IP直连) ${gl_huang}★自动${gl_bai}"
    echo -e "----------------------------------------"
    read -e -p "请选择 (1/2/3): " s_choice
    
    if [ "$s_choice" == "1" ]; then
        local count=$(grep -vE '^$|#' "$SERVERS_LIST" | wc -l)
        if [ "$count" -eq 0 ]; then
            echo -e "${gl_red}❌ 预设列表为空！请先在节点管理中添加落地机。${gl_bai}"
            echo -e "${gl_huang}已自动切换为手动输入模式...${gl_bai}"
            sleep 1
            return 1
        fi
        
        echo -e "\n--- 预设落地机列表 ---"
        local idx=1
        while IFS=' ' read -r name ip port; do
            [[ -z "$name" || "$name" == "#" ]] && continue
            echo -e "${gl_lv}${idx}. ${name} \t ${gl_hui}(${ip}:${port})${gl_bai}"
            idx=$((idx+1))
        done < "$SERVERS_LIST"
        echo -e "----------------------------------------"
        read -e -p "请输入序号选择落地机: " s_idx
        
        if [[ "$s_idx" =~ ^[0-9]+$ ]] && [ "$s_idx" -ge 1 ] && [ "$s_idx" -lt "$idx" ]; then
            SERVER_IP=$(grep -vE '^$|#' "$SERVERS_LIST" | sed -n "${s_idx}p" | awk '{print $2}')
            SERVER_PORT=$(grep -vE '^$|#' "$SERVERS_LIST" | sed -n "${s_idx}p" | awk '{print $3}')
            echo -e "${gl_lv}✅ 已选择外部落地机: ${SERVER_IP}:${SERVER_PORT}${gl_bai}"
            return 0
        else
            echo -e "${gl_red}输入无效！已自动切换为手动输入...${gl_bai}"
            sleep 1
            return 1
        fi
        
    elif [ "$s_choice" == "3" ] || [ "$s_choice" == "3 " ]; then
        # 自动获取本机公网 IP
        echo -ne "${gl_hui}正在自动获取本机公网IP(超时3秒)...${gl_bai}\r"
        local auto_ip=$(curl -s --connect-timeout 2 --max-time 3 ipinfo.io 2>/dev/null | awk -F'"' '/ip/{print $4}' || curl -s --connect-timeout 2 --max-time 3 ifconfig.me 2>/dev/null | grep -oP 'inet (\K[\d.]+)' | awk '{print $2}' || echo "你的服务器无法访问外网")
        
        if [ -z "$auto_ip" ] || [ "$auto_ip" == "你的服务器无法访问外网" ]; then
            echo -e "\n${gl_red}❌ 无法获取外网IP！已自动切换为手动输入模式...${gl_bai}"
            return 1
        fi
        
        SERVER_IP="$auto_ip"
        SERVER_PORT="-1" # 标记为自动模式，底层会自动将后端端口替换为本机监听端口
        echo -e "${gl_kjlan}✅ 已获取本机IP: ${SERVER_IP}，将直接指向本机${gl_bai}"
        return 0
        
    else
        echo -e "${gl_hui}已切换为手动输入模式...${gl_bai}"
        return 1
    fi
}

# ============================================================================
# 丝滑添加节点入口
# ============================================================================

add_node_selector() {
    clear
    echo -e "${gl_kjlan}========================================${gl_bai}"
    echo -e "${gl_kjlan}          选择中转模式与协议             "
    echo -e "${gl_kjlan}========================================${gl_bai}"
    echo -e "${gl_lv}1. 协议中转 (VLESS+Reality/Hy2/Argo)${gl_bai}"
    echo -e "${gl_hui}2. 纯端口转发 (无加密 TCP/UDP 穿透)${gl_bai}"
    echo -e "----------------------------------------"
    echo -e "0. 返回节点管理"
    echo -e "${gl_kjlan}========================================${gl_bai}"
    read -e -p "请选择模式: " mode
    
    case $mode in
        1) 
            clear
            echo -e "${gl_kjlan}========================================${gl_bai}"
            echo -e "${gl_kjlan}          选择加密协议                  "
            echo -e "${gl_kjlan}========================================${gl_bai}"
            echo -e "${gl_lv}1. VLESS + Reality       - 无需证书，抗审查${gl_bai}"
            echo -e "${gl_huang}2. Hysteria2             - 高性能 QUIC 协议${gl_bai}"
            echo -e "${gl_kjlan}3. Argo+VLESS+WS         - 隐藏IP，快速部署${gl_bai}"
            echo -e "----------------------------------------"
            echo -e "0. 返回"
            echo -e "${gl_kjlan}========================================${gl_bai}"
            read -e -p "请选择协议: " proto
            
            case $proto in
                1) add_reality ;;
                2) add_hysteria2 ;;
                3) add_argo_vless_ws ;;
                0|"") return 0 ;;
                *) echo -e "${gl_red}无效选择${gl_bai}"; sleep 1 ;;
            esac
            ;;
        2) add_direct ;;
        0|"") return 0 ;;
        *) echo -e "${gl_red}无效选择${gl_bai}"; sleep 1 ;;
    esac
    
    read -rs -n 1 -p "按任意键继续..."
}

# ============================================================================
# 协议参数收集器 (底层已支持 -1 自动替换为监听端口)
# ============================================================================

check_port() {
    if ! [[ "$1" =~ ^[0-9]+$ ]] || [ "$1" -lt 1 ] || [ "$1" -gt 65535 ]; then echo -e "${gl_red}端口错误${gl_bai}"; return 1; fi
    if ss -tulnp | grep -q ":${1} "; then echo -e "${gl_red}端口 $1 已被占用${gl_bai}"; return 1; fi
}

add_reality() {
    echo -e "\n--- VLESS + Reality 节点配置 ---"
    read -e -p "本机监听端口: " port; check_port "$port" || return 1
    
    if select_server; then
        local ip="$SERVER_IP"; local bport="$SERVER_PORT"
    else
        read -e -p "后端落地 IP: " ip; [[ -z "$ip" ]] && echo -e "${gl_red}IP为空${gl_bai}" && return 1
        read -e -p "后端落地端口: " bport; check_port "$bport" || return 1
    fi
    
    read -e -p "Reality 公钥: " pubkey; [[ -z "$pubkey" ]] && echo -e "${gl_red}公钥必填${gl_bai}" && return 1
    read -e -p "Reality 短ID (可留空): " short_id
    read -e -p "伪装域名 (SNI, 如 www.microsoft.com): " sni; [[ -z "$sni" ]] && sni="www.microsoft.com"
    read -e -p "TLS 指纹 (如 chrome): " fp; [[ -z "$fp" ]] && fp="chrome"

    jq --arg type "vless-reality" --argjson port "$port" --arg ip "$ip" --argjson bport "$bport" \
       --arg pubkey "$pubkey" --arg short_id "${short_id:-""}" --arg sni "$sni" --arg fp "$fp" \
       '. += [{"type": $type, "listen_port": $port, "server": $ip, "server_port": $bport, "public_key": $pubkey, "short_id": $short_id, "sni": $sni, "fingerprint": $fp}]' \
       "$RULES_JSON" > "${RULES_JSON".tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
       
    echo -e "${gl_lv}✅ VLESS + Reality 节点添加成功${gl_bai}"
}

add_argo_vless_ws() {
    echo -e "\n--- Argo + VLESS + WS 节点配置 ---"
    read -e -p "本机监听端口: " port; check_port "$port" || return 1
    
    if select_server; then
        local ip="$SERVER_IP"; local bport="$SERVER_PORT"
    else
        read -e -p "后端 IP/域名: " ip; [[ -z "$ip" ]] && echo -e "${gl_red}必填${gl_bai}" && return 1
        read -e -p "后端端口: " bport; check_port "$bport" || return 1
    fi
    
    read -e -p "WebSocket 路径 (如 /ray): " path; [[ -z "$path" ]] && path="/"
    echo -e "${gl_hui}提示: 中转机默认不启用TLS(由后端或CF处理)。${gl_bai}"

    jq --arg type "argo-vless-ws" --argjson port "$port" --arg ip "$ip" --argjson bport "$bport" --arg path "$path" \
       '. += [{"type": $type, "listen_port": $port, "server": $ip, "server_port": $bport, "path": $path}]' \
       "$RULES_JSON" > "${RULES_JSON".tmp" && mv "${RULES_JSON".tmp" "$RULES_JSON"
       
    echo -e "${gl_lv}✅ Argo + VLESS + WS 节点添加成功${gl_bai}"
}

add_hysteria2() {
    echo -e "\n--- Hysteria 2 节点配置 ---"
    read -e -p "本机监听端口: " port; check_port "$port" || return 1
    
    if select_server; then
        local ip="$SERVER_IP"; local bport="$SERVER_PORT"
    else
        read -e -p "后端落地 IP: " ip; [[ -z "$ip" ]] && echo -e "${gl_red}IP为空${gl_bai}" && return 1
        read -e -p "后端落地端口: " bport; check_port "$bport" || return 1
    fi
    
    read -e -p "Hysteria2 密码: " pass; [[ -z "$pass" ]] && echo -e "${gl_red}密码必填${gl_bai}" && return 1
    read -e -p "伪装域名 (SNI): " sni; [[ -z "$sni" ]] && echo -e "${gl_red}Hy2强烈建议填写SNI${gl_bai}"
    echo -e "${gl_hui}提示: 基于 UDP，请确保防火墙已放行本机 ${port} 端口的 UDP！${gl_bai}"

    jq --arg type "hysteria2" --argjson port "$port" --arg ip "$ip" --argjson bport "$bport" \
       --arg pass "$pass" --arg sni "${sni:-""}" \
       '. += [{"type": $type, "listen_port": $port, "server": $ip, "server_port": $bport, "password": $pass, "sni": $sni}]' \
       "$RULES_JSON" > "${RULES_JSON".tmp" && mv "${RULES_JSON".tmp" "$RULES_JSON"
       
    echo -e "${gl_lv}✅ Hysteria 2 节点添加成功${gl_bai}"
}

add_direct() {
    echo -e "\n--- 纯端口转发节点配置 ---"
    read -e -p "本机监听端口: " port; check_port "$port" || return 1
    
    if select_server; then
        local ip="$SERVER_IP"; local bport="$SERVER_PORT"
    else
        read -e -p "后端目标 IP: " ip; [[ -z "$ip" ]] && echo -e "${gl_red}IP为空${gl_bai}" && return 1
        read -e -p "后端目标端口: " bport; check_port "$bport" || return 1
    fi

    jq --arg type "direct" --argjson port "$port" --arg ip "$ip" --argjson bport "$bport" \
       '. += [{"type": $type, "listen_port": $port, "server": $ip, "server_port": $bport}]' \
       "$RULES_JSON" > "${RULES_JSON".tmp" && mv "${RULES_JSON".tmp" "$RULES_JSON"
       
    echo -e "${gl_lv}✅ 纯转发节点添加成功${gl_bai}"
}

# ============================================================================
# 查看与删除
# ============================================================================

view_rules() {
    echo -e "${gl_huang}----------------------------------------${gl_bai}"
    echo -e "${gl_huang}       当前节点列表${gl_bai}"
    echo -e "${gl_huang}----------------------------------------${gl_bai}"
    local count=$(jq 'length' "$RULES_JSON")
    if [ "$count" -eq 0 ]; then echo -e "${gl_hui}暂无节点${gl_bai}"; return 0; fi
    
    for ((i=0; i<count; i++)); do
        local type=$(jq -r ".[$i].type" "$RULES_JSON")
        local port=$(jq -r ".[$i].listen_port" "$RULES_JSON")
        local ip=$(jq -r ".[$i].server" "$RULES_JSON")
        local bport=$(jq -r ".[$i].server_port" "$RULES_JSON")
        local sni=$(jq -r ".[$i].sni" "$RULES_JSON")
        local path=$(jq -r ".[$i].path" "$RULES_JSON")
        
        # 如果是自动获取的IP，显示为“本机直连 (你的公网IP)”
        if [ "$ip" != "127.0.0.1" ] && [ "$bport" == "-1" ]; then
            local display_ip="${gl_kjlan}本机直连 (${ip})${gl_bai}"
        elif [ "$ip" == "127.0.0.1" ] && [ "$bport" == "-1" ]; then
            local display_ip="${gl_kjlan}本机回环 (127.0.0.1)${gl_bai}"
        else
            local display_ip="${ip}:${bport}"
        fi

        case $type in
            vless-reality) local info="Reality [${sni}] -> ${display_ip}" ;;
            hysteria2) local info="Hy2 (UDP) [${sni}] -> ${display_ip}" ;;
            argo-vless-ws) local info="Argo+WS [${path}] -> ${display_ip}" ;;
            direct) local info="纯转发 -> ${display_ip}" ;;
            *) local info="未知 -> ${display_ip}" ;;
        esac
        printf "${gl_lv}[%d] 端口:%-6s %s${gl_bai}\n" "$i" "$port" "$info"
    done
}

del_rule() {
    view_rules
    [ $(jq 'length' "$RULES_JSON") -eq 0 ] && return 0
    echo "----------------------------------------"
    read -e -p "输入要删除的节点序号 (如 0): " idx
    if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -lt $(jq 'length' "$RULES_JSON") ]; then
        jq "del(.[$idx])" "$RULES_JSON" > "${RULES_JSON".tmp" && mv "${RULES_JSON".tmp" "$RULES_JSON"
        echo -e "${gl_lv}✅ 已删除序号 $idx 的节点${gl_bai}"
    else
        echo -e "${gl_red}序号无效${gl_bai}"
    fi
}

# ============================================================================
# 核心黑科技：多协议动态 JSON 生成引擎 (支持 -1 自动替换为本机端口)
# ============================================================================

build_json() {
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
                json=$(echo "$json" | jq --arg tag "$in_tag" --argjson p "$port" \
                    '.inbounds += [{type:"mixed", tag:$tag, listen:"::", listen_port:$p}]')
                # 【关键逻辑】如果 bport 是 -1，则自动替换为当前监听端口，实现真正的本机直连
                json=$(echo "$json" | jq --arg tag "$out_tag" --argjson p "$port" --argjson rule "$rule" \
                    '.outbounds += [{
                        type: "vless", tag: $tag, 
                        server: (if $rule.server == "-1" then $p else $rule.server end), 
                        server_port: (if $rule.server_port == "-1" then $p else $rule.server_port end),
                        uuid: "00000000-0000-0000-0000-000000000000", flow: "xtls-rprx-vision",
                        tls: {
                            enabled: true, server_name: $rule.sni,
                            utls: { enabled: true, fingerprint: $rule.fingerprint },
                            reality: { enabled: true, public_key: $rule.public_key, short_id: $rule.short_id }
                        }
                    }]')
                ;;
                
            argo-vless-ws)
                json=$(echo "$json" | jq --arg tag "$in_tag" --argjson p "$port" \
                    '.inbounds += [{type:"mixed", tag:$tag, listen:"::", listen_port:$p}]')
                json=$(echo "$json" | jq --arg tag "$out_tag" --argjson p "$port" --argjson rule "$rule" \
                    '.outbounds += [{
                        type: "vless", tag: $tag, 
                        server: (if $rule.server == "-1" then $p else $rule.server end), 
                        server_port: (if $rule.server_port == "-1" then $p else $rule.server_port end),
                        uuid: "00000000-0000-0000-0000-000000000000",
                        transport: { type: "ws", path: $rule.path }
                    }]')
                ;;
                
            hysteria2)
                json=$(echo "$json" | jq --arg tag "$in_tag" --argjson p "$port" \
                    '.inbounds += [{type:"mixed", tag:$tag, listen:"::", listen_port:$p}]')
                json=$(echo "$json" | jq --arg tag "$out_tag" --argjson p "$port" --argjson rule "$rule" \
                    '.outbounds += [{
                        type: "hysteria2", tag: $tag, 
                        server: (if $rule.server == "-1" then $p else $rule.server end), 
                        server_port: (if $rule.server_port == "-1" then $p else $rule.server_port end),
                        password: $rule.password,
                        tls: { enabled: true, server_name: $rule.sni, insecure: true }
                    }]')
                ;;
                
            direct)
                # 纯转发：如果是自动直连模式，把目标地址也替换为本机回环地址
                json=$(echo "$json" | jq --arg tag "$in_tag" --argjson p "$port" --argjson rule "$rule" \
                    '.inbounds += [{
                        type: "direct", tag: $tag, listen:"::", listen_port: $p,
                        override_address: (if $rule.server == "-1" then "127.0.0.1" else $rule.server end), 
                        override_port: (if $rule.server_port == "-1" then $p else $rule.server_port end)
                    }]')
                continue
                ;;
        esac
        
        json=$(echo "$json" | jq --arg in "$in_tag" --arg out "$out_tag" \
            '.route.rules += [{inbound:[$in], outbound:$out}]')
    done
    
    echo "$json" > "$TMP_FILE"
}

apply_config() {
    if [ $(jq 'length' "$RULESJSON") -eq 0 ]; then
        echo -e "${gl_red}错误：节点列表为空！${gl_bai}"; return 1
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
    
    [ $? -eq 0 ] && echo -e "${gl_lv}✅ 配置已热重载！${gl_bai}" || echo -e "${gl_red}❌ 启动失败${gl_bai}"
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
        echo -e "${gl_kjlan}       Sing-Box 多协议管理脚本           "
        echo -e "${gl_kjlan}========================================${gl_bai}"
        echo -e "核心状态: ${core}"
        echo -e "----------------------------------------"
        echo -e "${gl_lv}1. 安装/更新 Sing-Box 核心${gl_bai}"
        echo -e "${gl_huang}2. 节点管理 ${gl_huang}★${gl_bai}"
        echo -e "----------------------------------------"
        echo -e "0. 退出"
        echo -e "${gl_kjlan}========================================${gl_bai}"
        read -e -p "选择: " choice
        case $choice in
            1) install_singbox ;;
            2) node_manager_menu ;;
            0|"") break ;;
        esac
    done
}

main_menu
