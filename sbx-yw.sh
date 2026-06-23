#!/usr/bin/env bash
# ============================================================================
# Sing-Box 多协议管理脚本 (终极完整版)
# ============================================================================

set -u

# ============================================================================
# 全局变量
# ============================================================================
RULES_JSON="/etc/sing-box/.sb-rules.db"
SERVERS_LIST="/etc/sing-box/sb-servers.list"
CONF_FILE="/etc/sing-box/config.json"
TMP_FILE="/tmp/sb-relay-tmp.json"
LINKS_FILE="/etc/sing-box/client_links.txt"
HY2_CRT="/etc/sing-box/hy2.crt"
HY2_KEY="/etc/sing-box/hy2.key"
BAK_DIR="/etc/sing-box/backup"
HOST_ALIAS_FILE="/etc/sing-box/.host_alias"

: "${gl_bai:=\033[0m}"
: "${gl_lv:=\033[32m}"
: "${gl_huang:=\033[33m}"
: "${gl_hui:=\033[90m}"
: "${gl_red:=\033[31m}"
: "${gl_kjlan:=\033[32m}"
: "${gl_lan:=\033[34m}"
: "${gl_bright:=\033[97m}"
: "${gl_cyan:=\033[96m}"

# ============================================================================
# 环境检测与初始化
# ============================================================================
check_env() {
    [ "$(id -u)" -ne 0 ] && echo -e "${gl_red}请使用 root 运行${gl_bai}" && exit 1

    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${gl_huang}安装 jq...${gl_bai}"
        if command -v apt >/dev/null 2>&1; then apt-get update -qq && apt-get install -y jq -qq
        elif command -v yum >/dev/null 2>&1; then yum install -y jq -q
        else echo -e "${gl_red}无法自动安装 jq${gl_bai}" && exit 1; fi
    fi
    if ! command -v openssl >/dev/null 2>&1; then
        if command -v apt >/dev/null 2>&1; then apt-get install -y openssl -qq
        elif command -v yum >/dev/null 2>&1; then yum install -y openssl -q; fi
    fi

    mkdir -p /etc/sing-box "$BAK_DIR"
    [ ! -f "$SERVERS_LIST" ] && touch "$SERVERS_LIST"
    [ ! -f "$LINKS_FILE" ] && touch "$LINKS_FILE"
    if [ -f "/etc/sing-box/sb-relay-rules.json" ]; then mv "/etc/sing-box/sb-relay-rules.json" "$RULES_JSON" 2>/dev/null; fi
    if [ ! -f "$RULES_JSON" ] || ! jq empty "$RULES_JSON" >/dev/null 2>&1; then echo "[]" > "$RULES_JSON"; fi

    if [ ! -f "$HOST_ALIAS_FILE" ] || [ -z "$(cat "$HOST_ALIAS_FILE" 2>/dev/null | tr -d '[:space:]')" ]; then
        clear
        echo -e "${gl_kjlan}========================================${gl_bai}"
        echo -e "${gl_kjlan}      欢迎使用 Sing-Box 管理脚本       "
        echo -e "${gl_kjlan}========================================${gl_bai}"
        echo -e "${gl_huang}检测到首次运行，请为当前机器设置身份备注：${gl_bai}"
        echo -e "${gl_hui}例如: 香港中转机、美西落地机、家里软路由等${gl_bai}"
        read -e -p "$(echo -e "${gl_cyan}请输入本机备注名: ${gl_bai}")" alias_name
        [ -z "$alias_name" ] && alias_name="未命名主机"
        echo "$alias_name" > "$HOST_ALIAS_FILE"
        echo -e "${gl_lv}✅ 设置完成: ${alias_name}${gl_bai}"
        read -rs -n 1 -p "按任意键继续..."
    fi
}

get_host_alias() { local a=""; [ -f "$HOST_ALIAS_FILE" ] && a=$(cat "$HOST_ALIAS_FILE" | tr -d '[:space:]'); echo "${a:-未命名主机}"; }

# ============================================================================
# 工具函数
# ============================================================================
url_encode() { echo -n "$1" | jq -sRr @uri; }
get_public_ip() {
    local t; t=$(curl -s --connect-timeout 3 https://myip.ipip.net 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+')
    [[ "$t" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$t" && return
    t=$(curl -s --connect-timeout 3 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')
    [[ "$t" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$t" && return
    t=$(curl -s --connect-timeout 3 https://icanhazip.com 2>/dev/null | tr -d '[:space:]')
    [[ "$t" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$t" && return
    echo ""
}
get_sb_version() { sing-box version 2>/dev/null | grep -oP '\d+\.\d+' | head -1; }
check_port_warn() {
    local p="$1" w=0
    jq -e --argjson p "$p" '.[].port == $p' "$RULES_JSON" >/dev/null 2>&1 && echo -e "${gl_huang}提示: 端口 $p 已存在${gl_bai}" && w=1
    ss -tlnup 2>/dev/null | grep -q ":${p} " && echo -e "${gl_huang}提示: 端口 $p 被占用${gl_bai}" && w=1
    [ "$w" -eq 1 ] && echo -e "${gl_hui}(不限端口, 继续添加)${gl_bai}"
}
safe_write_rules() { jq . "$1" > "${RULES_JSON}.tmp" && sync && mv "${RULES_JSON}.tmp" "$RULES_JSON"; }

select_sni() {
    echo -e "${gl_huang}--- 伪装域名 (SNI) 设置 ---${gl_bai}" >&2
    echo -e "${gl_lv}1. 使用默认伪装域名${gl_bai}" >&2
    echo -e "${gl_lv}2. 自动优选最佳域名 (并发测速)${gl_bai}" >&2
    echo -e "${gl_lv}3. 手动输入域名${gl_bai}" >&2
    read -e -p "$(echo -e "${gl_cyan}请选择 (1默认 / 2优选 / 3手动): ${gl_bai}")" c
    case $c in
        1) echo "www.microsoft.com" ;;
        2)
            echo -e "${gl_huang}[并发测速中，约需3秒]...${gl_bai}" >&2
            local d=("aws.com" "bing.com" "snap.licdn.com" "devblogs.microsoft.com" "cdn.bizibly.com" "www.apple.com" "ts1.tc.mm.bing.net" "fpinit.itunes.apple.com" "go.microsoft.com" "catalog.gamepass.com" "gray-config-prod.api.arc-cdn.net" "apps.mzstatic.com" "tag.demandbase.com" "r.bing.com" "tag-logger.demandbase.com" "cdn-dynmedia-1.microsoft.com" "services.digitaleast.mobi" "gray.video-player.arcpublishing.com" "azure.microsoft.com" "beacon.gtv-pub.com" "amd.com" "www.joom.com" "www.stengg.com" "www.wedgehr.com" "www.cerebrium.ai" "www.nazhumi.cem" "cloudflare-ech.com" "www.microsoft.com" "dl.google.com" "www.amazon.com")
            local f="/tmp/sb_sni_test.$$"; > "$f"
            for i in "${d[@]}"; do ( n=$(curl -o /dev/null -s -w '%{time_connect}' --max-time 2 -4 "https://$i" 2>/dev/null | awk '{printf "%d",$1*1000}'); [ -n "$n" ] && echo "$n $i" >> "$f" ) & done
            wait
            local b_d="www.microsoft.com" b_t=9999
            while read -r line; do local t=${line%% *}; local dom=${line#* }; [ "$t" -lt "$b_t" ] 2>/dev/null && b_t=$t b_d=$dom; done < "$f"
            rm -f "$f"
            echo -e "${gl_lv}选用: $b_d (${b_t}ms)${gl_bai}" >&2; echo "$b_d" ;;
        3) read -e -p "$(echo -e "${gl_cyan}输入域名: ${gl_bai}")" s; echo "${s:-www.microsoft.com}" ;;
        *) echo "www.microsoft.com" ;;
    esac
}

# ============================================================================
# 安装 / 卸载 / 备注
# ============================================================================
install_core() {
    echo -e "${gl_huang}正在连接官方源安装...${gl_bai}"
    if command -v apt >/dev/null 2>&1; then curl -fsSL https://sing-box.app/deb-install.sh | bash
    elif command -v yum >/dev/null 2>&1; then curl -fsSL https://sing-box.app/rpm-install.sh | bash
    else echo -e "${gl_red}不支持该系统${gl_bai}"; fi
    read -rs -n 1 -p "按任意键返回..."
}
uninstall_core() {
    echo -e "${gl_red}即将卸载 sing-box 并清理所有配置！${gl_bai}"
    read -e -p "$(echo -e "${gl_cyan}确定? (输入 YES 确认): ${gl_bai}")" c
    if [ "$c" == "YES" ]; then
        systemctl stop sing-box 2>/dev/null; systemctl disable sing-box 2>/dev/null
        if command -v apt >/dev/null 2>&1; then apt-get remove -y sing-box 2>/dev/null
        elif command -v yum >/dev/null 2>&1; then yum remove -y sing-box 2>/dev/null; fi
        rm -rf /etc/sing-box; echo -e "${gl_lv}已完全卸载${gl_bai}"
    else echo -e "${gl_hui}已取消${gl_bai}"; fi
    read -rs -n 1 -p "按任意键返回..."
}
set_host_alias() {
    echo -e "${gl_huang}当前备注: ${gl_lv}$(get_host_alias)${gl_bai}"
    read -e -p "$(echo -e "${gl_cyan}输入新备注 (回车取消): ${gl_bai}")" n
    [ -n "$n" ] && echo "$n" > "$HOST_ALIAS_FILE" && echo -e "${gl_lv}✅ 已更新为: $n${gl_bai}" || echo -e "${gl_hui}已取消${gl_bai}"
    read -rs -n 1 -p "按任意键返回..."
}

# ============================================================================
# 添加 VLESS + Reality (含集群模式)
# ============================================================================
add_reality() {
    echo -e "\n${gl_lan}--- VLESS + Reality 配置 ---${gl_bai}"
    read -e -p "$(echo -e "${gl_cyan}本机监听端口: ${gl_bai}")" port
    [[ ! "$port" =~ ^[0-9]+$ ]] && echo -e "${gl_red}端口错误${gl_bai}" && return
    check_port_warn "$port"
    read -e -p "$(echo -e "${gl_cyan}节点备注名 (回车默认端口): ${gl_bai}")" name
    [ -z "$name" ] && name="Reality-$port"

    echo -e "${gl_huang}>>> 请选择工作模式 <<<${gl_bai}"
    echo -e "${gl_lv}1. 本机直接落地 (全自动生成) ★${gl_bai}"
    echo -e "${gl_hui}2. 中转到其他机器 (单线 1对1)${gl_bai}"
    echo -e "${gl_bright}3. 集群/负载均衡 (单端口挂多落地) ★NEW${gl_bai}"
    read -e -p "$(echo -e "${gl_cyan}请选择 (1落地 / 2中转 / 3集群): ${gl_bai}")" m

    if [ "$m" == "1" ]; then
        echo -e "${gl_huang}[全自动] 生成密钥和UUID...${gl_bai}"
        local uuid pk pub keys sni fp sid
        uuid=$(cat /proc/sys/kernel/random/uuid)
        keys=$(sing-box generate reality-keypair 2>/dev/null)
        pk=$(echo "$keys" | grep PrivateKey | awk '{print $2}')
        pub=$(echo "$keys" | grep PublicKey | awk '{print $2}')
        [ -z "$pub" ] && echo -e "${gl_red}生成失败${gl_bai}" && return
        sni=$(select_sni)
        read -e -p "$(echo -e "${gl_cyan}TLS 指纹 (回车chrome): ${gl_bai}")" fp; [ -z "$fp" ] && fp="chrome"
        read -e -p "$(echo -e "${gl_cyan}短ID ShortId (可留空): ${gl_bai}")" sid

        jq -n --argjson p "$port" --arg name "$name" --arg u "$uuid" --arg pk "$pk" --arg pub "$pub" \
              --arg sid "$sid" --arg sni "$sni" --arg fp "$fp" \
              'input | . += [{"type":"vless-reality","name":$name,"port":$p,"mode":"standalone","uuid":$u,"priv_key":$pk,"pub_key":$pub,"sid":$sid,"sni":$sni,"fp":$fp}]' \
              "$RULES_JSON" | safe_write_rules /dev/stdin
        echo -e "${gl_lv}✅ 节点 [${name}] 添加成功！${gl_bai}"

    elif [ "$m" == "2" ]; then
        local ip bp pub sid sni fp pk keys
        read -e -p "$(echo -e "${gl_cyan}后端IP: ${gl_bai}")" ip; [ -z "$ip" ] && echo -e "${gl_red}IP为空${gl_bai}" && return
        read -e -p "$(echo -e "${gl_cyan}后端端口: ${gl_bai}")" bp; [[ ! "$bp" =~ ^[0-9]+$ ]] && echo -e "${gl_red}端口错误${gl_bai}" && return
        read -e -p "$(echo -e "${gl_cyan}后端公钥 (输入 G 自动生成): ${gl_bai}")" pub
        if [ "$pub" = "G" ]; then
            keys=$(sing-box generate reality-keypair 2>/dev/null)
            pk=$(echo "$keys" | grep PrivateKey | awk '{print $2}')
            pub=$(echo "$keys" | grep PublicKey | awk '{print $2}')
            echo -e "${gl_red}⚠️  请将此私钥填入后端:${gl_bai}\n${gl_kjlan}${pk}${gl_bai}"
            read -rs -n 1 -p "已复制私钥？按任意键继续..."
        elif [ -z "$pub" ]; then echo -e "${gl_red}公钥不能为空！${gl_bai}"; return; fi
        read -e -p "$(echo -e "${gl_cyan}短ID: ${gl_bai}")" sid
        sni=$(select_sni)
        read -e -p "$(echo -e "${gl_cyan}指纹 (回车chrome): ${gl_bai}")" fp; [ -z "$fp" ] && fp="chrome"

        jq -n --argjson p "$port" --arg name "$name" --arg ip "$ip" --argjson bp "$bp" --arg pub "$pub" \
              --arg sid "$sid" --arg sni "$sni" --arg fp "$fp" \
              'input | . += [{"type":"vless-reality","name":$name,"port":$p,"mode":"relay","ip":$ip,"bp":$bp,"pub_key":$pub,"sid":$sid,"sni":$sni,"fp":$fp}]' \
              "$RULES_JSON" | safe_write_rules /dev/stdin
        echo -e "${gl_lv}✅ 节点 [${name}] 添加成功！${gl_bai}"

    elif [ "$m" == "3" ]; then
        echo -e "${gl_bright}========= 集群/负载均衡模式 =========${gl_bai}"
        echo -e "${gl_hui}说明: 客户端连接本端口，系统自动测速并分配给最快落地机${gl_bai}"
        echo -e "${gl_hui}所有落地机必须配置相同的 UUID！${gl_bai}"
        echo -e "${gl_bright}========================================${gl_bai}"
        
        read -e -p "$(echo -e "${gl_cyan}请输入集群统一 UUID (回车自动生成): ${gl_bai}")" uuid
        [ -z "$uuid" ] && uuid=$(cat /proc/sys/kernel/random/uuid)
        
        sni=$(select_sni)
        read -e -p "$(echo -e "${gl_cyan}统一 TLS 指纹 (回车chrome): ${gl_bai}")" fp; [ -z "$fp" ] && fp="chrome"
        
        local backends="[]"
        while true; do
            clear
            echo -e "${gl_kjlan}>>> 添加集群后端落地机 <<<${gl_bai}"
            echo -e "当前已添加: ${gl_lv}$(echo "$backends" | jq 'length')${gl_bai} 个"
            echo -e "----------------------------------------"
            read -e -p "$(echo -e "${gl_cyan}输入后端IP (回车完成添加): ${gl_bai}")" ip
            [ -z "$ip" ] && break
            
            read -e -p "$(echo -e "${gl_cyan}后端端口: ${gl_bai}")" bp; [[ ! "$bp" =~ ^[0-9]+$ ]] && echo -e "${gl_red}端口错误${gl_bai}" && continue
            
            read -e -p "$(echo -e "${gl_cyan}后端公钥: ${gl_bai}")" pub
            if [ -z "$pub" ]; then echo -e "${gl_red}公钥不能为空！${gl_bai}"; continue; fi
            
            read -e -p "$(echo -e "${gl_cyan}后端短ID (可留空): ${gl_bai}")" sid

            backends=$(echo "$backends" | jq --arg ip "$ip" --argjson bp "$bp" --arg pub "$pub" --arg sid "$sid" \
                '. += [{"ip":$ip, "bp":$bp, "pub_key":$pub, "sid":$sid}]')
            echo -e "${gl_lv}✅ 已添加: ${ip}:${bp}${gl_bai}"
            read -rs -n 1 -p "按任意键继续添加下一个..."
        done
        
        if [ "$(echo "$backends" | jq 'length')" -eq 0 ]; then
            echo -e "${gl_hui}未添加任何后端，已取消。${gl_bai}"; return
        fi

        jq -n --argjson p "$port" --arg name "$name" --arg u "$uuid" --arg sni "$sni" --arg fp "$fp" --argjson b "$backends" \
              'input | . += [{"type":"vless-reality","name":$name,"port":$p,"mode":"cluster","uuid":$u,"sni":$sni,"fp":$fp,"backends":$b}]' \
              "$RULES_JSON" | safe_write_rules /dev/stdin
        echo -e "\n${gl_lv}✅ 集群 [${name}] 添加成功！共 $(echo "$backends" | jq 'length') 个落地机${gl_bai}"
    fi
}

# ============================================================================
# 添加 Hysteria2 / Argo / Direct
# ============================================================================
add_hy2() {
    echo -e "\n${gl_lan}--- Hysteria 2 配置 ---${gl_bai}"
    read -e -p "$(echo -e "${gl_cyan}本机监听 UDP 端口: ${gl_bai}")" port
    [[ ! "$port" =~ ^[0-9]+$ ]] && echo -e "${gl_red}错误${gl_bai}" && return
    check_port_warn "$port"
    read -e -p "$(echo -e "${gl_cyan}节点备注名 (回车默认端口): ${gl_bai}")" name
    [ -z "$name" ] && name="Hy2-$port"
    echo -e "${gl_huang}>>> 请选择工作模式 <<<${gl_bai}"
    echo -e "${gl_lv}1. 本机直接落地 (自动生成证书) ★${gl_bai}"
    echo -e "${gl_hui}2. 中转模式${gl_bai}"
    read -e -p "$(echo -e "${gl_cyan}请选择 (1落地 / 2中转): ${gl_bai}")" m
    local sni; sni=$(select_sni)  # ✅ 修复：添加了缺失的 )
    local up_mb down_mb
    read -e -p "$(echo -e "${gl_cyan}上行带宽 Mbps (留空不限速): ${gl_bai}")" up_mb
    read -e -p "$(echo -e "${gl_cyan}下行带宽 Mbps (留空不限速): ${gl_bai}")" down_mb
    up_mb="${up_mb:-0}"; down_mb="${down_mb:-0}"

    if [ "$m" == "1" ]; then
        local pass; pass=$(openssl rand -base64 16)
        if [ ! -f "$HY2_CRT" ] || [ ! -f "$HY2_KEY" ]; then
            echo -e "${gl_huang}生成自签证书...${gl_bai}"
            openssl req -x509 -nodes -newkey rsa:2048 -keyout "$HY2_KEY" -out "$HY2_CRT" -subj "/CN=$sni" -days 3650 2>/dev/null
            chmod 644 "$HY2_CRT" "$HY2_KEY" 2>/dev/null
        fi
        jq -n --argjson p "$port" --arg name "$name" --arg pass "$pass" --arg sni "$sni" --argjson up "$up_mb" --argjson down "$down_mb" \
              'input | . += [{"type":"hysteria2","name":$name,"port":$p,"mode":"standalone","pass":$pass,"sni":$sni,"up":$up,"down":$down}]' \
              "$RULES_JSON" | safe_write_rules /dev/stdin
        echo -e "${gl_lv}✅ 节点 [${name}] 添加成功！${gl_bai}"
    else
        local ip bp pass
        read -e -p "$(echo -e "${gl_cyan}后端IP: ${gl_bai}")" ip; [ -z "$ip" ] && return
        read -e -p "$(echo -e "${gl_cyan}后端端口: ${gl_bai}")" bp; [[ ! "$bp" =~ ^[0-9]+$ ]] && return
        read -e -p "$(echo -e "${gl_cyan}密码: ${gl_bai}")" pass; [ -z "$pass" ] && return
        jq -n --argjson p "$port" --arg name "$name" --arg ip "$ip" --argjson bp "$bp" --arg pass "$pass" --arg sni "$sni" --argjson up "$up_mb" --argjson down "$down_mb" \
              'input | . += [{"type":"hysteria2","name":$name,"port":$p,"mode":"relay","ip":$ip,"bp":$bp,"pass":$pass,"sni":$sni,"up":$up,"down":$down}]' \
              "$RULES_JSON" | safe_write_rules /dev/stdin
        echo -e "${gl_lv}✅ 节点 [${name}] 添加成功${gl_bai}"
    fi
}

add_argo() {
    echo -e "\n${gl_lan}--- Argo + VLESS + WS 配置 ---${gl_bai}"
    read -e -p "$(echo -e "${gl_cyan}本机监听端口: ${gl_bai}")" port
    [[ ! "$port" =~ ^[0-9]+$ ]] && echo -e "${gl_red}错误${gl_bai}" && return
    check_port_warn "$port"
    read -e -p "$(echo -e "${gl_cyan}节点备注名 (回车默认端口): ${gl_bai}")" name
    [ -z "$name" ] && name="Argo-$port"
    echo -e "${gl_huang}>>> 请选择工作模式 <<<${gl_bai}"
    echo -e "${gl_lv}1. 本机直接落地 ★${gl_bai}"
    echo -e "${gl_hui}2. 中转模式${gl_bai}"
    read -e -p "$(echo -e "${gl_cyan}请选择 (1落地 / 2中转): ${gl_bai}")" m
    local path; read -e -p "$(echo -e "${gl_cyan}WS路径 (如 /ray): ${gl_bai}")" path; [ -z "$path" ] && path="/ray"
    if [ "$m" == "1" ]; then
        local uuid argo_domain; uuid=$(cat /proc/sys/kernel/random/uuid)
        read -e -p "$(echo -e "${gl_cyan}Argo 隧道域名 (留空稍后填): ${gl_bai}")" argo_domain
        jq -n --argjson p "$port" --arg name "$name" --arg u "$uuid" --arg path "$path" --arg domain "$argo_domain" \
              'input | . += [{"type":"argo","name":$name,"port":$p,"mode":"standalone","uuid":$u,"path":$path,"domain":$domain}]' \
              "$RULES_JSON" | safe_write_rules /dev/stdin
        echo -e "${gl_lv}✅ 节点 [${name}] 添加成功！${gl_bai}"
    else
        local ip bp
        read -e -p "$(echo -e "${gl_cyan}后端IP/域名: ${gl_bai}")" ip; [ -z "$ip" ] && return
        read -e -p "$(echo -e "${gl_cyan}后端端口: ${gl_bai}")" bp; [[ ! "$bp" =~ ^[0-9]+$ ]] && return
        jq -n --argjson p "$port" --arg name "$name" --arg ip "$ip" --argjson bp "$bp" --arg path "$path" \
              'input | . += [{"type":"argo","name":$name,"port":$p,"mode":"relay","ip":$ip,"bp":$bp,"path":$path}]' \
              "$RULES_JSON" | safe_write_rules /dev/stdin
        echo -e "${gl_lv}✅ 节点 [${name}] 添加成功${gl_bai}"
    fi
}

add_direct() {
    echo -e "\n${gl_lan}--- 纯端口转发 (透明中转) 配置 ---${gl_bai}"
    local port ip bp
    read -e -p "$(echo -e "${gl_cyan}本机监听端口: ${gl_bai}")" port; [[ ! "$port" =~ ^[0-9]+$ ]] && return
    check_port_warn "$port"
    read -e -p "$(echo -e "${gl_cyan}节点备注名 (回车默认端口): ${gl_bai}")" name
    [ -z "$name" ] && name="Direct-$port"
    local known_ips
    known_ips=$(jq -r '[.[] | select(.mode=="relay" or .type=="direct") | .ip] | unique | .[]' "$RULES_JSON" 2>/dev/null | sort -u | grep -v '^$')
    if [ -n "$known_ips" ]; then
        echo -e "${gl_huang}--- 选择后端目标 IP ---${gl_bai}"
        local idx=1; declare -A ip_map
        while IFS= read -r dip; do ip_map[$idx]="$dip"; echo -e "${gl_lv}$idx. $dip${gl_bai}"; ((idx++)); done <<< "$known_ips"
        echo -e "${gl_bright}0. 手动输入其他 IP${gl_bai}"
        read -e -p "$(echo -e "${gl_cyan}请选择序号 (0-$((idx-1))): ${gl_bai}")" sel
        if [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -gt 0 ] && [ -n "${ip_map[$sel]:-}" ]; then ip="${ip_map[$sel]}"; echo -e "${gl_lv}已选择: $ip${gl_bai}"
        else read -e -p "$(echo -e "${gl_cyan}手动输入后端目标 IP: ${gl_bai}")" ip; [ -z "$ip" ] && return; fi
    else read -e -p "$(echo -e "${gl_cyan}后端目标 IP: ${gl_bai}")" ip; [ -z "$ip" ] && return; fi
    read -e -p "$(echo -e "${gl_cyan}后端目标端口: ${gl_bai}")" bp; [[ ! "$bp" =~ ^[0-9]+$ ]] && return
    jq -n --argjson p "$port" --arg name "$name" --arg ip "$ip" --argjson bp "$bp" \
          'input | . += [{"type":"direct","name":$name,"port":$p,"ip":$ip,"bp":$bp}]' \
          "$RULES_JSON" | safe_write_rules /dev/stdin
    echo -e "${gl_lv}✅ 节点 [${name}] -> ${ip}:${bp} 添加成功${gl_bai}"
}

# ============================================================================
# 添加节点菜单
# ============================================================================
add_node_menu() {
    echo -e "\n${gl_lan}--- 添加节点 ---${gl_bai}"
    echo -e "${gl_lv}1. VLESS + Reality (支持集群)${gl_bai}"
    echo -e "${gl_lv}2. Hysteria 2${gl_bai}"
    echo -e "${gl_lv}3. Argo + VLESS + WS${gl_bai}"
    echo -e "${gl_lv}4. 纯端口转发${gl_bai}"
    echo -e "${gl_hui}0. 返回${gl_bai}"
    read -e -p "$(echo -e "${gl_cyan}请选择: ${gl_bai}")" c
    case $c in
        1) add_reality ;;
        2) add_hy2 ;;
        3) add_argo ;;
        4) add_direct ;;
        *) return ;;
    esac
}

# ============================================================================
# 查看节点列表
# ============================================================================
view_nodes() {
    local host_alias; host_alias=$(get_host_alias)
    echo -e "${gl_huang}----------------------------------------${gl_bai}"
    echo -e "${gl_cyan}本机身份: ${gl_lv}${host_alias}${gl_bai}"
    echo -e "${gl_huang}----------------------------------------${gl_bai}"
    local count; count=$(jq 'length' "$RULES_JSON")
    if [ "$count" -eq 0 ]; then echo -e "${gl_hui}暂无节点${gl_bai}"; return; fi
    for ((i=0; i<count; i++)); do
        local type mode port m_str name route_info=""
        type=$(jq -r ".[$i].type" "$RULES_JSON")
        mode=$(jq -r ".[$i].mode" "$RULES_JSON")
        port=$(jq -r ".[$i].port" "$RULES_JSON")
        name=$(jq -r ".[$i].name // \"未命名\"" "$RULES_JSON")
        
        if [ "$mode" == "standalone" ]; then m_str="${gl_kjlan}[落地]${gl_bai}"
        elif [ "$mode" == "cluster" ]; then
            local b_count
            b_count=$(jq ".[$i].backends | length" "$RULES_JSON")
            m_str="${gl_bright}[集群]${gl_bai} (${gl_lv}${b_count}个落地${gl_bai})"
        else
            local dip dbp
            dip=$(jq -r ".[$i].ip // empty" "$RULES_JSON")
            dbp=$(jq -r ".[$i].bp // empty" "$RULES_JSON")
            if [ "$type" == "direct" ]; then m_str="${gl_huang}[转发]${gl_bai}"; else m_str="${gl_hui}[中转]${gl_bai}"; fi
            if [ -n "$dip" ] && [ -n "$dbp" ]; then route_info=" ${gl_cyan}-> ${dip}:${dbp}${gl_bai}"; fi
        fi
        printf "${gl_lv}[%d] %-10s 端口:%-6s %-12s %s%s${gl_bai}\n" "$i" "$name" "$port" "$m_str" "$type" "$route_info"
    done
}

# ============================================================================
# 删除节点
# ============================================================================
del_node_inline() {
    local count; count=$(jq 'length' "$RULES_JSON")
    if [ "$count" -eq 0 ]; then echo -e "${gl_hui}节点列表为空${gl_bai}"; return; fi
    view_nodes
    echo -e "----------------------------------------"
    read -e -p "$(echo -e "${gl_cyan}输入要删除的序号 (0-$((count-1))), 回车跳过: ${gl_bai}")" idx
    [ -z "$idx" ] && return
    if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -lt "$count" ]; then
        local del_name del_type del_port
        del_name=$(jq -r ".[$idx].name // \"未命名\"" "$RULES_JSON")
        del_type=$(jq -r ".[$idx].type" "$RULES_JSON")
        del_port=$(jq -r ".[$idx].port" "$RULES_JSON")
        jq "del(.[$idx])" "$RULES_JSON" > "${RULES_JSON}.tmp" && sync && mv "${RULES_JSON}.tmp" "$RULES_JSON"
        echo -e "${gl_lv}✅ 已删除 [${idx}] ${del_name} (${del_type}:${del_port})${gl_bai}"
    else echo -e "${gl_red}序号无效${gl_bai}"; fi
}

del_node_by_port() {
    echo -e "${gl_cyan}[操作机: $(get_host_alias)]${gl_bai}"
    read -e -p "$(echo -e "${gl_cyan}输入要删除的监听端口: ${gl_bai}")" target_port
    [[ ! "$target_port" =~ ^[0-9]+$ ]] && echo -e "${gl_red}端口格式错误${gl_bai}" && return
    local count
    count=$(jq --argjson p "$target_port" '[.[] | select(.port == $p)] | length' "$RULES_JSON")
    if [ "$count" -eq 0 ]; then echo -e "${gl_hui}未找到监听端口 ${target_port} 的节点${gl_bai}"; return; fi
    echo -e "${gl_huang}找到以下匹配节点:${gl_bai}"
    jq -r --argjson p "$target_port" '.[] | select(.port == $p) | "  - \(.name // "未命名") (\(.type):\(.port))"' "$RULES_JSON"
    read -e -p "$(echo -e "${gl_red}确认删除以上 ${count} 条记录? (y/n): ${gl_bai}")" c
    if [ "$c" == "y" ]; then
        jq --argjson p "$target_port" 'del(.[] | select(.port == $p))' "$RULES_JSON" > "${RULES_JSON}.tmp" && sync && mv "${RULES_JSON}.tmp" "$RULES_JSON"
        echo -e "${gl_lv}✅ 已清理端口 ${target_port}${gl_bai}"
    else echo -e "${gl_hui}已取消${gl_bai}"; fi
}

# ============================================================================
# 链接 / 配置生成
# ============================================================================
view_links() {
    > "$LINKS_FILE"
    local ip has=0
    ip=$(get_public_ip)
    if [[ -z "$ip" ]] || ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${gl_red}自动获取公网IP失败！${gl_bai}"
        read -e -p "$(echo -e "${gl_cyan}请手动输入服务器IP: ${gl_bai}")" ip
        if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo -e "${gl_red}IP格式错误，无法生成链接${gl_bai}"; read -rs -n 1 -p "按任意键返回..."; return
        fi
    fi
    local count; count=$(jq 'length' "$RULES_JSON")
    for ((i=0; i<count; i++)); do
        local mode type link name
        mode=$(jq -r ".[$i].mode" "$RULES_JSON")
        [ "$mode" != "standalone" ] && continue
        type=$(jq -r ".[$i].type" "$RULES_JSON"); name=$(jq -r ".[$i].name // \"未命名\"" "$RULES_JSON")
        link=""
        case "$type" in
            vless-reality)
                local uuid port sni fp pub sid
                uuid=$(jq -r ".[$i].uuid" "$RULES_JSON")  # ✅ 修复：RULESJSON -> RULES_JSON
                port=$(jq -r ".[$i].port" "$RULES_JSON")
                sni=$(jq -r ".[$i].sni" "$RULES_JSON"); fp=$(jq -r ".[$i].fp" "$RULES_JSON")
                pub=$(jq -r ".[$i].pub_key" "$RULES_JSON")  # ✅ 修复：RULESJSON -> RULES_JSON
                sid=$(jq -r ".[$i].sid" "$RULES_JSON")
                link="vless://${uuid}@${ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(url_encode "$sni")&fp=$(url_encode "$fp")&pbk=$(url_encode "$pub")&sid=$(url_encode "$sid")&type=tcp#$(url_encode "$name")" ;;
            hysteria2)
                local pass sni port
                port=$(jq -r ".[$i].port" "$RULES_JSON"); pass=$(jq -r ".[$i].pass" "$RULES_JSON"); sni=$(jq -r ".[$i].sni" "$RULES_JSON")
                if [ -n "$pass" ]; then link="hysteria2://${pass}@${ip}:${port}?insecure=1&sni=$(url_encode "$sni")#$(url_encode "$name")"
                else link="hysteria2://${ip}:${port}?insecure=1&sni=$(url_encode "$sni")#$(url_encode "$name")"; fi ;;
            argo)
                local uuid path domain port
                port=$(jq -r ".[$i].port" "$RULES_JSON"); uuid=$(jq -r ".[$i].uuid" "$RULES_JSON")
                path=$(jq -r ".[$i].path" "$RULES_JSON"); domain=$(jq -r ".[$i].domain" "$RULES_JSON")
                if [ -n "$domain" ]; then link="vless://${uuid}@${domain}:443?encryption=none&security=tls&type=ws&path=$(url_encode "$path")#$(url_encode "$name")"; fi ;;
        esac
        if [ -n "$link" ]; then echo "$link" >> "$LINKS_FILE"; has=1; fi
    done
    local total; total=$(wc -l < "$LINKS_FILE" 2>/dev/null | tr -d ' '); [ -z "$total" ] && total=0
    echo -e "${gl_kjlan}========================================${gl_bai}"
    echo -e "       客户端一键导入链接 (共 ${gl_lv}${total}${gl_bai} 条)"
    echo -e "       节点归属: ${gl_lv}$(get_host_alias)${gl_bai}"
    echo -e "       服务器IP: ${gl_lv}${ip}${gl_bai}"
    echo -e "${gl_kjlan}========================================${gl_bai}"
    if [ "$has" -eq 0 ]; then echo -e "${gl_hui}暂无可用链接，请先添加【本机直接落地】节点。${gl_bai}"
    else
        local idx=1
        while IFS= read -r line; do echo -e "${gl_lv}[$idx] ${gl_kjlan}${line}${gl_bai}"; ((idx++)); done < "$LINKS_FILE"
        echo -e "----------------------------------------"
        echo -e "${gl_hui}如界面显示不全，请查看纯净文件:${gl_bai} ${gl_cyan}cat ${LINKS_FILE}${gl_bai}"
    fi
    echo -e "${gl_kjlan}========================================${gl_bai}"
}

apply_config() {
    if ! jq empty "$RULES_JSON" >/dev/null 2>&1; then
        echo -e "${gl_red}检测到节点配置被污染，已自动清空！${gl_bai}"; echo "[]" > "$RULES_JSON"; read -rs -n 1 -p "按任意键返回..."; return
    fi
    local count; count=$(jq 'length' "$RULES_JSON")
    if [ "$count" -eq 0 ]; then echo -e "${gl_red}错误：节点列表为空！${gl_bai}"; read -rs -n 1 -p "按任意键返回..."; return; fi

    local sb_ver ver_num ver_major ver_minor; sb_ver=$(get_sb_version)
    if [ -n "$sb_ver" ]; then
        echo -e "${gl_hui}检测到 sing-box ${sb_ver}${gl_bai}"
        ver_major=$(echo "$sb_ver" | cut -d. -f1); ver_minor=$(echo "$sb_ver" | cut -d. -f2)
        ver_num=$((ver_major * 100 + ver_minor))
        if [ "$ver_num" -lt 110 ]; then
            echo -e "${gl_huang}⚠️  警告: 本脚本按 1.10+ 格式生成，当前 ${sb_ver} 可能不兼容${gl_bai}"
            read -e -p "$(echo -e "${gl_cyan}继续? (y/n): ${gl_bai}")" c; [ "$c" != "y" ] && return
        fi
    else echo -e "${gl_huang}未检测到 sing-box, 仅生成配置文件${gl_bai}"; fi

    if [ -f "$CONF_FILE" ]; then
        local bak_name="config_$(date +%Y%m%d_%H%M%S).json"
        cp "$CONF_FILE" "${BAK_DIR}/${bak_name}"; echo -e "${gl_hui}旧配置已备份: ${BAK_DIR}/${bak_name}${gl_bai}"
    fi

    echo -e "${gl_lv}[1/3] 正在生成 JSON...${gl_bai}"
    local json; json=$(jq -n '{log:{level:"error"},inbounds:[],outbounds:[{type:"direct",tag:"direct"}],route:{rules:[],final:"direct"}}')

    for ((i=0; i<count; i++)); do
        local type mode port in_tag out_tag
        type=$(jq -r ".[$i].type" "$RULES_JSON"); mode=$(jq -r ".[$i].mode" "$RULES_JSON")
        port=$(jq -r ".[$i].port" "$RULES_JSON"); in_tag="in-${port}"; out_tag="out-${port}"

        case "$type" in
            vless-reality)
                if [ "$mode" == "standalone" ]; then
                    json=$(echo "$json" | jq --argjson p "$port" --arg in_tag "$in_tag" \
                        --arg u "$(jq -r ".[$i].uuid" "$RULES_JSON")" --arg pk "$(jq -r ".[$i].priv_key" "$RULES_JSON")" \
                        --arg sid "$(jq -r ".[$i].sid" "$RULES_JSON")" --arg sni "$(jq -r ".[$i].sni" "$RULES_JSON")" \
                        '.inbounds += [{"type": "vless", "tag": $in_tag, "listen": "::", "listen_port": $p, "users": [{"name": "user", "uuid": $u, "flow": "xtls-rprx-vision"}], "tls": {"enabled": true, "server_name": $sni, "reality": ({"enabled": true, "handshake": {"server": $sni, "server_port": 443}, "private_key": $pk} + (if $sid != "" then {"short_id": [$sid]} else {} end))}}]')
                elif [ "$mode" == "cluster" ]; then
                    local out_tags=""
                    local idx=0
                    while IFS= read -r be; do
                        local b_ip b_bp b_pub b_sid
                        b_ip=$(echo "$be" | jq -r ".ip")
                        b_bp=$(echo "$be" | jq -r ".bp")
                        b_pub=$(echo "$be" | jq -r ".pub_key")
                        b_sid=$(echo "$be" | jq -r ".sid // empty")  # ✅ 修复：添加了 jq
                        local cur_out="out-cluster-${idx}"
                        local sid_json="{}"
                        [ -n "$b_sid" ] && sid_json=",\"short_id\":\"$b_sid\""
                        out_tags+=",\"${cur_out}\""
                        json=$(echo "$json" | jq \
                            --argjson p "$port" --arg out "${cur_out}" --arg ip "$b_ip" --argjson bp "$b_bp" --arg pub "$b_pub" --arg sid_json "$sid_json" \
                            '.outbounds += [{"type": "vless", "tag": $out, "server": $ip, "server_port": $bp, "uuid": "00000000-0000-0000-0000-000000000000", "flow": "xtls-rprx-vision", "tls": {"enabled": true, "server_name": "www.microsoft.com", "utls": {"enabled": true, "fingerprint": "chrome"}, "reality": {"enabled": true, "public_key": $pub $sid_json}}}]')
                        ((idx++))
                    done < <(jq -c '.[]' <<< "$(jq -r ".[$i].backends" "$RULES_JSON")")
                    
                    out_tags="${out_tags#*,}"

                    json=$(echo "$json" | jq \
                        --arg in_tag "$in_tag" --arg u "$(jq -r ".[$i].uuid" "$RULES_JSON")" \
                        --arg sni "$(jq -r ".[$i].sni" "$RULES_JSON")" \
                        --arg fp "$(jq -r ".[$i].fp" "$RULES_JSON")" \
                        --argjson p "$port" \
                        --arg outs "[$out_tags]" \
                        '.inbounds += [{"type": "vless", "tag": $in_tag, "listen": "::", "listen_port": $p, "users": [{"name": "user", "uuid": $u, "flow": "xtls-rprx-vision"}], "tls": {"enabled": true, "server_name": $sni, "reality": {"enabled": true, "handshake": {"server": $sni, "server_port": 443}}}}]
                         | .outbounds += [{"type": "urltest", "tag": "urltest-\($p|tostring)", "outbounds": $outs, "url": "https://www.gstatic.com/generate_204", "interval": "5m"}]
                         | .route.rules += [{"inbound":[$in_tag], "outbound": "urltest-\($p|tostring)"}]')
                else
                    json=$(echo "$json" | jq --argjson p "$port" --arg in_tag "$in_tag" --arg out_tag "$out_tag" \
                        --arg ip "$(jq -r ".[$i].ip" "$RULES_JSON")" --argjson bp "$(jq -r ".[$i].bp" "$RULES_JSON")" \
                        --arg pub "$(jq -r ".[$i].pub_key" "$RULES_JSON")" --arg sid "$(jq -r ".[$i].sid" "$RULES_JSON")" \
                        --arg sni "$(jq -r ".[$i].sni" "$RULES_JSON")" --arg fp "$(jq -r ".[$i].fp" "$RULES_JSON")" \
                        '.inbounds += [{"type":"mixed","tag":$in_tag,"listen":"::","listen_port":$p}] | .outbounds += [{"type": "vless", "tag": $out_tag, "server": $ip, "server_port": $bp, "uuid": "00000000-0000-0000-0000-000000000000", "flow": "xtls-rprx-vision", "tls": {"enabled": true, "server_name": $sni, "utls": {"enabled": true, "fingerprint": $fp}, "reality": ({"enabled": true, "public_key": $pub} + (if $sid != "" then {"short_id": $sid} else {} end))}}}]')  # ✅ 修复：添加了 )
                    json=$(echo "$json" | jq --arg in "$in_tag" --arg out "$out_tag" '.route.rules += [{"inbound":[$in], "outbound":$out}]')
                fi ;;
            hysteria2)
                if [ "$mode" == "standalone" ]; then
                    json=$(echo "$json" | jq --argjson p "$port" --arg pass "$(jq -r ".[$i].pass" "$RULES_JSON")" \
                        --arg sni "$(jq -r ".[$i].sni" "$RULES_JSON")" --argjson up "$(jq -r ".[$i].up // 0" "$RULES_JSON")" \
                        --argjson down "$(jq -r ".[$i].down // 0" "$RULES_JSON")" \
                        '.inbounds += [{"type": "hysteria2", "tag": ("in-" + ($p|tostring)), "listen": "::", "listen_port": $p, "users": [{"name": "user", "password": $pass}], "tls": {"enabled": true, "server_name": $sni, "certificate_path": "/etc/sing-box/hy2.crt", "key_path": "/etc/sing-box/hy2.key"} + (if $up > 0 then {"up_mbps": $up} else {} end) + (if $down > 0 then {"down_mbps": $down} else {} end)}]')
                else
                    json=$(echo "$json" | jq --argjson p "$port" --arg in_tag "$in_tag" --arg out_tag "$out_tag" \
                        --arg ip "$(jq -r ".[$i].ip" "$RULES_JSON")" --argjson bp "$(jq -r ".[$i].bp" "$RULES_JSON")" \
                        --arg pass "$(jq -r ".[$i].pass" "$RULES_JSON")" --arg sni "$(jq -r ".[$i].sni" "$RULES_JSON")" \
                        '.inbounds += [{"type":"mixed","tag":$in_tag,"listen":"::","listen_port":$p}] | .outbounds += [{"type": "hysteria2", "tag": $out_tag, "server": $ip, "server_port": $bp, "password": $pass, "tls": {"enabled":true,"server_name":$sni,"insecure":true}}}]')  # ✅ 修复：添加了 )
                    json=$(echo "$json" | jq --arg in "$in_tag" --arg out "$out_tag" '.route.rules += [{"inbound":[$in], "outbound":$out}]')
                fi ;;
            argo)
                if [ "$mode" == "standalone" ]; then
                    json=$(echo "$json" | jq --argjson p "$port" --arg u "$(jq -r ".[$i].uuid" "$RULES_JSON")" \
                        --arg path "$(jq -r ".[$i].path" "$RULES_JSON")" \
                        '.inbounds += [{"type": "vless", "tag": ("in-" + ($p|tostring)), "listen": "::", "listen_port": $p, "users": [{"name": "user", "uuid": $u}], "transport": {"type":"ws","path":$path}}]')
                else
                    json=$(echo "$json" | jq --argjson p "$port" --arg in_tag "$in_tag" --arg out_tag "$out_tag" \
                        --arg ip "$(jq -r ".[$i].ip" "$RULES_JSON")" --argjson bp "$(jq -r ".[$i].bp" "$RULES_JSON")" \
                        --arg path "$(jq -r ".[$i].path" "$RULES_JSON")" \
                        '.inbounds += [{"type":"mixed","tag":$in_tag,"listen":"::","listen_port":$p}] | .outbounds += [{"type": "vless", "tag": $out_tag, "server": $ip, "server_port": $bp, "uuid": "00000000-0000-0000-0000-000000000000", "transport": {"type":"ws","path":$path}}}]')  # ✅ 修复：添加了 )
                    json=$(echo "$json" | jq --arg in "$in_tag" --arg out "$out_tag" '.route.rules += [{"inbound":[$in], "outbound":$out}]')
                fi ;;
            direct)
                json=$(echo "$json" | jq --argjson p "$port" --arg in_tag "$in_tag" \
                    --arg ip "$(jq -r ".[$i].ip" "$RULES_JSON")" --argjson bp "$(jq -r ".[$i].bp" "$RULES_JSON")" \
                    '.inbounds += [{"type": "direct", "tag": $in_tag, "listen": "::", "listen_port": $p, "override_address": $ip, "override_port": $bp}]')
                ;;
        esac
    done

    echo "$json" > "$TMP_FILE"
    echo -e "${gl_lv}[2/3] 安全校验中...${gl_bai}"
    if ! sing-box check -c "$TMP_FILE" >/dev/null 2>&1; then
        echo -e "${gl_red}❌ 校验失败！详细错误：${gl_bai}"; sing-box check -c "$TMP_FILE"
        rm -f "$TMP_FILE"; read -rs -n 1 -p "按任意键返回..."; return
    fi

    echo -e "${gl_lv}[3/3] 重启服务...${gl_bai}"
    cp -f "$TMP_FILE" "$CONF_FILE" && rm -f "$TMP_FILE"
    systemctl enable sing-box >/dev/null 2>&1; systemctl restart sing-box; sleep 1

    if systemctl is-active --quiet sing-box; then echo -e "${gl_lv}✅ 成功！服务已运行中！${gl_bai}"
    else echo -e "${gl_red}❌ 服务崩溃退出！日志：${gl_bai}"; journalctl -u sing-box -n 20 --no-pager; echo -e "${gl_huang}提示: 可从 ${BAK_DIR} 恢复旧配置${gl_bai}"; fi
    read -rs -n 1 -p "按任意键返回..."
}

# ============================================================================
# 恢复备份 / 查看日志
# ============================================================================
restore_backup() {
    if [ ! -d "$BAK_DIR" ] || [ -z "$(ls -A "$BAK_DIR" 2>/dev/null)" ]; then
        echo -e "${gl_hui}没有可用的备份${gl_bai}"; read -rs -n 1 -p "按任意键返回..."; return
    fi
    echo -e "${gl_huang}可用备份列表:${gl_bai}"
    local idx=0; declare -A bak_map
    for f in $(ls -t "$BAK_DIR"/*.json 2>/dev/null); do bak_map[$idx]="$f"; echo -e "${gl_lv}[$idx] ${f##*/}${gl_bai}"; ((idx++)); done
    read -e -p "$(echo -e "${gl_cyan}输入序号恢复 (回车取消): ${gl_bai}")" sel
    if [[ "$sel" =~ ^[0-9]+$ ]] && [ -n "${bak_map[$sel]:-}" ]; then
        systemctl stop sing-box 2>/dev/null; cp "${bak_map[$sel]}" "$CONF_FILE"; systemctl start sing-box 2>/dev/null
        echo -e "${gl_lv}✅ 已恢复: ${bak_map[$sel]}${gl_bai}"
    else echo -e "${gl_hui}已取消${gl_bai}"; fi
    read -rs -n 1 -p "按任意键返回..."
}
view_logs() {
    echo -e "${gl_huang}--- sing-box 最近 30 行日志 ---${gl_bai}"
    journalctl -u sing-box -n 30 --no-pager 2>/dev/null || echo -e "${gl_hui}无法读取日志${gl_bai}"
    read -rs -n 1 -p "按任意键返回..."
}

# ============================================================================
# 主菜单
# ============================================================================
main_menu() {
    check_env
    while true; do
        clear
        local r="${gl_red}未安装${gl_bai}" s="${gl_red}未运行${gl_bai}" b="${gl_red}未启用${gl_bai}" diag=""
        if command -v sing-box >/dev/null 2>&1 || [ -f "/usr/local/bin/sing-box" ]; then
            r="${gl_lv}已安装 ✅${gl_bai}"
            if systemctl is-active --quiet sing-box 2>/dev/null; then s="${gl_lv}运行中 ✅${gl_bai}"
            else
                s="${gl_red}未运行${gl_bai}"
                if systemctl is-enabled sing-box --quiet 2>/dev/null; then
                    if [ -f "$CONF_FILE" ]; then
                        if ! sing-box check -c "$CONF_FILE" >/dev/null 2>&1; then
                            diag="\n${gl_red}⚠ 诊断: config.json 格式错误！${gl_bai}\n${gl_hui}请选 5 重新生成，或选 8 查看日志${gl_bai}"
                        else
                            local last_err; last_err=$(journalctl -u sing-box -n 5 --no-pager 2>/dev/null | grep -i "fatal\|error" | tail -2)
                            if [ -n "$last_err" ]; then
                                diag="\n${gl_red}⚠ 最近错误:${gl_bai}"
                                while IFS= read -r line; do diag+="\n${gl_hui}  $line${gl_bai}"; done <<< "$last_err"
                                diag+="\n${gl_hui}选 8 查看完整日志 | 选 7 恢复备份${gl_bai}"
                            else diag="\n${gl_huang}💡 提示: 尚未生成配置，请选 5 启动${gl_bai}"; fi
                        fi
                    else diag="\n${gl_huang}💡 提示: 尚未生成配置，请选 5 启动${gl_bai}"; fi
                fi
            fi
            systemctl is-enabled sing-box --quiet 2>/dev/null && b="${gl_lv}已启用 ✅${gl_bai}"
        fi

        local n; n=$(jq 'length' "$RULES_JSON")  # ✅ 修复：添加了 )
        local host_alias; host_alias=$(get_host_alias)
        
        echo -e "${gl_kjlan}========================================${gl_bai}"
        echo -e "       Sing-Box 多协议节点管理脚本        "
        echo -e "       当前机器: ${gl_lv}${host_alias}${gl_bai}       "
        echo -e "========================================${gl_bai}"
        echo -e "核心状态: $r   |   运行状态: $s"
        echo -e "开机自启: $b   |   节点数量: ${gl_lv}${n}${gl_bai} 个"
        [ -n "$diag" ] && echo -e "$diag"
        echo -e "----------------------------------------"
        echo -e "${gl_lv}1. 安装/更新核心${gl_bai}"
        echo -e "${gl_huang}2. 添加节点 (支持单端口多落地集群)${gl_bai}"
        echo -e "${gl_hui}3. 查看/删除节点${gl_bai}"
        echo -e "${gl_kjlan}4. 📋 查看一键导入链接${gl_bai}"
        echo -e "----------------------------------------"
        echo -e "${gl_lv}5. 🧨 校验并启动服务 ★${gl_bai}"
        echo -e "${gl_hui}6. 停止服务${gl_bai}"
        echo -e "----------------------------------------"
        echo -e "${gl_huang}7. 📦 恢复备份配置${gl_bai}"
        echo -e "${gl_hui}8. 📜 查看服务日志${gl_bai}"
        echo -e "----------------------------------------"
        echo -e "${gl_red}9. 🗑️  卸载 sing-box${gl_bai}"
        echo -e "${gl_bright}10. 🔪 按端口精准删除${gl_bai}"
        echo -e "${gl_cyan}11. 🏷️ 修改本机备注名${gl_bai}"
        echo -e "----------------------------------------"
        echo -e "${gl_bright}0. 退出${gl_bai}"
        echo -e "${gl_kjlan}========================================${gl_bai}"
        read -e -p "$(echo -e "${gl_cyan}请输入选择 (0-11): ${gl_bai}")" c

        case $c in
            1) install_core ;;
            2) add_node_menu ;;
            3) del_node_inline; read -rs -n 1 -p "按任意键继续..." ;;
            4) view_links; read -rs -n 1 -p "按任意键继续..." ;;
            5) apply_config ;;
            6) systemctl stop sing-box 2>/dev/null; echo -e "${gl_lv}已停止${gl_bai}"; read -rs -n 1 -p "按任意键继续..." ;;
            7) restore_backup ;;
            8) view_logs ;;
            9) uninstall_core ;;
            10) del_node_by_port; read -rs -n 1 -p "按任意键继续..." ;;
            11) set_host_alias ;;
            0|"") exit 0 ;;
            *) echo -e "${gl_red}输入无效${gl_bai}"; sleep 1 ;;
        esac
    done
}

main_menu
