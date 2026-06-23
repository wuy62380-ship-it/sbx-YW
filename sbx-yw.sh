#!/usr/bin/env bash
# ============================================================================
# Sing-Box 全自动多协议管理脚本 (上帝模式：自带面板+一键生成客户端链接)
# ============================================================================

# --- 颜色定义 ---
: "${gl_bai:=\033[0m}"
: "${gl_lv:=\033[32m}"
: "${gl_huang:=\033[33m}"
: "${gl_hui:=\033[90m}"
: "${gl_red:=\033[31m}"
: "${gl_kjlan:=\033[32m}"
: "${gl_lan:=\033[34m}"

# --- 核心路径 ---
RULES_JSON="/etc/sing-box/sb-relay-rules.json"
SERVERS_LIST="/etc/sing-box/sb-servers.list"
CONF_FILE="/etc/sing-box/config.json"
TMP_FILE="/tmp/sb-relay-tmp.json"
LINKS_FILE="/etc/sing-box/client_links.txt"

# ============================================================================
# 基础环境与工具函数
# ============================================================================

check_basic_env() {
    if [ "$(id -u)" -ne 0 ]; then echo -e "${gl_red}错误：请使用 root 用户运行${gl_bai}"; exit 1; fi
    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${gl_huang}[环境] 安装 jq...${gl_bai}"
        if command -v apt >/dev/null 2>&1; then apt-get update -qq && apt-get install -y jq -qq
        elif command -v yum >/dev/null 2>&1; then yum install -y jq -q; fi
        [ $? -ne 0 ] && echo -e "${gl_red}jq 安装失败${gl_bai}" && exit 1
    fi
    if ! command -v openssl >/dev/null 2>&1; then
        if command -v apt >/dev/null 2>&1; then apt-get install -y openssl -qq
        elif command -v yum >/dev/null 2>&1; then yum install -y openssl -q; fi
    fi
    mkdir -p /etc/sing-box
    [ ! -f "$RULES_JSON" ] && echo '[]' > "$RULES_JSON"
    [ ! -f "$SERVERS_LIST" ] && touch "$SERVERS_LIST"
    [ ! -f "$LINKS_FILE" ] && touch "$LINKS_FILE"
}

url_encode() {
    echo -n "$1" | jq -sRr @uri
}

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
        
        echo -e "${gl_kjlan}========================================${gl_bai}"
        echo -e "${gl_kjlan}          节 点 与 服 务 管 理            "
        echo -e "${gl_kjlan}========================================${gl_bai}"
        echo -e "核心状态: ${status}  |  规则数量: ${gl_lv}${count}${gl_bai} 个"
        echo -e "----------------------------------------"
        echo -e "${gl_lv}1. 添加节点 (协议 & 工作模式)${gl_bai}"
        echo -e "${gl_hui}2. 落地机管理 (仅用于外部中转)${gl_bai}"
        echo -e "----------------------------------------"
        echo -e "3. 查看当前节点详情"
        echo -e "${gl_kjlan}4. 📋 查看客户端一键导入链接 (v2rayN等)${gl_bai}"
        echo -e "${gl_red}5. 删除指定节点${gl_bai}"
        echo -e "----------------------------------------"
        echo -e "${gl_lv}6. 🧨 校验并应用配置 (热重载) ${gl_huang}★${gl_bai}"
        echo -e "${gl_hui}7. 停止服务${gl_bai}"
        echo -e "----------------------------------------"
        echo -e "0. 返回主菜单"
        echo -e "${gl_kjlan}========================================${gl_bai}"
        read -e -p "请输入选择: " choice
        
        case $choice in
            1) add_node_selector ;;
            2) manage_servers ;;
            3) view_rules; read -rs -n 1 -p "按任意键继续..." ;;
            4) view_links ;;
            5) del_rule; read -rs -n 1 -p "按任意键继续..." ;;
            6) apply_config; read -rs -n 1 -p "按任意键继续..." ;;
            7) systemctl stop sing-box && echo -e "${gl_lv}已停止${gl_bai}"; read -rs -n 1 -p "按任意键继续..." ;;
            0|"") break ;;
            *) echo -e "${gl_red}无效选择${gl_bai}"; sleep 1 ;;
        esac
    done
}

# ============================================================================
# 查看一键导入链接
# ============================================================================

view_links() {
    clear
    echo -e "${gl_kjlan}========================================${gl_bai}"
    echo -e "${gl_kjlan}     客户端一键导入链接 (直接复制粘贴)     "
    echo -e "${gl_kjlan}========================================${gl_bai}"
    if [ ! -s "$LINKS_FILE" ]; then
        echo -e "${gl_hui}暂无链接。请先添加【本机直接落地】模式的节点。${gl_bai}"
    else
        echo -e "${gl_lv}$(grep -v '^$' "$LINKS_FILE")${gl_bai}"
        echo -e "\n${gl_huang}----------------------------------------${gl_bai}"
        echo -e "${gl_hui}提示: 在 v2rayN 中，点击 服务器 -> 从剪贴板导入批量URL。${gl_bai}"
        echo -e "${gl_hui}      手机端 (小火箭等) 直接复制链接，打开APP自动识别。${gl_bai}"
    fi
    echo -e "${gl_kjlan}========================================${gl_bai}"
    read -rs -n 1 -p "按任意键返回..."
}

# ============================================================================
# 落地机池管理
# ============================================================================

manage_servers() {
    while true; do
        clear
        local count=$(grep -vE '^$|#' "$SERVERS_LIST" | wc -l)
        echo -e "${gl_huang}========================================${gl_bai}"
        echo -e "${gl_huang}         外 部 落 地 机 管 理             "
        echo -e "${gl_huang}========================================${gl_bai}"
        echo -e "当前已预设: ${gl_lv}${count}${gl_bai} 台"
        echo -e "----------------------------------------"
        echo -e "${gl_lv}1. 添加落地机${gl_bai}"
        echo -e "${gl_huang}2. 查看列表${gl_bai}"
        echo -e "${gl_red}3. 清空列表${gl_bai}"
        echo -e "0. 返回"
        echo -e "----------------------------------------"
        read -e -p "请输入选择: " choice
        
        case $choice in
            1) 
                read -e -p "别名 (如 美国-01): " name
                read -e -p "IP 地址: " ip
                read -e -p "端口: " port
                if [[ -n "$name" && -n "$ip" && -n "$port" ]]; then
                    echo "$name $ip $port" >> "$SERVERS_LIST"
                    echo -e "${gl_lv}✅ 添加成功${gl_bai}"
                fi
                read -rs -n 1 -p "按任意键继续..." ;;
            2) 
                cat "$SERVERS_LIST" | grep -vE '^$|#'
                read -rs -n 1 -p "按任意键继续..." ;;
            3) echo "" > "$SERVERS_LIST"; echo -e "${gl_lv}已清空${gl_bai}"; read -rs -n 1 -p "按任意键继续..." ;;
            0|"") break ;;
        esac
    done
}

# ============================================================================
# 外部中转选择器
# ============================================================================

select_server() {
    echo -e "\n--- 请选择外部后端 ---"
    echo -e "${gl_lv}1. 从预设列表选择${gl_bai}"
    echo -e "${gl_hui}2. 手动输入 IP 和端口${gl_bai}"
    read -e -p "请选择 (1/2): " s_choice
    
    if [ "$s_choice" == "1" ]; then
        local count=$(grep -vE '^$|#' "$SERVERS_LIST" | wc -l)
        if [ "$count" -eq 0 ]; then echo -e "${gl_red}列表为空，已切为手动输入${gl_bai}"; sleep 1; return 1; fi
        local idx=1
        while IFS=' ' read -r name ip port; do
            [[ -z "$name" || "$name" == "#" ]] && continue
            printf "${gl_lv}%d. %-15s ${gl_hui}(%s:%s)${gl_bai}\n" "$idx" "$name" "$ip" "$port"
            idx=$((idx+1))
        done < "$SERVERS_LIST"
        read -e -p "输入序号: " s_idx
        if [[ "$s_idx" =~ ^[0-9]+$ ]] && [ "$s_idx" -ge 1 ] && [ "$s_idx" -lt "$idx" ]; then
            SERVER_IP=$(grep -vE '^$|#' "$SERVERS_LIST" | sed -n "${s_idx}p" | awk '{print $2}')
            SERVER_PORT=$(grep -vE '^$|#' "$SERVERS_LIST" | sed -n "${s_idx}p" | awk '{print $3}')
            return 0
        else
            return 1
        fi
    else
        return 1
    fi
}

# ============================================================================
# 丝滑添加节点入口
# ============================================================================

add_node_selector() {
    clear
    echo -e "${gl_kjlan}========================================${gl_bai}"
    echo -e "${gl_kjlan}          选择协议与工作模式             "
    echo -e "${gl_kjlan}========================================${gl_bai}"
    echo -e "${gl_lv}1. VLESS + Reality      - 抗审查，无需证书${gl_bai}"
    echo -e "${gl_huang}2. Hysteria2            - 极速 QUIC 协议${gl_bai}"
    echo -e "${gl_kjlan}3. Argo + VLESS + WS    - 隐藏源IP${gl_bai}"
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
    read -rs -n 1 -p "按任意键继续..."
}

# ============================================================================
# 端口校验
# ============================================================================

check_port() {
    if ! [[ "$1" =~ ^[0-9]+$ ]] || [ "$1" -lt 1 ] || [ "$1" -gt 65535 ]; then echo -e "${gl_red}端口格式错误${gl_bai}"; return 1; fi
    if ss -tulnp | grep -q ":${1} "; then echo -e "${gl_red}本机端口 $1 已被占用${gl_bai}"; return 1; fi
}

# ============================================================================
# VLESS + Reality (支持全自动独立落地)
# ============================================================================

add_reality() {
    echo -e "\n${gl_lan}--- VLESS + Reality 配置 ---${gl_bai}"
    read -e -p "本机监听端口 (如 443): " port; check_port "$port" || return 1
    
    echo -e "\n${gl_huang}>>> 请选择工作模式 <<<${gl_bai}"
    echo -e "${gl_lv}1. 中转模式 (转发给其他机器或本机已有面板)${gl_bai}"
    echo -e "${gl_kjlan}2. 本机直接落地 (全自动生成，无需面板) ★小白推荐${gl_bai}"
    read -e -p "请选择 (1/2): " r_mode
    
    if [ "$r_mode" == "2" ]; then
        echo -e "${gl_huang}[全自动] 正在生成密钥对和UUID...${gl_bai}"
        local uuid=$(cat /proc/sys/kernel/random/uuid)
        local priv_key="" pubkey=""
        
        if command -v sing-box >/dev/null 2>&1; then
            local keys=$(sing-box generate reality-keypair 2>/dev/null)
            priv_key=$(echo "$keys" | grep "PrivateKey" | awk '{print $2}')
            pubkey=$(echo "$keys" | grep "PublicKey" | awk '{print $2}')
        elif command -v xray >/dev/null 2>&1; then
            local keys=$(xray x25519 2>/dev/null)
            priv_key=$(echo "$keys" | head -n 1 | awk '{print $3}')
            pubkey=$(echo "$keys" | tail -n 1 | awk '{print $3}')
        fi
        
        if [[ -z "$pubkey" || -z "$priv_key" ]]; then
            echo -e "${gl_red}❌ 生成失败，请确保系统装有 sing-box 核心后再试。${gl_bai}"; return 1
        fi
        
        read -e -p "伪装域名 SNI (直接回车默认 www.microsoft.com): " sni; [[ -z "$sni" ]] && sni="www.microsoft.com"
        read -e -p "TLS 指纹 (直接回车默认 chrome): " fp; [[ -z "$fp" ]] && fp="chrome"
        read -e -p "短ID ShortId (可留空): " short_id
        
        jq --arg type "vless-reality" --argjson port "$port" --arg mode "standalone" \
           --arg uuid "$uuid" --arg priv_key "$priv_key" --arg pubkey "$pubkey" \
           --arg short_id "${short_id:-""}" --arg sni "$sni" --arg fp "$fp" \
           '. += [{"type": $type, "listen_port": $port, "mode": $mode, "uuid": $uuid, "private_key": $priv_key, "public_key": $pubkey, "short_id": $short_id, "sni": $sni, "fingerprint": $fp}]' \
           "$RULES_JSON" > "${RULES_JSON}.tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
           
        local my_ip=$(curl -s --connect-timeout 2 ipinfo.io/ip || echo "你的服务器IP")
        
        # 生成 v2rayN 标准链接
        local enc_sni=$(url_encode "$sni")
        local enc_fp=$(url_encode "$fp")
        local enc_pbk=$(url_encode "$pubkey")
        local enc_sid=$(url_encode "$short_id")
        local link="vless://${uuid}@${my_ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${enc_sni}&fp=${enc_fp}&pbk=${enc_pbk}&sid=${enc_sid}&type=tcp#Reality-${my_ip}"
        
        echo -e "\n${gl_lv}✅ 节点已生成！请复制下方链接直接导入 v2rayN/小火箭:${gl_bai}"
        echo -e "${gl_huang}==================================================${gl_bai}"
        echo -e "${gl_kjlan}${link}${gl_bai}"
        echo -e "${gl_huang}==================================================${gl_bai}"
        
        # 保存链接到文件
        echo "$link" >> "$LINKS_FILE"
        
    else
        if select_server; then
            local ip="$SERVER_IP"; local bport="$SERVER_PORT"
        else
            read -e -p "后端 IP (如 127.0.0.1): " ip; [[ -z "$ip" ]] && echo -e "${gl_red}IP为空${gl_bai}" && return 1
            read -e -p "后端端口: " bport
            if ! [[ "$bport" =~ ^[0-9]+$ ]] || [ "$bport" -lt 1 ] || [ "$bport" -gt 65535 ]; then echo -e "${gl_red}端口错误${gl_bai}"; return 1; fi
        fi
        
        read -e -p "后端的 Reality 公钥 (输入 G 自动生成一对): " pubkey
        if [[ "$pubkey" =~ ^[Gg]$ ]]; then
            local keys=$(sing-box generate reality-keypair 2>/dev/null || xray x25519 2>/dev/null)
            priv_key=$(echo "$keys" | grep "Private" | awk '{print $NF}')
            pubkey=$(echo "$keys" | grep "Public" | awk '{print $NF}')
            echo -e "${gl_red}⚠️  请将此私钥填入你的后端面板: ${gl_kjlan}${priv_key}${gl_bai}"
            read -rs -n 1 -p "按任意键继续..."
        elif [[ -z "$pubkey" ]]; then
            echo -e "${gl_red}公钥不能为空！${gl_bai}"; return 1
        fi
        
        read -e -p "短ID (需与后端一致): " short_id
        read -e -p "SNI: " sni; [[ -z "$sni" ]] && sni="www.microsoft.com"
        read -e -p "Fingerprint: " fp; [[ -z "$fp" ]] && fp="chrome"

        jq --arg type "vless-reality" --argjson port "$port" --arg mode "relay" \
           --arg ip "$ip" --argjson bport "$bport" --arg pubkey "$pubkey" --arg short_id "${short_id:-""}" --arg sni "$sni" --arg fp "$fp" \
           '. += [{"type": $type, "listen_port": $port, "mode": $mode, "server": $ip, "server_port": $bport, "public_key": $pubkey, "short_id": $short_id, "sni": $sni, "fingerprint": $fp}]' \
           "$RULES_JSON" > "${RULES_JSON}.tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
           
        echo -e "${gl_lv}✅ Reality 中转规则添加成功！${gl_bai}"
    fi
}

# ============================================================================
# Hysteria2 (支持全自动独立落地)
# ============================================================================

add_hysteria2() {
    echo -e "\n${gl_lan}--- Hysteria 2 配置 ---${gl_bai}"
    read -e -p "本机监听端口 (UDP, 如 8443): " port; check_port "$port" || return 1
    
    echo -e "\n${gl_huang}>>> 请选择工作模式 <<<${gl_bai}"
    echo -e "${gl_lv}1. 中转模式${gl_bai}"
    echo -e "${gl_kjlan}2. 本机直接落地 (全自动生成) ★小白推荐${gl_bai}"
    read -e -p "请选择 (1/2): " h_mode
    
    if [ "$h_mode" == "2" ]; then
        local pass=$(openssl rand -base64 16)
        read -e -p "伪装域名 SNI (如 www.bing.com): " sni; [[ -z "$sni" ]] && sni="www.bing.com"
        
        jq --arg type "hysteria2" --argjson port "$port" --arg mode "standalone" \
           --arg pass "$pass" --arg sni "$sni" \
           '. += [{"type": $type, "listen_port": $port, "mode": $mode, "password": $pass, "sni": $sni}]' \
           "$RULES_JSON" > "${RULES_JSON}.tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
           
        local my_ip=$(curl -s --connect-timeout 2 ipinfo.io/ip || echo "你的服务器IP")
        
        # 生成标准链接
        local enc_pass=$(url_encode "$pass")
        local enc_sni=$(url_encode "$sni")
        local link="hysteria2://${enc_pass}@${my_ip}:${port}?sni=${enc_sni}&insecure=1#Hy2-${my_ip}"
        
        echo -e "\n${gl_lv}✅ Hy2 节点已生成！(注:因无证书，使用了 insecure 模式)${gl_bai}"
        echo -e "${gl_huang}==================================================${gl_bai}"
        echo -e "${gl_kjlan}${link}${gl_bai}"
        echo -e "${gl_huang}==================================================${gl_bai}"
        
        echo "$link" >> "$LINKS_FILE"
    else
        if select_server; then
            local ip="$SERVER_IP"; local bport="$SERVER_PORT"
        else
            read -e -p "后端 IP: " ip; [[ -z "$ip" ]] && return 1
            read -e -p "后端端口: " bport
            if ! [[ "$bport" =~ ^[0-9]+$ ]] || [ "$bport" -lt 1 ] || [ "$bport" -gt 65535 ]; then return 1; fi
        fi
        read -e -p "密码: " pass; [[ -z "$pass" ]] && return 1
        read -e -p "SNI: " sni; [[ -z "$sni" ]] && sni="www.bing.com"

        jq --arg type "hysteria2" --argjson port "$port" --arg mode "relay" --arg ip "$ip" --argjson bport "$bport" \
           --arg pass "$pass" --arg sni "$sni" \
           '. += [{"type": $type, "listen_port": $port, "mode": $mode, "server": $ip, "server_port": $bport, "password": $pass, "sni": $sni}]' \
           "$RULES_JSON" > "${RULES_JSON}.tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
        echo -e "${gl_lv}✅ Hy2 中转规则添加成功${gl_bai}"
    fi
}

# ============================================================================
# Argo + VLESS + WS (支持全自动独立落地)
# ============================================================================

add_argo_vless_ws() {
    echo -e "\n${gl_lan}--- Argo + VLESS + WS 配置 ---${gl_bai}"
    read -e -p "本机监听端口 (如 8080): " port; check_port "$port" || return 1
    
    echo -e "\n${gl_huang}>>> 请选择工作模式 <<<${gl_bai}"
    echo -e "${gl_lv}1. 中转模式${gl_bai}"
    echo -e "${gl_kjlan}2. 本机直接落地 (配合 CF Argo 使用) ★${gl_bai}"
    read -e -p "请选择 (1/2): " a_mode
    
    if [ "$a_mode" == "2" ]; then
        local uuid=$(cat /proc/sys/kernel/random/uuid)
        read -e -p "WebSocket 路径 (如 /ray): " path; [[ -z "$path" ]] && path="/ray"
        
        jq --arg type "argo-vless-ws" --argjson port "$port" --arg mode "standalone" \
           --arg uuid "$uuid" --arg path "$path" \
           '. += [{"type": $type, "listen_port": $port, "mode": $mode, "uuid": $uuid, "path": $path}]' \
           "$RULES_JSON" > "${RULES_JSON}.tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
           
        # 注意：Argo 的 IP 需要用户自己替换为 Cloudflare 分配的临时域名或优选域名
        local link="vless://${uuid}@你的CF域名:443?encryption=none&security=tls&type=ws&host=你的CF域名&path=$(url_encode "$path")#Argo-WS"
        
        echo -e "\n${gl_lv}✅ Argo 后端已生成！${gl_bai}"
        echo -e "${gl_red}⚠️  请先在 Cloudflare 中开启 Argo 隧道指向 127.0.0.1:${port}${gl_bai}"
        echo -e "${gl_huang}==================================================${gl_bai}"
        echo -e "${gl_hui}请将下方链接中的【你的CF域名】替换为 Argo 分配的域名后再导入:${gl_bai}"
        echo -e "${gl_kjlan}${link}${gl_bai}"
        echo -e "${gl_huang}==================================================${gl_bai}"
        
        echo "$link" >> "$LINKS_FILE"
    else
        if select_server; then
            local ip="$SERVER_IP"; local bport="$SERVER_PORT"
        else
            read -e -p "后端 IP/域名: " ip; [[ -z "$ip" ]] && return 1
            read -e -p "后端端口: " bport
            if ! [[ "$bport" =~ ^[0-9]+$ ]] || [ "$bport" -lt 1 ] || [ "$bport" -gt 65535 ]; then return 1; fi
        fi
        read -e -p "WebSocket 路径: " path; [[ -z "$path" ]] && path="/"

        jq --arg type "argo-vless-ws" --argjson port "$port" --arg mode "relay" --arg ip "$ip" --argjson bport "$bport" --arg path "$path" \
           '. += [{"type": $type, "listen_port": $port, "mode": $mode, "server": $ip, "server_port": $bport, "path": $path}]' \
           "$RULES_JSON" > "${RULES_JSON}.tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
        echo -e "${gl_lv}✅ Argo 中转规则添加成功${gl_bai}"
    fi
}

# ============================================================================
# 查看与删除
# ============================================================================

view_rules() {
    echo -e "${gl_huang}----------------------------------------${gl_bai}"
    echo -e "${gl_huang}         当前节点与服务状态              "
    echo -e "${gl_huang}----------------------------------------${gl_bai}"
    local count=$(jq 'length' "$RULES_JSON")
    if [ "$count" -eq 0 ]; then echo -e "${gl_hui}暂无节点${gl_bai}"; return 0; fi
    
    for ((i=0; i<count; i++)); do
        local type=$(jq -r ".[$i].type" "$RULES_JSON")
        local mode=$(jq -r ".[$i].mode" "$RULES_JSON")
        local port=$(jq -r ".[$i].listen_port" "$RULES_JSON")
        
        local mode_str=""
        local info=""
        if [ "$mode" == "standalone" ]; then
            mode_str="${gl_kjlan}[本机落地直连]${gl_bai}"
        else
            mode_str="${gl_hui}[中转]${gl_bai}"
            local ip=$(jq -r ".[$i].server" "$RULES_JSON")
            local bport=$(jq -r ".[$i].server_port" "$RULES_JSON")
            [ "$ip" == "-1" ] && ip="127.0.0.1"
            [ "$bport" == "-1" ] && bport="$port"
            mode_str+=" -> ${ip}:${bport}"
        fi

        case $type in
            vless-reality) 
                info="Reality $(jq -r ".[$i].sni" "$RULES_JSON")" 
                [ "$mode" == "standalone" ] && info+=" | PublicKey: $(jq -r ".[$i].public_key" "$RULES_JSON")"
                ;;
            hysteria2) info="Hy2(UDP) $(jq -r ".[$i].sni" "$RULES_JSON")" 
                [ "$mode" == "standalone" ] && info+=" | Pass: $(jq -r ".[$i].password" "$RULES_JSON")"
                ;;
            argo-vless-ws) info="Argo+WS $(jq -r ".[$i].path" "$RULES_JSON")" 
                [ "$mode" == "standalone" ] && info+=" | UUID: $(jq -r ".[$i].uuid" "$RULES_JSON")"
                ;;
            *) info="未知协议" ;;
        esac
        printf "${gl_lv}[%d] 端口:%-6s %-20s %s${gl_bai}\n" "$i" "$port" "$mode_str" "$info"
    done
}

del_rule() {
    view_rules
    [ $(jq 'length' "$RULES_JSON") -eq 0 ] && return 0
    echo "----------------------------------------"
    read -e -p "输入要删除的节点序号 (如 0): " idx
    if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -lt $(jq 'length' "$RULES_JSON") ]; then
        jq "del(.[$idx])" "$RULES_JSON" > "${RULES_JSON}.tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
        echo -e "${gl_lv}✅ 已删除${gl_bai}"
    else
        echo -e "${gl_red}序号无效${gl_bai}"
    fi
}

# ============================================================================
# 核心引擎：多协议动态 JSON 生成 (区分 Standalone 与 Relay)
# ============================================================================

build_json() {
    local json=$(jq -n '{log:{level:"error"}, inbounds:[], outbounds:[{type:"direct", tag:"direct"}], route:{rules:[], final:"direct"}}')
    local count=$(jq 'length' "$RULES_JSON")
    
    for ((i=0; i<count; i++)); do
        local rule=$(jq ".[$i]" "$RULES_JSON")
        local type=$(echo "$rule" | jq -r '.type')
        local mode=$(echo "$rule" | jq -r '.mode')
        local port=$(echo "$rule" | jq -r '.listen_port')
        local in_tag="in-${port}"
        
        case "$type" in
            vless-reality)
                if [ "$mode" == "standalone" ]; then
                    json=$(echo "$json" | jq --argjson rule "$rule" --arg tag "$in_tag" \
                        '.inbounds += [{
                            type: "vless", tag: $tag, listen: "::", listen_port: $rule.listen_port,
                            uuid: $rule.uuid, flow: "xtls-rprx-vision",
                            tls: {
                                enabled: true, server_name: $rule.sni,
                                utls: { enabled: true, fingerprint: $rule.fingerprint },
                                reality: { enabled: true, private_key: $rule.private_key, short_id: [$rule.short_id] }
                            }
                        }]')
                else
                    local out_tag="out-${port}"
                    json=$(echo "$json" | jq --arg tag "$in_tag" --argjson p "$port" \
                        '.inbounds += [{type:"mixed", tag:$tag, listen:"::", listen_port:$p}]')
                    json=$(echo "$json" | jq --arg tag "$out_tag" --argjson p "$port" --argjson rule "$rule" \
                        '.outbounds += [{
                            type: "vless", tag: $tag, 
                            server: (if $rule.server == "-1" then "127.0.0.1" else $rule.server end), 
                            server_port: (if $rule.server_port == -1 then $p else $rule.server_port end),
                            uuid: "00000000-0000-0000-0000-000000000000", flow: "xtls-rprx-vision",
                            tls: {
                                enabled: true, server_name: $rule.sni,
                                utls: { enabled: true, fingerprint: $rule.fingerprint },
                                reality: { enabled: true, public_key: $rule.public_key, short_id: $rule.short_id }
                            }
                        }]')
                    json=$(echo "$json" | jq --arg in "$in_tag" --arg out "$out_tag" '.route.rules += [{inbound:[$in], outbound:$out}]')
                fi
                ;;
                
            hysteria2)
                if [ "$mode" == "standalone" ]; then
                    json=$(echo "$json" | jq --argjson rule "$rule" --arg tag "$in_tag" \
                        '.inbounds += [{
                            type: "hysteria2", tag: $tag, listen: "::", listen_port: $rule.listen_port,
                            password: $rule.password,
                            tls: { enabled: true, server_name: $rule.sni, insecure: true }
                        }]')
                else
                    local out_tag="out-${port}"
                    json=$(echo "$json" | jq --arg tag "$in_tag" --argjson p "$port" \
                        '.inbounds += [{type:"mixed", tag:$tag, listen:"::", listen_port:$p}]')
                    json=$(echo "$json" | jq --arg tag "$out_tag" --argjson p "$port" --argjson rule "$rule" \
                        '.outbounds += [{
                            type: "hysteria2", tag: $tag, 
                            server: (if $rule.server == "-1" then "127.0.0.1" else $rule.server end), 
                            server_port: (if $rule.server_port == -1 then $p else $rule.server_port end),
                            password: $rule.password,
                            tls: { enabled: true, server_name: $rule.sni, insecure: true }
                        }]')
                    json=$(echo "$json" | jq --arg in "$in_tag" --arg out "$out_tag" '.route.rules += [{inbound:[$in], outbound:$out}]')
                fi
                ;;
                
            argo-vless-ws)
                if [ "$mode" == "standalone" ]; then
                    json=$(echo "$json" | jq --argjson rule "$rule" --arg tag "$in_tag" \
                        '.inbounds += [{
                            type: "vless", tag: $tag, listen: "::", listen_port: $rule.listen_port,
                            uuid: $rule.uuid,
                            transport: { type: "ws", path: $rule.path }
                        }]')
                else
                    local out_tag="out-${port}"
                    json=$(echo "$json" | jq --arg tag "$in_tag" --argjson p "$port" \
                        '.inbounds += [{type:"mixed", tag:$tag, listen:"::", listen_port:$p}]')
                    json=$(echo "$json" | jq --arg tag "$out_tag" --argjson p "$port" --argjson rule "$rule" \
                        '.outbounds += [{
                            type: "vless", tag: $tag, 
                            server: (if $rule.server == "-1" then "127.0.0.1" else $rule.server end), 
                            server_port: (if $rule.server_port == -1 then $p else $rule.server_port end),
                            uuid: "00000000-0000-0000-0000-000000000000",
                            transport: { type: "ws", path: $rule.path }
                        }]')
                    json=$(echo "$json" | jq --arg in "$in_tag" --arg out "$out_tag" '.route.rules += [{inbound:[$in], outbound:$out}]')
                fi
                ;;
        esac
    done
    
    echo "$json" > "$TMP_FILE"
}

apply_config() {
    if [ $(jq 'length' "$RULES_JSON") -eq 0 ]; then
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
    systemctl restart sing-box
    
    [ $? -eq 0 ] && echo -e "${gl_lv}✅ 配置已重载，服务运行中！${gl_bai}" || echo -e "${gl_red}❌ 启动失败，请运行 journalctl -u sing-box -n 20 查看日志${gl_bai}"
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
        echo -e "${gl_kjlan}    Sing-Box 全自动节点管理脚本         "
        echo -e "${gl_kjlan}========================================${gl_bai}"
        echo -e "核心状态: ${core}"
        echo -e "----------------------------------------"
        echo -e "${gl_lv}1. 安装/更新 Sing-Box 核心${gl_bai}"
        echo -e "${gl_huang}2. 节点与服务管理${gl_bai}"
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
