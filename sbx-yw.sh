#!/usr/bin/env bash
# ============================================================================
# Sing-Box 多协议管理脚本 (全面修复版)
# 修复内容:
#   1. line 338 缺失的闭合单引号 (致命语法错误根因)
#   2. /etc/singbing-box 拼写错误 -> /etc/sing-box
#   3. jq 中所有 "field":"$var" 改为 "field":$var (否则存的是字面量 $var)
#   4. apply_config 中 $in_tag / $out_tag 通过 --arg 正确传入 jq
#   5. apply_config argo 中转 / direct 分支 "tag":"in-$p" 改用 jq 字符串拼接
#   6. hy2 证书同时检查 .crt 和 .key 是否都存在, 缺一即重新生成
#   7. 清理无用的 --arg tag 参数
# ============================================================================

set -u
RULES_JSON="/etc/sing-box/sb-relay-rules.json"
SERVERS_LIST="/etc/sing-box/sb-servers.list"
CONF_FILE="/etc/sing-box/config.json"
TMP_FILE="/tmp/sb-relay-tmp.json"
LINKS_FILE="/etc/sing-box/client_links.txt"
HY2_CRT="/etc/sing-box/hy2.crt"
HY2_KEY="/etc/sing-box/hy2.key"

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
        elif command -v yum >/dev/null 2>&1; then yum install -y openssl -q; fi
    fi
    mkdir -p /etc/sing-box
    [ ! -f "$SERVERS_LIST" ] && touch "$SERVERS_LIST"
    [ ! -f "$LINKS_FILE" ] && touch "$LINKS_FILE"

    # 如果 rules.json 不存在或被污染, 自动初始化为空数组
    if [ ! -f "$RULES_JSON" ] || ! jq empty "$RULES_JSON" >/dev/null 2>&1; then
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
                local n
                n=$(curl -o /dev/null -s -w '%{time_connect}' --max-time 1 -4 "https://$i" 2>/dev/null | awk '{printf "%d",$1*1000}')
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
        local uuid pk pub keys sni fp sid
        uuid=$(cat /proc/sys/kernel/random/uuid)
        keys=$(sing-box generate reality-keypair 2>/dev/null)
        pk=$(echo "$keys" | grep PrivateKey | awk '{print $2}')
        pub=$(echo "$keys" | grep PublicKey | awk '{print $2}')
        [ -z "$pub" ] && echo -e "${gl_red}生成失败，请检查核心${gl_bai}" && return

        sni=$(select_sni)
        read -e -p "TLS 指纹 (直接回车默认 chrome): " fp; [ -z "$fp" ] && fp="chrome"
        read -e -p "短ID ShortId (可留空): " sid

        # 修复: 所有 $var 不要外面再加双引号包裹, 否则 jq 会存字面量
        jq --arg p "$port" --arg u "$uuid" --arg pk "$pk" --arg pub "$pub" \
           --arg sid "$sid" --arg sni "$sni" --arg fp "$fp" \
           '. += [{"type":"vless-reality","port":$p|tonumber,"mode":"standalone","uuid":$u,"priv_key":$pk,"pub_key":$pub,"sid":$sid,"sni":$sni,"fp":$fp}]' \
           "$RULES_JSON" > "${RULES_JSON}.tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
        echo -e "${gl_lv}✅ Reality 节点添加成功！${gl_bai}"
    else
        local ip bp pub sid sni fp pk keys
        read -e -p "后端IP: " ip; [ -z "$ip" ] && echo -e "${gl_red}IP为空${gl_bai}" && return
        read -e -p "后端端口: " bp; [[ ! "$bp" =~ ^[0-9]+$ ]] && echo -e "${gl_red}端口错误${gl_bai}" && return
        read -e -p "后端公钥 (输入 G 自动生成一对): " pub
        if [ "$pub" = "G" ]; then
            keys=$(sing-box generate reality-keypair 2>/dev/null)
            pk=$(echo "$keys" | grep PrivateKey | awk '{print $2}')
            pub=$(echo "$keys" | grep PublicKey | awk '{print $2}')
            echo -e "${gl_red}⚠️  请将此私钥填入后端面板: ${gl_kjlan}${pk}${gl_bai}"
            read -rs -n 1 -p "已复制私钥？按任意键继续..."
        elif [ -z "$pub" ]; then
            echo -e "${gl_red}公钥不能为空！${gl_bai}"; return
        fi
        read -e -p "短ID: " sid
        sni=$(select_sni)
        read -e -p "指纹 (直接回车 chrome): " fp; [ -z "$fp" ] && fp="chrome"

        # 修复: "ip":$ip (不要 "$ip"), 否则存的是字面量
        jq --arg p "$port" --arg ip "$ip" --arg bp "$bp" --arg pub "$pub" \
           --arg sid "$sid" --arg sni "$sni" --arg fp "$fp" \
           '. += [{"type":"vless-reality","port":$p|tonumber,"mode":"relay","ip":$ip,"bp":$bp|tonumber,"pub_key":$pub,"sid":$sid,"sni":$sni,"fp":$fp}]' \
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
    local sni
    sni=$(select_sni)

    if [ "$m" == "1" ]; then
        local pass
        pass=$(openssl rand -base64 16)
        # 修复: 同时检查 .crt 和 .key, 任一缺失就重新生成一对
        # 修复: /etc/singbing-box 拼写错误 -> /etc/sing-box
        if [ ! -f "$HY2_CRT" ] || [ ! -f "$HY2_KEY" ]; then
            openssl req -x509 -nodes -newkey rsa:2048 \
                -keyout "$HY2_KEY" -out "$HY2_CRT" \
                -subj "/CN=$sni" -days 3650 2>/dev/null
        fi
        # 修复: "pass":$pass, "sni":$sni
        jq --arg p "$port" --arg pass "$pass" --arg sni "$sni" \
           '. += [{"type":"hysteria2","port":$p|tonumber,"mode":"standalone","pass":$pass,"sni":$sni}]' \
           "$RULES_JSON" > "${RULES_JSON}.tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
        echo -e "${gl_lv}✅ Hy2 节点添加成功！${gl_bai}"
    else
        local ip bp pass
        read -e -p "后端IP: " ip; [ -z "$ip" ] && return
        read -e -p "后端端口: " bp; [[ ! "$bp" =~ ^[0-9]+$ ]] && return
        read -e -p "密码: " pass; [ -z "$pass" ] && return
        # 修复: 所有 "field":"$var" -> "field":$var
        jq --arg p "$port" --arg ip "$ip" --arg bp "$bp" --arg pass "$pass" --arg sni "$sni" \
           '. += [{"type":"hysteria2","port":$p|tonumber,"mode":"relay","ip":$ip,"bp":$bp|tonumber,"pass":$pass,"sni":$sni}]' \
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
    local path
    read -e -p "WS路径 (如 /ray): " path; [ -z "$path" ] && path="/ray"

    if [ "$m" == "1" ]; then
        local uuid
        uuid=$(cat /proc/sys/kernel/random/uuid)
        # 修复: "uuid":$u, "path":$path
        jq --arg p "$port" --arg u "$uuid" --arg path "$path" \
           '. += [{"type":"argo","port":$p|tonumber,"mode":"standalone","uuid":$u,"path":$path}]' \
           "$RULES_JSON" > "${RULES_JSON}.tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
        echo -e "${gl_lv}✅ Argo 后端添加成功！${gl_bai}"
    else
        local ip bp
        read -e -p "后端IP/域名: " ip; [ -z "$ip" ] && return
        read -e -p "后端端口: " bp; [[ ! "$bp" =~ ^[0-9]+$ ]] && return
        # 修复: "ip":$ip, "path":$path
        jq --arg p "$port" --arg ip "$ip" --arg bp "$bp" --arg path "$path" \
           '. += [{"type":"argo","port":$p|tonumber,"mode":"relay","ip":$ip,"bp":$bp|tonumber,"path":$path}]' \
           "$RULES_JSON" > "${RULES_JSON}.tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
        echo -e "${gl_lv}✅ 中转规则添加成功${gl_bai}"
    fi
}

add_direct() {
    echo -e "\n${gl_lan}--- 纯端口转发配置 ---${gl_bai}"
    local port ip bp
    read -e -p "本机监听端口: " port; [[ ! "$port" =~ ^[0-9]+$ ]] && return
    read -e -p "后端目标 IP: " ip; [ -z "$ip" ] && return
    read -e -p "后端目标端口: " bp; [[ ! "$bp" =~ ^[0-9]+$ ]] && return
    # 修复: "ip":$ip
    jq --arg p "$port" --arg ip "$ip" --arg bp "$bp" \
       '. += [{"type":"direct","port":$p|tonumber,"ip":$ip,"bp":$bp|tonumber}]' \
       "$RULES_JSON" > "${RULES_JSON}.tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
    echo -e "${gl_lv}✅ 纯转发节点添加成功${gl_bai}"
}

view_nodes() {
    echo -e "${gl_huang}----------------------------------------${gl_bai}"
    local count
    count=$(jq 'length' "$RULES_JSON")
    if [ "$count" -eq 0 ]; then echo -e "${gl_hui}暂无节点${gl_bai}"; return; fi
    for ((i=0; i<count; i++)); do
        local type mode port m_str
        type=$(jq -r ".[$i].type" "$RULES_JSON")
        mode=$(jq -r ".[$i].mode" "$RULES_JSON")
        port=$(jq -r ".[$i].port" "$RULES_JSON")
        if [ "$mode" == "standalone" ]; then
            m_str="${gl_kjlan}[本机落地]${gl_bai}"
        else
            m_str="${gl_hui}[中转]${gl_bai}"
        fi
        printf "${gl_lv}[%d] 端口: %-6s %-20s %s${gl_bai}\n" "$i" "$port" "$m_str" "$type"
    done
}

view_links() {
    > "$LINKS_FILE"
    local ip
    ip=$(curl -s --connect-timeout 2 ipinfo.io/ip 2>/dev/null || echo "你的服务器IP")
    local has=0
    echo -e "${gl_kjlan}========================================${gl_bai}"
    echo -e "       客户端一键导入链接 (实时同步)       "
    echo -e "${gl_kjlan}========================================${gl_bai}"

    local count
    count=$(jq 'length' "$RULES_JSON")
    for ((i=0; i<count; i++)); do
        local mode type link
        mode=$(jq -r ".[$i].mode" "$RULES_JSON")
        [ "$mode" != "standalone" ] && continue
        type=$(jq -r ".[$i].type" "$RULES_JSON")
        link=""

        if [ "$type" == "vless-reality" ]; then
            local uuid port sni fp pub sid
            uuid=$(jq -r ".[$i].uuid" "$RULES_JSON")
            port=$(jq -r ".[$i].port" "$RULES_JSON")
            sni=$(jq -r ".[$i].sni" "$RULES_JSON")
            fp=$(jq -r ".[$i].fp" "$RULES_JSON")
            pub=$(jq -r ".[$i].pub_key" "$RULES_JSON")
            sid=$(jq -r ".[$i].sid" "$RULES_JSON")
            link="vless://${uuid}@${ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(url_encode "$sni")&fp=$(url_encode "$fp")&pbk=$(url_encode "$pub")&sid=$(url_encode "$sid")&type=tcp#Reality-${port}"
        fi

        if [ -n "$link" ]; then
            echo -e "${gl_kjlan}${link}${gl_bai}" | tee -a "$LINKS_FILE"
            has=1
        fi
    done

    if [ "$has" -eq 0 ]; then
        echo -e "${gl_hui}暂无可用链接，请先添加【本机直接落地】节点。${gl_bai}"
    fi
    echo -e "${gl_kjlan}========================================${gl_bai}"
}

del_node() {
    view_nodes
    local count
    count=$(jq 'length' "$RULES_JSON")
    [ "$count" -eq 0 ] && return
    read -e -p "输入要删除的序号 (从0开始): " idx
    if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -lt "$count" ]; then
        jq "del(.[$idx])" "$RULES_JSON" > "${RULES_JSON}.tmp" && mv "${RULES_JSON}.tmp" "$RULES_JSON"
        echo -e "${gl_lv}✅ 已删除${gl_bai}"
    else
        echo -e "${gl_red}序号无效${gl_bai}"
    fi
}

# ============================================================================
# 终极稳健引擎: 纯原生 jq 索引循环
# ============================================================================

apply_config() {
    if ! jq empty "$RULES_JSON" >/dev/null 2>&1; then
        echo -e "${gl_red}检测到节点配置被意外污染，已自动清空！请重新添加节点。${gl_bai}"
        echo "[]" > "$RULES_JSON"
        read -rs -n 1 -p "按任意键返回..."
        return
    fi

    local count
    count=$(jq 'length' "$RULES_JSON")
    if [ "$count" -eq 0 ]; then
        echo -e "${gl_red}错误：节点列表为空！${gl_bai}"
        read -rs -n 1 -p "按任意键返回..."
        return
    fi

    echo -e "${gl_lv}[1/3] 正在生成 JSON (纯原生jq引擎)...${gl_bai}"
    local json
    json=$(jq -n '{log:{level:"error"},inbounds:[],outbounds:[{type:"direct",tag:"direct"}],route:{rules:[],final:"direct"}}')

    # 索引循环, 杜绝字符串截断风险
    for ((i=0; i<count; i++)); do
        local type mode port in_tag out_tag
        type=$(jq -r ".[$i].type" "$RULES_JSON")
        mode=$(jq -r ".[$i].mode" "$RULES_JSON")
        port=$(jq -r ".[$i].port" "$RULES_JSON")
        in_tag="in-${port}"
        out_tag="out-${port}"

        if [ "$type" == "vless-reality" ]; then
            if [ "$mode" == "standalone" ]; then
                # sing-box 1.10+ schema:
                #   - uuid 移入 users[].uuid, flow 也在 users[]
                #   - reality 移入 tls.reality, 必须有 handshake
                #   - 服务器端不需要 utls
                json=$(echo "$json" | jq \
                    --argjson p "$port" \
                    --arg in_tag "$in_tag" \
                    --arg u "$(jq -r ".[$i].uuid" "$RULES_JSON")" \
                    --arg pk "$(jq -r ".[$i].priv_key" "$RULES_JSON")" \
                    --arg sid "$(jq -r ".[$i].sid" "$RULES_JSON")" \
                    --arg sni "$(jq -r ".[$i].sni" "$RULES_JSON")" \
                    '.inbounds += [{
                        "type": "vless",
                        "tag": $in_tag,
                        "listen": "::",
                        "listen_port": $p,
                        "users": [{
                            "name": "user",
                            "uuid": $u,
                            "flow": "xtls-rprx-vision"
                        }],
                        "tls": {
                            "enabled": true,
                            "server_name": $sni,
                            "reality": ({"enabled": true,
                                         "handshake": {"server": $sni, "server_port": 443},
                                         "private_key": $pk}
                                        + (if $sid != "" then {"short_id": [$sid]} else {} end))
                        }
                    }]')
            else
                # sing-box 1.10+ outbound schema:
                #   - uuid 仍在顶层 (正确)
                #   - reality 移入 tls.reality
                #   - outbound 的 short_id 是字符串, 不是数组
                json=$(echo "$json" | jq \
                    --argjson p "$port" \
                    --arg in_tag "$in_tag" \
                    --arg out_tag "$out_tag" \
                    --arg ip "$(jq -r ".[$i].ip" "$RULES_JSON")" \
                    --argjson bp "$(jq -r ".[$i].bp" "$RULES_JSON")" \
                    --arg pub "$(jq -r ".[$i].pub_key" "$RULES_JSON")" \
                    --arg sid "$(jq -r ".[$i].sid" "$RULES_JSON")" \
                    --arg sni "$(jq -r ".[$i].sni" "$RULES_JSON")" \
                    --arg fp "$(jq -r ".[$i].fp" "$RULES_JSON")" \
                    '.inbounds += [{"type":"mixed","tag":$in_tag,"listen":"::","listen_port":$p}]
                     | .outbounds += [{
                        "type": "vless",
                        "tag": $out_tag,
                        "server": $ip,
                        "server_port": $bp,
                        "uuid": "00000000-0000-0000-0000-000000000000",
                        "flow": "xtls-rprx-vision",
                        "tls": {
                            "enabled": true,
                            "server_name": $sni,
                            "utls": {"enabled": true, "fingerprint": $fp},
                            "reality": ({"enabled": true, "public_key": $pub}
                                        + (if $sid != "" then {"short_id": $sid} else {} end))
                        }
                    }]')
                json=$(echo "$json" | jq --arg in "$in_tag" --arg out "$out_tag" \
                    '.route.rules += [{"inbound":[$in], "outbound":$out}]')
            fi

        elif [ "$type" == "hysteria2" ]; then
            if [ "$mode" == "standalone" ]; then
                # sing-box 1.10+ schema:
                #   - password 移入 users[].password
                #   - 证书字段名: certificate_path + key_path (不是 certificates)
                json=$(echo "$json" | jq \
                    --argjson p "$port" \
                    --arg pass "$(jq -r ".[$i].pass" "$RULES_JSON")" \
                    --arg sni "$(jq -r ".[$i].sni" "$RULES_JSON")" \
                    '.inbounds += [{
                        "type": "hysteria2",
                        "tag": ("in-" + ($p|tostring)),
                        "listen": "::",
                        "listen_port": $p,
                        "users": [{"name": "user", "password": $pass}],
                        "tls": {
                            "enabled": true,
                            "server_name": $sni,
                            "certificate_path": "/etc/sing-box/hy2.crt",
                            "key_path": "/etc/sing-box/hy2.key"
                        }
                    }]')
            else
                # HY2 outbound: password 仍在顶层 (正确)
                json=$(echo "$json" | jq \
                    --argjson p "$port" \
                    --arg in_tag "$in_tag" \
                    --arg out_tag "$out_tag" \
                    --arg ip "$(jq -r ".[$i].ip" "$RULES_JSON")" \
                    --argjson bp "$(jq -r ".[$i].bp" "$RULES_JSON")" \
                    --arg pass "$(jq -r ".[$i].pass" "$RULES_JSON")" \
                    --arg sni "$(jq -r ".[$i].sni" "$RULES_JSON")" \
                    '.inbounds += [{"type":"mixed","tag":$in_tag,"listen":"::","listen_port":$p}]
                     | .outbounds += [{
                        "type": "hysteria2",
                        "tag": $out_tag,
                        "server": $ip,
                        "server_port": $bp,
                        "password": $pass,
                        "tls": {"enabled":true,"server_name":$sni,"insecure":true}
                    }]')
                json=$(echo "$json" | jq --arg in "$in_tag" --arg out "$out_tag" \
                    '.route.rules += [{"inbound":[$in], "outbound":$out}]')
            fi

        elif [ "$type" == "argo" ]; then
            if [ "$mode" == "standalone" ]; then
                # sing-box 1.10+ VLESS inbound: uuid 移入 users[]
                # Argo + WS 不需要 flow (WS 不支持 xtls-rprx-vision)
                json=$(echo "$json" | jq \
                    --argjson p "$port" \
                    --arg u "$(jq -r ".[$i].uuid" "$RULES_JSON")" \
                    --arg path "$(jq -r ".[$i].path" "$RULES_JSON")" \
                    '.inbounds += [{
                        "type": "vless",
                        "tag": ("in-" + ($p|tostring)),
                        "listen": "::",
                        "listen_port": $p,
                        "users": [{"name": "user", "uuid": $u}],
                        "transport": {"type":"ws","path":$path}
                    }]')
            else
                # VLESS outbound: uuid 仍在顶层
                json=$(echo "$json" | jq \
                    --argjson p "$port" \
                    --arg in_tag "$in_tag" \
                    --arg out_tag "$out_tag" \
                    --arg ip "$(jq -r ".[$i].ip" "$RULES_JSON")" \
                    --argjson bp "$(jq -r ".[$i].bp" "$RULES_JSON")" \
                    --arg path "$(jq -r ".[$i].path" "$RULES_JSON")" \
                    '.inbounds += [{"type":"mixed","tag":$in_tag,"listen":"::","listen_port":$p}]
                     | .outbounds += [{
                        "type": "vless",
                        "tag": $out_tag,
                        "server": $ip,
                        "server_port": $bp,
                        "uuid": "00000000-0000-0000-0000-000000000000",
                        "transport": {"type":"ws","path":$path}
                    }]')
                json=$(echo "$json" | jq --arg in "$in_tag" --arg out "$out_tag" \
                    '.route.rules += [{"inbound":[$in], "outbound":$out}]')
            fi

        elif [ "$type" == "direct" ]; then
            json=$(echo "$json" | jq \
                --argjson p "$port" \
                --arg in_tag "$in_tag" \
                --arg ip "$(jq -r ".[$i].ip" "$RULES_JSON")" \
                --argjson bp "$(jq -r ".[$i].bp" "$RULES_JSON")" \
                '.inbounds += [{
                    "type": "direct",
                    "tag": $in_tag,
                    "listen": "::",
                    "listen_port": $p,
                    "override_address": $ip,
                    "override_port": $bp
                }]')
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
            if systemctl is-active --quiet sing-box 2>/dev/null; then
                s="${gl_lv}运行中 ✅${gl_bai}"
            else
                s="${gl_red}未运行${gl_bai}"
            fi
            systemctl is-enabled sing-box --quiet 2>/dev/null && b="${gl_lv}已启用 ✅${gl_bai}"
        fi
        local n
        n=$(jq 'length' "$RULES_JSON")

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
