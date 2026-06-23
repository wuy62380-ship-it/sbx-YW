#!/usr/bin/env bash
# ============================================================================
# Sing-Box 多协议管理脚本 (终极防崩溃版：修复文件名拼写错误)
# ============================================================================

RULES_JSON="/etc/sing-box/sb-relay-rules.json"
SERVERS_LIST="/etc/sing-box/sb-servers.list"
CONF_FILE="/etc/sing-box/config.json"
TMP_FILE="/tmp/sb-relay-tmp.json"
LINKS_FILE="/etc/sing-box/client_links.txt"

: "${gl_bai:=\033[0m}" "${gl_lv:=\033[32m}" "${gl_huang:=\033[33m}" "${gl_hui:=\033[90m}" "${gl_red:=\033[31m}" "${gl_kjlan:=\033[32m}" "${gl_lan:=\033[34m}"

check_env() {
    [ "$(id -u)" -ne 0 ] && echo -e "${gl_red}请使用 root 运行${gl_bai}" && exit 1
    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${gl_huang}安装 jq...${gl_bai}"
        if command -v apt >/dev/null 2>&1; then apt-get update -qq && apt-get install -y jq -qq
        elif command -v yum >/dev/null 2>&1; then yum install -y jq -q; fi
    fi
    if ! command -v openssl >/dev/null 2>&1; then
        if command -v apt >/dev/null 2>&1; then apt-get install -y openssl -qq
        elif command -v  yum >/dev/null 2>&1; then yum install -y openssl -q; fi
    fi
    mkdir -p /etc/sing-box
    [ ! -f "$SERVERS_LIST" ] && touch "$SERVERS_LIST"
    [ ! -f "$LINKS_FILE" ] && touch "$LINKS_FILE"
    
    # 救命修复：如果 rules.json 被 shell 截断污染，自动清空它
    if ! jq empty "$RULES_JSON" >/dev/null 2>&1; then
        echo "[]" > "$RULES_JSON"
    fi
}

url_encode() { echo -n "$1" | jq -sRr @uri; }

select_sni() {
    echo ""
    echo "--- 伪装域名 (SNI) 设置 ---"
    echo "1. 使用默认伪装域名"
    echo "2. 自动优选最佳域名"
    echo "3. 手动输入域名"
    read -e -p "请选择 (1/2/3): " c
    case $c in
        1) echo "www.microsoft.com" ;;
        2) 
            echo -e "${gl_huang}[测试中]...${gl_bai}"
            local d="www.microsoft.com" t=9999
            for i in "www.apple.com" "dl.google.com" "www.amazon.com"; do
                local n=$(curl -o /dev/null -s -w '%{time_connect}' --max-time 1 -4 "https://$i" 2>/dev/null| awk '{printf "%d",$1*1000}')
                [ -n "$n" ] && [ "$n" -lt "$t" ] && t=$n d=$i
            done
            echo -e "${gl_lv}选用: $d${gl_bai}"
            echo "$d" ;;
        3) read -e -p "输入域名: " s; echo "${s:-www.microsoft.com}" ;;
        *) echo "www.microsoft.com" ;;
    esac
}

install_core() {
    echo -e "${gl_huang}正在连接官方源安装...${gl_bai}"
    if command -v apt >/dev/null 2>&1; then curl -fsSL https://sing-box.app/deb-install.sh | bash
    elif command -v yum >/dev/null 2>&1; then curl -fsSL https://sing-box.app/rpm-install.sh | bash
    else echo -e "${gl_red}不支持该系统${gl_bai}"; fi
    read -rs -n 1 -p "按任意键返回..."
}

add_node_menu() {
    while true; do
        clear
        echo -e "${gl_kjlan}========================================${gl_bai}"
        echo -e "${gl_kjlan}          添加节点向导                  "
        echo -e "${gl_kjlan}========================================${gl_bai}"
        echo -e "${gl_lv}1. VLESS + Reality      - 抗审查，无需证书${gl_bai}"
        echo -e "${gl_huang}2. Hysteria2            - 极速 QUIC 协议${gl_bai}"
        echo -e "${gl_kjlan}3. Argo + VLESS + WS    - 隐藏源IP${gl_bai}"
        echo -e "${gl_hui}4. 纯端口转发 (TCP/UDP 穿透)${gl_bai}"
        echo -e "----------------------------------------"
        echo -e "0. 返回主菜单"
        echo -e "${gl_kjlan}========================================${gl_bai}"
        read -e -p "请选择协议: " p
        case $p in
            1) add_reality ;;
            2) add_hy2 ;;
            3) add_argo ;;
            4) add_direct ;;
            0|"") break ;;
            *) echo -e "${gl_red}无效选择${gl_bai}"; sleep 1 ;;
        esac
        read -rs -n 1 -p "按任意键继续..."
    done
}

add_reality() {
    echo -e "\n${gl_lan}--- VLESS + Reality 配置 ---${gl_bai}"
    read -e -p "本机监听端口 (如 443): " port
    [[ ! "$port" =~ ^[0-9]+$ ]] && echo -e "${gl_red}端口错误${gl_bai}" && return
    
    echo -e "\n>>> 请选择工作模式 <<<"
    echo -e "${gl_lv}1. 本机直接落地 (全自动生成) ★推荐${gl_bai}"
    echo -e "${gl_hui}2. 中转到其他机器${gl_bai}"
    read -e -p "请选择 (1/2): " m
    
    if [ "$m" == "1" ]; then
        echo -e "${gl_huang}[全自动] 生成密钥和UUID...${gl_bai}"
        local uuid=$(cat /proc/sys/kernel/random/uuid)
        local keys=$(sing-box generate reality-keypair 2>/dev/null)
        local pk=$(echo "$keys" | grep PrivateKey | awk '{print $2}')
        local pub=$(echo "$keys" | grep PublicKey | awk '{print $2}')
        [ -z "$pub" ] && echo -e "${gl_red}生成失败，请检查核心${gl_bai}" && return
        
        local sni=$(select_sni)
        read -e -p "TLS 指纹 (直接回车默认 chrome): " fp; [ -z "$fp" ] && fp="chrome"
        read -e -p "短ID ShortId (可留空): " sid
        
        jq --arg p "$port" --arg u "$uuid" --arg pk "$pk" --arg pub "$pub" --arg sid "$sid" --arg sni "$sni" --arg fp "$fp" \
           '. += [{"type":"vless-reality","port":$p|tonumber,"mode":"standalone","uuid":$u,"priv_key":$pk,"pub_key":$pub,"sid":$sid,"sni":$sni,"fp":$fp}]' \
           "$RULES_JSON" > "${RULES_JSON}.tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
        echo -e "${gl_lv}✅ Reality 节点添加成功！${gl_bai}"
    else
        read -e -p "后端IP: " ip; [ -z "$ip" ] && echo -e "${gl_red}IP为空${gl_bai}" && return
        read -e -p "后端端口: " bp; [[ ! "$bp" =~ ^[0-9]+$ ]] && echo -e "${gl_red}端口错误${gl_bai}" && return
        read -e -p "后端公钥 (输入 G 自动生成一对): " pub
        if [ "$pub" = "G" ]; then
            local keys=$(sing-box generate reality-keypair 2>/dev/null)
            pk=$(echo "$keys" | grep PrivateKey | awk '{print $2}')
            pub=$(echo "$keys" | grep PublicKey | awk '{print $2}')
            echo -e "${gl_red}⚠️  请将此私钥填入后端面板: ${gl_kjlan}${pk}${gl_bai}"
            read -rs -n 1 -p "已复制私钥？按任意键继续..."
        elif [ -z "$pub" ]; then
            echo -e "${gl_red}公钥不能为空！${gl_bai}"; return
        fi
        read -e -p "短ID: " sid
        local sni=$(select_sni)
        read -e -p "指纹 (直接回车 chrome): " fp; [ -z "$fp" ] && fp="chrome"
        
        jq --arg p "$port" --arg ip "$ip" --arg bp "$bp" --arg pub "$pub" --arg sid "$sid" --arg sni "$sni" --arg fp "$fp" \
           '. += [{"type":"vless-reality","port":$p|tonumber,"mode":"relay","ip":"$ip","bp":$bp|tonumber,"pub_key":$pub,"sid":$sid,"sni":$sni,"fp":$fp}]' \
           "$RULES_JSON" > "${RULES_JSON}.tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
        echo -e "${gl_lv}✅ 中转规则添加成功！${gl_bai}"
    fi
}

add_hy2() {
    echo -e "\n${gl_lan}--- Hysteria 2 配置 ---${gl_bai}"
    read -e -p "本机监听 UDP 端口 (如 8443): " port
    [[ ! "$port" =~ ^[0-9]+$ ]] && echo -e "${gl_red}错误${gl_bai}" && return
    echo -e "\n>>> 请选择工作模式 <<<"
    echo -e "${gl_lv}1. 本机直接落地 (自动生成证书) ★${gl_bai}"
    echo -e "${gl_hui}2. 中转模式${gl_bai}"
    read -e -p "请选择 (1/2): " m
    local sni=$(select_sni)
    
    if [ "$m" == "1" ]; then
        local pass=$(openssl rand -base64 16)
        [ ! -f "/etc/sing-box/hy2.crt" ] && openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/singbing-box/hy2.key -out /etc/sing-box/hy2.crt -subj "/CN=$sni" -days 3650 2>/dev/null
        jq --arg p "$port" --arg pass "$pass" --arg sni "$sni" \
           '. += [{"type":"hysteria2","port":$p|tonumber,"mode":"standalone","pass":"$pass","sni":"$sni"}]' \
           "$RULES_JSON" > "${RULES_JSON}.tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
        echo -e "${gl_lv}✅ Hy2 节点添加成功！${gl_bai}"
    else
        read -e -p "后端IP: " ip; [ -z "$ip" ] && return
        read -e -p "后端端口: " bp; [[ ! "$bp" =~ ^[0-9]+$ ]] && return
        read -e -p "密码: " pass; [ -z "$pass" ] && return
        # 👇 修复点：这里之前把 ${gl_bai}.tmp 错写成了临时文件名，已修正为 ${RULES_JSON}.tmp
        jq --arg p "$port" --arg ip "$ip" --arg bp "$bp" --arg pass "$pass" --arg sni "$sni" \
           '. += [{"type":"hysteria2","port":$p|tonumber,"mode":"relay","ip":"$ip","bp":$bp|tonumber,"pass":"$pass","sni":"$sni"}]' \
           "$RULES_JSON" > "${RULES_JSON}.tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
        echo -e "${gl_lv}✅ 中转规则添加成功${gl_bai}"
    fi
}

add_argo() {
    echo -e "\n${gl_lan}--- Argo + VLESS + WS 配置 ---${gl_bai}"
    read -e -p "本机监听端口 (如 8080): " port
    [[ ! "$port" =~ ^[0-9]+$ ]] && echo -e "${gl_red}错误${gl_bai}" && return
    echo -e "\n>>> 请选择工作模式 <<<"
    echo -e "${gl_lv}1. 本机直接落地 ★${gl_bai}"
    echo -e "${gl_hui}2. 中转模式${gl_bai}"
    read -e -p "请选择 (1/2): " m
    read -e -p "WS路径 (如 /ray): " path; [ -z "$path" ] && path="/ray"
    
    if [ "$m" == "1" ]; then
        local uuid=$(cat /proc/sys/kernel/random/uuid)
        jq --arg p "$port" --arg u "$uuid" --arg path "$path" \
           '. += [{"type":"argo","port":$p|tonumber,"mode":"standalone","uuid":"$u","path":"$path"}]' \
           "$RULES_JSON" > "${RULES_JSON}.tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
        echo -e "${gl_lv}✅ Argo 后端添加成功！${gl_bai}"
    else
        read -e -p "后端IP/域名: " ip; [ -z "$ip" ] && return
        read -e -p "后端端口: " bp; [[ ! "$bp" =~ ^[0-9]+$ ]] && return
        jq --arg p "$port" --arg ip "$ip" --arg bp "$bp" --arg path "$path" \
           '. += [{"type":"argo","port":$p|tonumber,"mode":"relay","ip":"$ip","bp":$bp|tonumber,"path":"$path"}]' \
           "$RULES_JSON" > "${RULES_JSON}.tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
        echo -e "${gl_lv}✅ 中转规则添加成功${gl_bai}"
    fi
}

add_direct() {
    echo -e "\n${gl_lan}--- 纯端口转发配置 ---${gl_bai}"
    read -e -p "本机监听端口: " port; [[ ! "$port" =~ ^[0-9]+$ ]] && return
    read -e -p "后端目标 IP: " ip; [ -z "$ip" ] && return
    read -e -p "后端目标端口: " bp; [[ ! "$bp" =~ ^[0-9]+$ ]] && return
    jq --arg p "$port" --arg ip "$ip" --arg bp "$bp" \
       '. += [{"type":"direct","port":$p|tonumber,"ip":"$ip","bp":$bp|tonumber}]' \
       "$RULES_JSON" > "${RULES_JSON}.tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
    echo -e "${gl_lv}✅ 纯转发节点添加成功${gl_bai}"
}

view_nodes() {
    echo -e "${gl_huang}----------------------------------------${gl_bai}"
    local count=$(jq 'length' "$RULES_JSON")
    if [ "$count" -eq 0 ]; then echo -e "${gl_hui}暂无节点${gl_bai}"; return; fi
    for ((i=0; i<count; i++)); do
        local type=$(jq -r ".[$i].type" "$RULES_JSON")
        local mode=$(jq -r ".[$i].mode" "$RULES_JSON")
        local port=$(jq -r ".[$i].port" "$RULES_JSON")
        local m_str=""; [ "$mode" == "standalone" ] && m_str="${gl_kjlan}[本机落地]${gl_bai}" || m_str="${gl_hui}[中转]${gl_bai}"
        printf "${gl_lv}[%d] 端口: %-6s %-12s %s${gl_bai}\n" "$i" "$port" "$m_str" "$type"
    done
}

view_links() {
    > "$LINKS_FILE"
    local ip=$(curl -s --connect-timeout 2 ipinfo.io/ip 2>/dev/null || echo "你的服务器IP")
    local has=0
    echo -e "${gl_kjlan}========================================${gl_bai}"
    echo -e "       客户端一键导入链接 (实时同步)       "
    echo -e "${gl_kjlan}========================================${gl_bai}"
    
    for ((i=0; i<$(jq 'length' "$RULES_JSON"); i++)); do
        local mode=$(jq -r ".[$i].mode" "$RULES_JSON")
        [ "$mode" != "standalone" ] && continue
        local type=$(jq -r ".[$i].type" "$RULES_JSON")
        local link=""
        
        if [ "$type" == "vless-reality" ]; then
            local uuid=$(jq -r ".[$i].uuid" "$RULES_JSON")
            local port=$(jq -r ".[$i].port" "$RULES_JSON")
            local sni=$(jq -r ".[$i].sni" "$RULES_JSON")
            local fp=$(jq -r ".[$i].fp" "$RULES_JSON")
            local pub=$(jq -r ".[$i].pub_key" "$RULES_JSON")
            local sid=$(jq -r ".[$i].sid" "$RULES_JSON")
            link="vless://${uuid}@${ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(url_encode "$sni")&fp=$(url_encode "$fp")&pbk=$(url_encode "$pub")&sid=$(url_encode "$sid")&type=tcp#Reality-${port}"
        fi
        
        if [ -n "$link" ]; then
            echo -e "${gl_kjlan}${link}${gl_bai}" | tee -a "$LINKS_FILE"
            has=1
        fi
    done
    
    if [ "$has" -eq 0 ]; then echo -e "${gl_hui}暂无可用链接，请先添加【本机直接落地】节点。${gl_bai}"; fi
    echo -e "${gl_kjlan}========================================${gl_bai}"
}

del_node() {
    view_nodes
    [ $(jq 'length' "$RULES_JSON") -eq 0 ] && return
    read -e -p "输入要删除的序号 (从0开始): " idx
    if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -lt $(jq 'length' "$RULES_JSON") ]; then
        jq "del(.[$idx])" "$RULES_JSON" > "${RULES_JSON}.tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
        echo -e "${gl_lv}✅ 已删除${gl_bai}"
    else
        echo -e "${gl_red}序号无效${gl_bai}"
    fi
}

# ============================================================================
# 🌟 终极稳健引擎：纯原生 jq 索引循环 (绝不断裂)
# ============================================================================

apply_config() {
    if ! jq empty "$RULES_JSON" >/dev/null 2>&1; then
        echo -e "${gl_red}检测到节点配置被意外污染，已自动清空！请重新添加节点。${gl_bai}"
        echo "[]" > "$RULES_JSON"
        read -rs -n 1 -p "按任意键返回..."
        return
    fi

    if [ $(jq 'length' "$RULES_JSON") -eq 0 ]; then
        echo -e "${gl_red}错误：节点列表为空！${gl_bai}"; read -rs -n 1 -p "按任意键返回..."; return
    fi
    
    echo -e "${gl_lv}[1/3] 正在生成 JSON (纯原生jq引擎，杜绝断字)...${gl_bai}"
    local json=$(jq -n '{log:{level:"error"},inbounds:[],outbounds:[{type:"direct",tag:"direct"}],route:{rules:[],final:"direct"}}')
    local count=$(jq 'length' "$RULES_JSON")
    
    # 绝不使用 for row in，改用索引循环，从根本上切断字符串截断风险
    for ((i=0; i<count; i++)); do
        local type=$(jq -r ".[$i].type" "$RULES_JSON")
        local mode=$(jq -r ".[$i].mode" "$RULES_JSON")
        local port=$(jq -r ".[$i].port" "$RULES_JSON")
        local in_tag="in-${port}"
        local out_tag="out-${port}"
        
        if [ "$type" == "vless-reality" ]; then
            if [ "$mode" == "standalone" ]; then
                json=$(echo "$json" | jq --argjson p "$port" --arg u "$(jq -r ".[$i].uuid" "$RULES_JSON")" --arg pk "$(jq -r ".[$i].priv_key" "$RULES_JSON")" --arg pub "$(jq -r ".[$i].pub_key" "$RULES_JSON")" --arg sid "$(jq -r ".[$i].sid" "$RULES_JSON")" --arg sni "$(jq -r ".[$i].sni" "$RULES_JSON")" --arg fp "$(jq -r ".[$i].fp" "$RULES_JSON")" \
                '.inbounds += [{
                    "type": "vless", "tag": $in_tag, "listen": "::", "listen_port": $p, "uuid": $u,
                    "tls": {
                        "enabled": true, "server_name": $sni, "utls": {"enabled": true, "fingerprint": $fp}
                    },
                    "reality": {
                        "enabled": true, "private_key": $pk
                    } + (if $sid != "" then {"short_id": [$sid]} else {} end)
                }]')
            else
                json=$(echo "$json" | jq --arg tag "$in_tag" --argjson p "$port" --arg ip "$(jq -r ".[$i].ip" "$RULES_JSON")" --argjson bp "$(jq -r ".[$i].bp" "$RULES_JSON")" --arg pub "$(jq -r ".[$i].pub_key" "$RULES_JSON")" --arg sid "$(jq -r ".[$i].sid" "$RULES_JSON")" --arg sni "$(jq -r ".[$i].sni" "$RULES_JSON")" --arg fp "$(jq -r ".[$i].fp" "$RULES_JSON")" \
                '.inbounds += [{"type":"mixed","tag":$in_tag,"listen":"::","listen_port":$p}] | 
                .outbounds += [{
                    "type": "vless", "tag": $out_tag, "server": $ip, "server_port": $bp,
                    "uuid": "00000000-0000-0000-0000-000000000000", "flow": "xtls-rprx-vision",
                    "tls": {
                        "enabled": true, "server_name": $sni, "utls": {"enabled": true, "fingerprint": $fp}
                    },
                    "reality": {
                        "enabled": true, "public_key": $pub
                    } + (if $sid != "" then {"short_id": $sid} else {} end)
                }]')
                json=$(echo "$json" | jq --arg in "$in_tag" --arg out "$out_tag" '.route.rules += [{"inbound":[$in], "outbound":$out}]')
            fi
            
        elif [ "$type" == "hysteria2" ]; then
            if [ "$mode" == "standalone" ]; then
                json=$(echo "$json" | jq --argjson p "$port" --arg pass "$(jq -r ".[$i].pass" "$RULES_JSON")" --arg sni "$(jq -r ".[$i].sni" "$RULES_JSON")" \
                '.inbounds += [{
                    "type": "hysteria2", "tag": ("in-" + ($p|tostring)), "listen": "::", "listen_port": $p, "password": $pass,
                    "tls": {
                        "enabled": true, "server_name": $sni,
                        "certificates": [{"certificate":"/etc/sing-box/hy2.crt","key":"/etc/sing-box/hy2.key"}]
                    }
                }]')
            else
                json=$(echo "$json" | jq --arg tag "$in_tag" --argjson p "$port" --arg ip "$(jq -r ".[$i].ip" "$RULES_JSON")" --argjson bp "$(jq -r ".[$i].bp" "$RULES_JSON")" --arg pass "$(jq -r ".[$i].pass" "$RULES_JSON")" --arg sni "$(jq -r ".[$i].sni" "$RULES_JSON")" \
                '.inbounds += [{"type":"mixed","tag":$in_tag,"listen":"::","listen_port":$p}] | 
                .outbounds += [{"type":"hysteria2","tag":$out_tag,"server":$ip,"server_port":$bp,"password":$pass,"tls":{"enabled":true,"server_name":$sni,"insecure":true}}])
                json=$(echo "$json" | jq --arg in "$in_tag" --arg out "$out_tag" '.route.rules += [{"inbound":[$in], "outbound":$out}]')
            fi
            
        elif [ "$type" == "argo" ]; then
            if [ "$mode" == "standalone" ]; then
                json=$(echo "$json" | jq --argjson p "$port" --arg u "$(jq -r ".[$i].uuid" "$RULES_JSON")" --arg path "$(jq -r ".[$i].path" "$RULES_JSON")" \
                '.inbounds += [{"type":"vless","tag":("in-"+($p|tostring)),"listen":"::","listen_port":$p,"uuid":$u,"transport":{"type":"ws","path":$path}}]')
            else
                json=$(echo "$json" | jq --arg tag "in-$p" --argjson p "$port" --arg ip "$(jq -r ".[$i].ip" "$RULES_JSON")" --argjson bp "$(jq -r ".[$i].bp" "$RULES_JSON")" --arg path "$(jq -r ".[$i].path" "$RULES_JSON")" \
                '.inbounds += [{"type":"mixed","tag":"in-$p","listen":"::","listen_port":$p}] | 
                .outbounds += [{"type":"vless","tag":"out-$p","server":$ip,"server_port":$bp,"uuid":"00000000-0000-0000-0000-000000000000","transport":{"type":"ws","path":$path}}])
                json=$(echo "$json" | jq --arg in "in-$p" --arg out "out-$p" '.route.rules += [{"inbound":["in-$p"],"outbound":"out-$p"}]')
            fi
            
        elif [ "$type" == "direct" ]; then
            json=$(echo "$json" | jq --argjson p "$port" --arg ip "$(jq -r ".[$i].ip" "$RULES_JSON")" --arg bp "$(jq -r ".[$i].bp" "$RULES_JSON")" \
                '.inbounds += [{"type":"direct","tag":"in-$p","listen":"::","listen_port":$p,"override_address":$ip,"override_port":$bp}]')
        fi
    done
    
    echo "$json" > "$TMP_FILE"
    
    echo -e "${gl_lv}[2/3] 安全校验中...${gl_bai}"
    if ! sing-box check -c "$TMP_FILE" >/dev/null 2>&1; then
        echo -e "${gl_red}❌ 校验失败！详细错误：${gl_bai}"
        sing-box check -c "$TMP_FILE"
        rm -f "$TMP_FILE"
        read -rs -n 1 -p "按任意键返回..."
        return
    fi
    
    echo -e "${gl_lv}[3/3] 重启服务...${gl_bai}"
    cp -f "$TMP_FILE" "$CONF_FILE" && rm -f "$TMP_FILE"
    systemctl enable sing-box >/dev/null 2>&1
    systemctl restart sing-box
    sleep 1
    
    if systemctl is-active --quiet sing-box; then
        echo -e "${gl_lv}✅ 成功！服务已真实运行中！${gl_bai}"
    else
        echo -e "${gl_red}❌ 服务崩溃退出！真实原因：${gl_bai}"
        journalctl -u sing-box -n 15 --no-pager
    fi
    read -rs -n 1 -p "按任意键返回..."
}

# ============================================================================
# 铁壁循环主菜单
# ============================================================================

main_menu() {
    check_env
    while true; do
        clear
        local r="${gl_red}未安装${gl_bai}" s="${gl_red}未运行${gl_bai}" b="${gl_red}未启用${gl_bai}"
        if command -v sing-box >/dev/null 2>/dev/null || [ -f "/usr/local/bin/sing-box" ]; then
            r="${gl_lv}已安装 ✅${gl_bai}"
            if systemctl is-active --quiet sing-box 2>/dev/null; then s="${gl_lv}运行中 ✅${gl_bai}"; else s="${gl_red}未运行${gl_bai}"; fi
            systemctl is-enabled sing-box --quiet 2>/dev/null && b="${gl_lv}已启用 ✅${gl_bai}"
        fi
        local n=$(jq 'length' "$RULES_JSON")
        
        echo -e "${gl_kjlan}========================================${gl_bai}"
        echo -e "       Sing-Box 多协议节点管理脚本              "
        echo -e "========================================${gl_bai}"
        echo -e "核心状态: $r   |   运行状态: $s"
        echo -e "开机自启: $b   |   节点数量: ${gl_lv}${n}${gl_bai} 个"
        echo -e "----------------------------------------"
        echo -e "${gl_lv}1. 安装/更新核心${gl_bai}"
        echo -e "${gl_huang}2. 添加节点${gl_bai}"
        echo -e "${gl_hui}3. 查看/删除节点${gl_bai}"
        echo -e "${gl_kjlan}4. 📋 查看一键导入链接${gl_bai}"
        echo -e "----------------------------------------"
        echo -e "${gl_lv}5. 🧨 校验并启动服务 ★${gl_bai}"
        echo -e "${gl_hui}6. 停止服务${gl_bai}"
        echo -e "----------------------------------------"
        echo -e "0. 退出"
        echo -e "${gl_kjlan}========================================${gl_bai}"
        read -e -p "请输入选择: " c
        
        case $c in
            1) install_core ;;
            2) add_node_menu ;;
            3) 
                view_nodes
                read -e -p "输入 3 删除节点，直接回车跳过: " idx
                if [ "$idx" == "3" ]; then
                    del_node
                    read -rs -n 1 -p "按任意键继续..."
                fi
                ;;
            4) 
                view_links
                read -rs -n 1 -p "按任意键继续..."
                ;;
            5) apply_config ;;
            6) systemctl stop sing-box && echo -e "${gl_lv}已停止${gl_bai}" && read -rs -n 1 -p "按任意键继续..." ;;
            0|"") exit 0 ;;
            *) echo -e "${gl_red}输入无效${gl_bai}"; sleep 1 ;;
        esac
    done
}

main_menu
