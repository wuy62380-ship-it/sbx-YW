#!/usr/bin/env bash
# ============================================================================
# Sing-Box 全自动管理脚本 (彻底重构版：完美兼容 1.8+ 新语法)
# ============================================================================

RULES_JSON="/etc/sing-box/sb-relay-rules.json"
SERVERS_LIST="/etc/sing-box/sb-servers.list"
CONF_FILE="/etc/sing-box/config.json"
TMP_FILE="/tmp/sb-relay-tmp.json"
LINKS_FILE="/etc/sing-box/client_links.txt"

: "${gl_bai:=\033[0m}" "${gl_lv:=\033[32m}" "${gl_huang:=\033[33m}" "${gl_hui:=\033[90m}" "${gl_red:=\033[31m}" "${gl_kjlan:=\033[32m}"

check_env() {
    [ "$(id -u)" -ne 0 ] && echo "请用 root 运行" && exit 1
    command -v jq >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y jq -qq; }
    command -v openssl >/dev/null 2>&1 || { apt-get install -y openssl -qq; }
    mkdir -p /etc/sing-box
    [ ! -f "$RULES_JSON" ] && echo '[]' > "$RULES_JSON"
    [ ! -f "$SERVERS_LIST" ] && touch "$SERVERS_LIST"
    [ ! -f "$LINKS_FILE" ] && touch "$LINKS_FILE"
}

url_encode() { echo -n "$1" | jq -sRr @uri; }

select_sni() {
    echo "--- 伪装域名 (SNI) 设置 ---"
    echo "1. 使用默认"
    echo "2. 自动优选延迟"
    echo "3. 手动输入"
    read -p "请选择 (1/2/3): " c
    case $c in
        1) echo "www.microsoft.com" ;;
        2) 
            local d="www.microsoft.com" t=9999
            for i in "www.apple.com" "dl.google.com"; do
                local n=$(curl -o /dev/null -s -w '%{time_connect}' --max-time 1 -4 "https://$i" 2>/dev/null| awk '{printf "%d",$1*1000}')
                [ -n "$n" ] && [ "$n" -lt "$t" ] && t=$n d=$i
            done
            echo "$d" ;;
        3) read -p "输入域名: " s; echo "${s:-www.microsoft.com}" ;;
        *) echo "www.microsoft.com" ;;
    esac
}

install_core() {
    echo "正在连接官方源安装..."
    if command -v apt >/dev/null 2>&1; then curl -fsSL https://sing-box.app/deb-install.sh | bash
    elif command -v yum >/dev/null 2>&1; then curl -fsSL https://sing-box.app/rpm-install.sh | bash
    else echo "不支持该系统"; fi
    read -p "按回车返回..."
}

menu() {
    check_env
    while true; do
        clear
        local r="${gl_red}未运行${gl_bai}" b="${gl_red}未启用${gl_bai}"
        command -v sing-box >/dev/null 2>&1 || [ -f "/usr/local/bin/sing-box" ] || local r="${gl_red}未安装${gl_bai}"
        systemctl is-active --quiet sing-box 2>/dev/null && r="${gl_lv}运行中 ✅${gl_bai}"
        systemctl is-enabled sing-box --quiet 2>/dev/null && b="${gl_lv}已启用 ✅${gl_bai}"
        local n=$(jq 'length' "$RULES_JSON")
        
        echo -e "${gl_kjlan}========================================${gl_bai}"
        echo -e "       Sing-Box 节点管理脚本 (1.8+适配)    "
        echo -e "========================================${gl_bai}"
        echo -e "核心: $r  |  服务: $r  |  自启: $b  |  节点: $n 个"
        echo "----------------------------------------"
        echo -e "${gl_lv}1. 安装/更新核心${gl_bai}"
        echo -e "${gl_huang}2. 添加节点${gl_bai}"
        echo -e "3. 查看节点列表"
        echo -e "${gl_kjlan}4. 查看导入链接${gl_bai}"
        echo -e "${gl_red}5. 删除节点${gl_bai}"
        echo "----------------------------------------"
        echo -e "${gl_lv}6. 🧨 应用配置并启动 (热重载) ★${gl_bai}"
        echo -e "7. 停止服务"
        echo "----------------------------------------"
        echo "0. 退出"
        read -p "请选择: " c
        case $c in
            1) install_core ;;
            2) add_node ;;
            3) view_nodes; read -p "回车继续..." ;;
            4) view_links ;;
            5) del_node ;;
            6) apply_config ;;
            7) systemctl stop sing-box && echo "已停止" ;;
            0) break ;;
        esac
    done
}

add_node() {
    clear
    echo "1. VLESS + Reality"
    echo "2. Hysteria2"
    echo "3. Argo + VLESS + WS"
    echo "4. 纯端口转发"
    read -p "选择协议: " p
    case $p in 1) add_reality ;; 2) add_hy2 ;; 3) add_argo ;; 4) add_direct ;; esac
}

add_reality() {
    read -p "监听端口(如443): " port
    [[ ! "$port" =~ ^[0-9]+$ ]] && echo "端口错误" && return
    
    echo "1. 本机直接落地 (全自动) ★推荐"
    echo "2. 中转到其他机器"
    read -p "选择模式: " m
    
    if [ "$m" == "1" ]; then
        local uuid=$(cat /proc/sys/kernel/random/uuid)
        local keys=$(sing-box generate reality-keypair 2>/dev/null)
        local pk=$(echo "$keys" | grep PrivateKey | awk '{print $2}')
        local pub=$(echo "$keys" | grep PublicKey | awk '{print $2}')
        [ -z "$pub" ] && echo "密钥生成失败" && return
        
        local sni=$(select_sni)
        read -p "指纹(直接回车chrome): " fp; [ -z "$fp" ] && fp="chrome"
        read -p "短ID(可留空): " sid
        
        jq --arg p "$port" --arg u "$uuid" --arg pk "$pk" --arg pub "$pub" --arg sid "$sid" --arg sni "$sni" --arg fp "$fp" \
           '. += [{"type":"vless-reality","port":$p|tonumber,"mode":"standalone","uuid":$u,"priv_key":$pk,"pub_key":$pub,"sid":$sid,"sni":$sni,"fp":$fp}]' \
           "$RULES_JSON" > "${RULES_JSON}.tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
        echo "✅ 节点添加成功"
    else
        read -p "后端IP: " ip; [ -z "$ip" ] && return
        read -p "后端端口: " bp; [[ ! "$bp" =~ ^[0-9]+$ ]] && return
        read -p "公钥(输G生成): " pub
        if [ "$pub" = "G" ]; then
            local keys=$(sing-box generate reality-keypair 2>/dev/null)
            echo "请将此私钥填入后端: $(echo "$keys" | grep PrivateKey | awk '{print $2}')"
            pub=$(echo "$keys" | grep PublicKey | awk '{print $2}')
            read -p "回车继续..."
        fi
        read -p "短ID: " sid
        local sni=$(select_sni)
        read -p "指纹(回车chrome): " fp; [ -z "$fp" ] && fp="chrome"
        
        jq --arg p "$port" --arg ip "$ip" --arg bp "$bp" --arg pub "$pub" --arg sid "$sid" --arg sni "$sni" --arg fp "$fp" \
           '. += [{"type":"vless-reality","port":$p|tonumber,"mode":"relay","ip":"$ip","bp":$bp|tonumber,"pub_key":$pub,"sid":$sid,"sni":$sni,"fp":$fp}]' \
           "$RULES_JSON" > "${RULES_JSON}.tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
        echo "✅ 添加成功"
    fi
}

add_hy2() {
    read -p "监听UDP端口(如8443): " port
    [[ ! "$port" =~ ^[0-9]+$ ]] && echo "错误" && return
    echo "1. 本机落地 2. 中转"
    read -p "模式: " m
    local sni=$(select_sni)
    
    if [ "$m" == "1" ]; then
        local pass=$(openssl rand -base64 16)
        [ ! -f "/etc/sing-box/hy2.crt" ] && openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/sing-box/hy2.key -out /etc/sing-box/hy2.crt -subj "/CN=$sni" -days 3650 2>/dev/null
        jq --arg p "$port" --arg pass "$pass" --arg sni "$sni" '. += [{"type":"hysteria2","port":$p|tonumber,"mode":"standalone","pass":"$pass","sni":"$sni"}]' "$RULES_JSON" > "${RULES_JSON}.tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
    else
        read -p "后端IP: " ip; read -p "后端端口: " bp; read -p "密码: " pass
        jq --arg p "$port" --arg ip "$ip" --arg bp "$bp" --arg pass "$pass" --arg sni "$sni" '. += [{"type":"hysteria2","port":$p|tonumber,"mode":"relay","ip":"$ip","bp":$bp|tonumber,"pass":"$pass","sni":"$sni"}]' "$RULES_JSON" > "${RULES_JSON}.tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
    fi
    echo "✅ 添加成功"
}

add_argo() {
    read -p "监听端口(如8080): " port
    echo "1. 本机落地 2. 中转"
    read -p "模式: " m
    read -p "WS路径(如/ray): " path; [ -z "$path" ] && path="/ray"
    
    if [ "$m" == "1" ]; then
        local uuid=$(cat /proc/sys/kernel/random/uuid)
        jq --arg p "$port" --arg u "$uuid" --arg path "$path" '. += [{"type":"argo","port":$p|tonumber,"mode":"standalone","uuid":"$u","path":"$path"}]' "$RULES_JSON" > "${RULES_JSON}.tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
    else
        read -p "后端IP: " ip; read -p "后端端口: " bp
        jq --arg p "$port" --arg ip "$ip" --arg bp "$bp" --arg path "$path" '. += [{"type":"argo","port":$p|tonumber,"mode":"relay","ip":"$ip","bp":$bp|tonumber,"path":"$path"}]' "$RULES_JSON" > "${RULES_JSON}.tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
    fi
    echo "✅ 添加成功"
}

add_direct() {
    read -p "监听端口: " port
    read -p "目标IP: " ip; read -p "目标端口: " bp
    jq --arg p "$port" --arg ip "$ip" --arg bp "$bp" '. += [{"type":"direct","port":$p|tonumber,"ip":"$ip","bp":$bp|tonumber}]' "$RULES_JSON" > "${RULES_JSON}.tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
    echo "✅ 添加成功"
}

view_nodes() {
    jq -r '.[] | "端口: \(.port) | 模式: \(.mode) | 类型: \(.type)"' "$RULES_JSON"
}

view_links() {
    > "$LINKS_FILE"
    local ip=$(curl -s --connect-timeout 2 ipinfo.io/ip 2>/dev/null || echo "你的IP")
    for row in $(jq -c '.[] | select(.mode=="standalone")' "$RULES_JSON"); do
        local t=$(echo "$row" | jq -r '.type')
        local p=$(echo "$row" | jq -r '.port')
        if [ "$t" == "vless-reality" ]; then
            local link="vless://$(echo "$row" | jq -r '.uuid')@${ip}:${p}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(url_encode "$(echo "$row" | jq -r '.sni')")&fp=$(url_encode "$(echo "$row" | jq -r '.fp')")&pbk=$(url_encode "$(echo "$row" | jq -r '.pub_key')")&sid=$(url_encode "$(echo "$row" | jq -r '.sid')")&type=tcp#Reality-${p}"
            echo "$link" | tee -a "$LINKS_FILE"
        fi
    done
}

del_node() {
    view_nodes
    read -p "输入要删除的节点序号(从0开始): " i
    jq "del(.[$i])" "$RULES_JSON" > "${RULES_JSON}.tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
    echo "已删除"
}

# ============================================================================
# 🌟 终极引擎：彻底适配 Sing-Box 1.8+ 新语法
# ============================================================================

apply_config() {
    [ $(jq 'length' "$RULES_JSON") -eq 0 ] && echo "节点为空" && return
    echo "正在生成 1.8+ 标准配置..."
    
    local json=$(jq -n '{log:{level:"error"},inbounds:[],outbounds:[{type:"direct",tag:"direct"}],route:{rules:[],final:"direct"}}')
    
    for row in $(jq -c '.[]' "$RULES_JSON"); do
        local t=$(echo "$row" | jq -r '.type')
        local m=$(echo "$row" | jq -r '.mode')
        local p=$(echo "$row" | jq -r '.port')
        
        if [ "$t" == "vless-reality" ]; then
            if [ "$m" == "standalone" ]; then
                # 【修复核心】严格按照 1.8 规范：reality 与 tls 平级
                json=$(echo "$json" | jq --argjson r "$row" \
                '.inbounds += [{
                    "type": "vless", "tag": ("in-" + ($r.port|tostring)),
                    "listen": "::", "listen_port": $r.port,
                    "uuid": $r.uuid,
                    "tls": {
                        "enabled": true, "server_name": $r.sni,
                        "utls": {"enabled": true, "fingerprint": $r.fp}
                    },
                    "reality": {
                        "enabled": true, "private_key": $r.priv_key
                    } + if $r.sid != "" then {"short_id": [$r.sid]} else {} end
                }]')
            else
                json=$(echo "$json" | jq --argjson r "$row" \
                '.inbounds += [{"type":"mixed","tag":("in-"+($r.port|tostring)),"listen":"::","listen_port":$r.port}] | 
                .outbounds += [{
                    "type": "vless", "tag": ("out-"+($r.port|tostring)),
                    "server": $r.ip, "server_port": $r.bp,
                    "uuid": "00000000-0000-0000-0000-000000000000", "flow": "xtls-rprx-vision",
                    "tls": {
                        "enabled": true, "server_name": $r.sni,
                        "utls": {"enabled": true, "fingerprint": $r.fp}
                    },
                    "reality": {
                        "enabled": true, "public_key": $r.pub_key
                    } + if $r.sid != "" then {"short_id": $r.sid} else {} end
                }] |
                .route.rules += [{"inbound":[("in-"+($r.port|tostring))],"outbound":("out-"+($r.port|tostring))}]')
            fi
            
        elif [ "$t" == "hysteria2" ]; then
            if [ "$m" == "standalone" ]; then
                json=$(echo "$json" | jq --argjson r "$row" \
                '.inbounds += [{
                    "type": "hysteria2", "tag": ("in-" + ($r.port|tostring)),
                    "listen": "::", "listen_port": $r.port, "password": $r.pass,
                    "tls": {
                        "enabled": true, "server_name": $r.sni,
                        "certificates": [{"certificate":"/etc/sing-box/hy2.crt","key":"/etc/sing-box/hy2.key"}]
                    }
                }]')
            else
                json=$(echo "$json" | jq --argjson r "$row" \
                '.inbounds += [{"type":"mixed","tag":("in-"+($r.port|tostring)),"listen":"::","listen_port":$r.port}] | 
                .outbounds += [{"type":"hysteria2","tag":("out-"+($r.port|tostring)),"server":$r.ip,"server_port":$r.bp,"password":$r.pass,"tls":{"enabled":true,"server_name":$r.sni,"insecure":true}}] |
                .route.rules += [{"inbound":[("in-"+($r.port|tostring))],"outbound":("out-"+($r.port|tostring))}]')
            fi
            
        elif [ "$t" == "argo" ]; then
            if [ "$m" == "standalone" ]; then
                json=$(echo "$json" | jq --argjson r "$row" \
                '.inbounds += [{"type":"vless","tag":("in-"+($r.port|tostring)),"listen":"::","listen_port":$r.port,"uuid":$r.uuid,"transport":{"type":"ws","path":$r.path}}]')
            else
                json=$(echo "$json" | jq --argjson r "$row" \
                '.inbounds += [{"type":"mixed","tag":("in-"+($r.port|tostring)),"listen":"::","listen_port":$r.port}] | 
                .outbounds += [{"type":"vless","tag":("out-"+($r.port|tostring)),"server":$r.ip,"server_port":$r.bp,"uuid":"00000000-0000-0000-0000-000000000000","transport":{"type":"ws","path":$r.path}}] |
                .route.rules += [{"inbound":[("in-"+($r.port|tostring))],"outbound":("out-"+($r.port|tostring))}]')
            fi
            
        elif [ "$t" == "direct" ]; then
            json=$(echo "$json" | jq --argjson r "$row" \
            '.inbounds += [{"type":"direct","tag":("in-"+($r.port|tostring)),"listen":"::","listen_port":$r.port,"override_address":$r.ip,"override_port":$r.bp}]')
        fi
    done
    
    echo "$json" > "$TMP_FILE"
    
    echo "校验中..."
    if ! sing-box check -c "$TMP_FILE" >/dev/null 2>&1; then
        echo "❌ 配置校验失败，错误如下："
        sing-box check -c "$TMP_FILE"
        rm -f "$TMP_FILE"
        read -p "回车返回..."
        return
    fi
    
    echo "重启服务..."
    cp "$TMP_FILE" "$CONF_FILE" && rm -f "$TMP_FILE"
    systemctl enable sing-box >/dev/null 2>&1
    systemctl restart sing-box
    sleep 1
    
    if systemctl is-active --quiet sing-box; then
        echo -e "${gl_lv}✅ 成功！服务已真实运行中！${gl_bai}"
    else
        echo -e "${gl_red}❌ 失败！真实崩溃原因：${gl_bai}"
        journalctl -u sing-box -n 15 --no-pager
    fi
    read -p "回车返回..."
}

menu
