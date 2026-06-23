#!/usr/bin/env bash
# ============================================================================
# Sing-Box 多协议管理脚本 (完整修复增强版)
# 
# 原始修复:
#   1. line 338 缺失的闭合单引号 (致命语法错误根因)
#   2. /etc/singbing-box 拼写错误 -> /etc/sing-box
#   3. jq 中所有 "field":"$var" 改为 "field":$var
#   4. apply_config 中 $in_tag / $out_tag 通过 --arg 正确传入 jq
#   5. apply_config argo 中转 / direct 分支改用 jq 字符串拼接
#   6. hy2 证书同时检查 .crt 和 .key
#   7. 清理无用的 --arg tag 参数
#
# 本次增强:
#   8.  view_links 补全 Hysteria2 / Argo 链接生成
#   9.  add_argo 增加隧道域名字段, 用于生成完整链接
#  10.  删除节点 UX 重做, 一次输入即可删除
#  11.  apply_config 前自动备份旧配置 (带时间戳)
#  12.  添加端口冲突检测 (规则库 + 系统监听)
#  13.  apply_config 开头检测 sing-box 版本, 低于 1.10 给出警告
#  14.  Hysteria2 增加 up_mbps / down_mbps 带宽参数
#  15.  SNI 测速超时从 1s 改为 3s
#  16.  IP 获取增加 ifconfig.me / ip.sb 备用源
#  17.  jq 写入规则库后增加 sync 确保落盘
#  18.  数字类型统一使用 --argjson, 消除 |tonumber 噪音
#  19.  主菜单状态检测修正重复重定向
#  20.  增加 uninstall 功能
# ============================================================================

set -u

# ============================================================================
# 全局变量
# ============================================================================
RULES_JSON="/etc/sing-box/sb-relay-rules.json"
SERVERS_LIST="/etc/sing-box/sb-servers.list"
CONF_FILE="/etc/sing-box/config.json"
TMP_FILE="/tmp/sb-relay-tmp.json"
LINKS_FILE="/etc/sing-box/client_links.txt"
HY2_CRT="/etc/sing-box/hy2.crt"
HY2_KEY="/etc/sing-box/hy2.key"
BAK_DIR="/etc/sing-box/backup"

: "${gl_bai:=\033[0m}"
: "${gl_lv:=\033[32m}"
: "${gl_huang:=\033[33m}"
: "${gl_hui:=\033[90m}"
: "${gl_red:=\033[31m}"
: "${gl_kjlan:=\033[32m}"
: "${gl_lan:=\033[34m}"

# ============================================================================
# 环境检测与初始化
# ============================================================================
check_env() {
    [ "$(id -u)" -ne 0 ] && echo -e "${gl_red}请使用 root 运行${gl_bai}" && exit 1

    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${gl_huang}安装 jq...${gl_bai}"
        if command -v apt >/dev/null 2>&1; then
            apt-get update -qq && apt-get install -y jq -qq
        elif command -v yum >/dev/null 2>&1; then
            yum install -y jq -q
        else
            echo -e "${gl_red}无法自动安装 jq，请手动安装后重试${gl_bai}" && exit 1
        fi
    fi

    if ! command -v openssl >/dev/null 2>&1; then
        if command -v apt >/dev/null 2>&1; then
            apt-get install -y openssl -qq
        elif command -v yum >/dev/null 2>&1; then
            yum install -y openssl -q
        fi
    fi

    mkdir -p /etc/sing-box "$BAK_DIR"
    [ ! -f "$SERVERS_LIST" ] && touch "$SERVERS_LIST"
    [ ! -f "$LINKS_FILE" ] && touch "$LINKS_FILE"

    # 如果 rules.json 不存在或被污染, 自动初始化为空数组
    if [ ! -f "$RULES_JSON" ] || ! jq empty "$RULES_JSON" >/dev/null 2>&1; then
        echo "[]" > "$RULES_JSON"
    fi
}

# ============================================================================
# 工具函数
# ============================================================================
url_encode() {
    echo -n "$1" | jq -sRr @uri
}

# 获取本机公网 IP (多源备用)
get_public_ip() {
    curl -s --connect-timeout 3 ipinfo.io/ip 2>/dev/null \
        || curl -s --connect-timeout 3 ifconfig.me 2>/dev/null \
        || curl -s --connect-timeout 3 ip.sb 2>/dev/null \
        || echo "YOUR_SERVER_IP"
}

# 获取 sing-box 主版本号 (如 1.10 -> "1.10")
get_sb_version() {
    sing-box version 2>/dev/null | grep -oP '\d+\.\d+' | head -1
}

# 端口冲突检测: 返回 0=无冲突, 1=有冲突
check_port_conflict() {
    local port="$1"
    # 1) 检查规则库中是否已有
    local used
    used=$(jq -r '.[].port' "$RULES_JSON" 2>/dev/null | grep -x "$port")
    if [ -n "$used" ]; then
        echo -e "${gl_red}端口 $port 已在节点列表中！${gl_bai}"
        return 1
    fi
    # 2) 检查系统实际监听
    if ss -tlnup 2>/dev/null | grep -q ":${port} "; then
        echo -e "${gl_huang}警告: 端口 $port 已有程序监听${gl_bai}"
        read -e -p "是否继续? (y/n): " c
        [ "$c" != "y" ] && return 1
    fi
    return 0
}

# 安全写入 rules.json (原子 + sync)
safe_write_rules() {
    local src="$1"
    cp "$src" "${RULES_JSON}.tmp" && sync && mv "${RULES_JSON}.tmp" "$RULES_JSON"
}

# ============================================================================
# SNI 选择
# ============================================================================
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
            for i in "www.apple.com" "dl.google.com" "www.amazon.com" "www.microsoft.com"; do
                local n
                n=$(curl -o /dev/null -s -w '%{time_connect}' --max-time 3 -4 "https://$i" 2>/dev/null | awk '{printf "%d",$1*1000}')
                [ -n "$n" ] && [ "$n" -lt "$t" ] && t=$n d=$i
            done
            echo -e "${gl_lv}选用: $d (${t}ms)${gl_bai}"
            echo "$d"
            ;;
        3) read -e -p "输入域名: " s; echo "${s:-www.microsoft.com}" ;;
        *) echo "www.microsoft.com" ;;
    esac
}

# ============================================================================
# 安装 / 卸载核心
# ============================================================================
install_core() {
    echo -e "${gl_huang}正在连接官方源安装...${gl_bai}"
    if command -v apt >/dev/null 2>&1; then
        curl -fsSL https://sing-box.app/deb-install.sh | bash
    elif command -v yum >/dev/null 2>&1; then
        curl -fsSL https://sing-box.app/rpm-install.sh | bash
    else
        echo -e "${gl_red}不支持该系统${gl_bai}"
    fi
    read -rs -n 1 -p "按任意键返回..."
}

uninstall_core() {
    echo -e "${gl_red}即将卸载 sing-box 并清理所有配置！${gl_bai}"
    read -e -p "确定? (输入 YES 确认): " c
    if [ "$c" == "YES" ]; then
        systemctl stop sing-box 2>/dev/null
        systemctl disable sing-box 2>/dev/null
        if command -v apt >/dev/null 2>&1; then
            apt-get remove -y sing-box 2>/dev/null
        elif command -v yum >/dev/null 2>&1; then
            yum remove -y sing-box 2>/dev/null
        fi
        rm -rf /etc/sing-box
        echo -e "${gl_lv}已完全卸载${gl_bai}"
    else
        echo -e "${gl_hui}已取消${gl_bai}"
    fi
    read -rs -n 1 -p "按任意键返回..."
}

# ============================================================================
# 添加节点 - 主菜单
# ============================================================================
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

# ============================================================================
# 添加 VLESS + Reality
# ============================================================================
add_reality() {
    echo -e "\n${gl_lan}--- VLESS + Reality 配置 ---${gl_bai}"
    read -e -p "本机监听端口 (如 443): " port
    [[ ! "$port" =~ ^[0-9]+$ ]] && echo -e "${gl_red}端口错误${gl_bai}" && return
    check_port_conflict "$port" || return

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
        [ -z "$pub" ] && echo -e "${gl_red}生成失败，请检查核心是否已安装${gl_bai}" && return

        sni=$(select_sni)
        read -e -p "TLS 指纹 (直接回车默认 chrome): " fp; [ -z "$fp" ] && fp="chrome"
        read -e -p "短ID ShortId (可留空): " sid

        jq -n --argjson p "$port" --arg u "$uuid" --arg pk "$pk" --arg pub "$pub" \
              --arg sid "$sid" --arg sni "$sni" --arg fp "$fp" \
              'input | . += [{"type":"vless-reality","port":$p,"mode":"standalone","uuid":$u,"priv_key":$pk,"pub_key":$pub,"sid":$sid,"sni":$sni,"fp":$fp}]' \
              "$RULES_JSON" | safe_write_rules /dev/stdin
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
            echo -e "${gl_red}⚠️  请将此私钥填入后端配置:${gl_bai}"
            echo -e "${gl_kjlan}${pk}${gl_bai}"
            read -rs -n 1 -p "已复制私钥？按任意键继续..."
        elif [ -z "$pub" ]; then
            echo -e "${gl_red}公钥不能为空！${gl_bai}"; return
        fi
        read -e -p "短ID: " sid
        sni=$(select_sni)
        read -e -p "指纹 (直接回车 chrome): " fp; [ -z "$fp" ] && fp="chrome"

        jq -n --argjson p "$port" --arg ip "$ip" --argjson bp "$bp" --arg pub "$pub" \
              --arg sid "$sid" --arg sni "$sni" --arg fp "$fp" \
              'input | . += [{"type":"vless-reality","port":$p,"mode":"relay","ip":$ip,"bp":$bp,"pub_key":$pub,"sid":$sid,"sni":$sni,"fp":$fp}]' \
              "$RULES_JSON" | safe_write_rules /dev/stdin
        echo -e "${gl_lv}✅ 中转规则添加成功！${gl_bai}"
    fi
}

# ============================================================================
# 添加 Hysteria2
# ============================================================================
add_hy2() {
    echo -e "\n${gl_lan}--- Hysteria 2 配置 ---${gl_bai}"
    read -e -p "本机监听 UDP 端口 (如 8443): " port
    [[ ! "$port" =~ ^[0-9]+$ ]] && echo -e "${gl_red}错误${gl_bai}" && return
    check_port_conflict "$port" || return

    echo -e "\n>>> 请选择工作模式 <<<"
    echo -e "${gl_lv}1. 本机直接落地 (自动生成证书) ★${gl_bai}"
    echo -e "${gl_hui}2. 中转模式${gl_bai}"
    read -e -p "请选择 (1/2): " m
    local sni
    sni=$(select_sni)

    # 带宽参数 (可选)
    local up_mb down_mb
    read -e -p "上行带宽 Mbps (留空不限速): " up_mb
    read -e -p "下行带宽 Mbps (留空不限速): " down_mb
    # 空值转 0, 后续 jq 中 0 代表 null
    up_mb="${up_mb:-0}"
    down_mb="${down_mb:-0}"

    if [ "$m" == "1" ]; then
        local pass
        pass=$(openssl rand -base64 16)
        # 同时检查 .crt 和 .key, 任一缺失就重新生成一对
        if [ ! -f "$HY2_CRT" ] || [ ! -f "$HY2_KEY" ]; then
            echo -e "${gl_huang}生成自签证书...${gl_bai}"
            openssl req -x509 -nodes -newkey rsa:2048 \
                -keyout "$HY2_KEY" -out "$HY2_CRT" \
                -subj "/CN=$sni" -days 3650 2>/dev/null
        fi

        jq -n --argjson p "$port" --arg pass "$pass" --arg sni "$sni" \
              --argjson up "$up_mb" --argjson down "$down_mb" \
              'input | . += [{"type":"hysteria2","port":$p,"mode":"standalone","pass":$pass,"sni":$sni,"up":$up,"down":$down}]' \
              "$RULES_JSON" | safe_write_rules /dev/stdin
        echo -e "${gl_lv}✅ Hy2 节点添加成功！${gl_bai}"
    else
        local ip bp pass
        read -e -p "后端IP: " ip; [ -z "$ip" ] && return
        read -e -p "后端端口: " bp; [[ ! "$bp" =~ ^[0-9]+$ ]] && return
        read -e -p "密码: " pass; [ -z "$pass" ] && return

        jq -n --argjson p "$port" --arg ip "$ip" --argjson bp "$bp" --arg pass "$pass" \
              --arg sni "$sni" --argjson up "$up_mb" --argjson down "$down_mb" \
              'input | . += [{"type":"hysteria2","port":$p,"mode":"relay","ip":$ip,"bp":$bp,"pass":$pass,"sni":$sni,"up":$up,"down":$down}]' \
              "$RULES_JSON" | safe_write_rules /dev/stdin
        echo -e "${gl_lv}✅ 中转规则添加成功${gl_bai}"
    fi
}

# ============================================================================
# 添加 Argo + VLESS + WS
# ============================================================================
add_argo() {
    echo -e "\n${gl_lan}--- Argo + VLESS + WS 配置 ---${gl_bai}"
    read -e -p "本机监听端口 (如 8080): " port
    [[ ! "$port" =~ ^[0-9]+$ ]] && echo -e "${gl_red}错误${gl_bai}" && return
    check_port_conflict "$port" || return

    echo -e "\n>>> 请选择工作模式 <<<"
    echo -e "${gl_lv}1. 本机直接落地 ★${gl_bai}"
    echo -e "${gl_hui}2. 中转模式${gl_bai}"
    read -e -p "请选择 (1/2): " m
    local path
    read -e -p "WS路径 (如 /ray): " path; [ -z "$path" ] && path="/ray"

    if [ "$m" == "1" ]; then
        local uuid argo_domain
        uuid=$(cat /proc/sys/kernel/random/uuid)
        read -e -p "Argo 隧道域名 (如 xxx.trycloudflare.com, 留空稍后填写): " argo_domain

        jq -n --argjson p "$port" --arg u "$uuid" --arg path "$path" --arg domain "$argo_domain" \
              'input | . += [{"type":"argo","port":$p,"mode":"standalone","uuid":$u,"path":$path,"domain":$domain}]' \
              "$RULES_JSON" | safe_write_rules /dev/stdin
        echo -e "${gl_lv}✅ Argo 后端添加成功！${gl_bai}"
    else
        local ip bp
        read -e -p "后端IP/域名: " ip; [ -z "$ip" ] && return
        read -e -p "后端端口: " bp; [[ ! "$bp" =~ ^[0-9]+$ ]] && return

        jq -n --argjson p "$port" --arg ip "$ip" --argjson bp "$bp" --arg path "$path" \
              'input | . += [{"type":"argo","port":$p,"mode":"relay","ip":$ip,"bp":$bp,"path":$path}]' \
              "$RULES_JSON" | safe_write_rules /dev/stdin
        echo -e "${gl_lv}✅ 中转规则添加成功${gl_bai}"
    fi
}

# ============================================================================
# 添加纯端口转发
# ============================================================================
add_direct() {
    echo -e "\n${gl_lan}--- 纯端口转发配置 ---${gl_bai}"
    local port ip bp
    read -e -p "本机监听端口: " port; [[ ! "$port" =~ ^[0-9]+$ ]] && return
    check_port_conflict "$port" || return
    read -e -p "后端目标 IP: " ip; [ -z "$ip" ] && return
    read -e -p "后端目标端口: " bp; [[ ! "$bp" =~ ^[0-9]+$ ]] && return

    jq -n --argjson p "$port" --arg ip "$ip" --argjson bp "$bp" \
          'input | . += [{"type":"direct","port":$p,"ip":$ip,"bp":$bp}]' \
          "$RULES_JSON" | safe_write_rules /dev/stdin
    echo -e "${gl_lv}✅ 纯转发节点添加成功${gl_bai}"
}

# ============================================================================
# 查看节点列表
# ============================================================================
view_nodes() {
    echo -e "${gl_huang}----------------------------------------${gl_bai}"
    local count
    count=$(jq 'length' "$RULES_JSON")
    if [ "$count" -eq 0 ]; then
        echo -e "${gl_hui}暂无节点${gl_bai}"
        return
    fi
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

# ============================================================================
# 查看一键导入链接 (完整版: Reality + Hy2 + Argo)
# ============================================================================
view_links() {
    > "$LINKS_FILE"
    local ip
    ip=$(get_public_ip)
    local has=0

    echo -e "${gl_kjlan}========================================${gl_bai}"
    echo -e "       客户端一键导入链接 (实时生成)       "
    echo -e "       服务器IP: ${gl_lv}${ip}${gl_bai}"
    echo -e "${gl_kjlan}========================================${gl_bai}"

    local count
    count=$(jq 'length' "$RULES_JSON")
    for ((i=0; i<count; i++)); do
        local mode type link
        mode=$(jq -r ".[$i].mode" "$RULES_JSON")
        [ "$mode" != "standalone" ] && continue
        type=$(jq -r ".[$i].type" "$RULES_JSON")
        link=""

        case "$type" in
            vless-reality)
                local uuid port sni fp pub sid
                uuid=$(jq -r ".[$i].uuid" "$RULES_JSON")
                port=$(jq -r ".[$i].port" "$RULES_JSON")
                sni=$(jq -r ".[$i].sni" "$RULES_JSON")
                fp=$(jq -r ".[$i].fp" "$RULES_JSON")
                pub=$(jq -r ".[$i].pub_key" "$RULES_JSON")
                sid=$(jq -r ".[$i].sid" "$RULES_JSON")
                link="vless://${uuid}@${ip}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(url_encode "$sni")&fp=$(url_encode "$fp")&pbk=$(url_encode "$pub")&sid=$(url_encode "$sid")&type=tcp#Reality-${port}"
                ;;
            hysteria2)
                local pass sni port
                port=$(jq -r ".[$i].port" "$RULES_JSON")
                pass=$(jq -r ".[$i].pass" "$RULES_JSON")
                sni=$(jq -r ".[$i].sni" "$RULES_JSON")
                if [ -n "$pass" ]; then
                    link="hysteria2://${pass}@${ip}:${port}?insecure=1&sni=$(url_encode "$sni")#Hy2-${port}"
                else
                    link="hysteria2://${ip}:${port}?insecure=1&sni=$(url_encode "$sni")#Hy2-${port}"
                fi
                ;;
            argo)
                local uuid path domain port
                port=$(jq -r ".[$i].port" "$RULES_JSON")
                uuid=$(jq -r ".[$i].uuid" "$RULES_JSON")
                path=$(jq -r ".[$i].path" "$RULES_JSON")
                domain=$(jq -r ".[$i].domain" "$RULES_JSON")
                if [ -n "$domain" ]; then
                    link="vless://${uuid}@${domain}:443?encryption=none&security=tls&type=ws&path=$(url_encode "$path")#Argo-${port}"
                else
                    echo -e "${gl_hui}[Argo-$port] 缺少隧道域名，跳过生成链接${gl_bai}"
                fi
                ;;
        esac

        if [ -n "$link" ]; then
            echo -e "${gl_kjlan}${link}${gl_bai}" | tee -a "$LINKS_FILE"
            has=1
        fi
    done

    if [ "$has" -eq 0 ]; then
        echo -e "${gl_hui}暂无可用链接，请先添加【本机直接落地】节点。${gl_bai}"
    else
        echo -e "${gl_hui}链接已同步保存至: ${LINKS_FILE}${gl_bai}"
    fi
    echo -e "${gl_kjlan}========================================${gl_bai}"
}

# ============================================================================
# 删除节点 (内联版, 不再二次询问)
# ============================================================================
del_node_inline() {
    local count
    count=$(jq 'length' "$RULES_JSON")
    if [ "$count" -eq 0 ]; then
        echo -e "${gl_hui}节点列表为空${gl_bai}"
        return
    fi
    view_nodes
    echo -e "----------------------------------------"
    read -e -p "输入要删除的序号 (0-$((count-1))), 回车跳过: " idx
    if [ -z "$idx" ]; then
        return
    fi
    if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -lt "$count" ]; then
        local del_type del_port
        del_type=$(jq -r ".[$idx].type" "$RULES_JSON")
        del_port=$(jq -r ".[$idx].port" "$RULES_JSON")
        jq "del(.[$idx])" "$RULES_JSON" > "${RULES_JSON}.tmp" && sync && mv "${RULES_JSON}.tmp" "$RULES_JSON"
        echo -e "${gl_lv}✅ 已删除 [${idx}] ${del_type}:${del_port}${gl_bai}"
    else
        echo -e "${gl_red}序号无效${gl_bai}"
    fi
}

# ============================================================================
# 配置生成与应用引擎 (纯原生 jq 索引循环, sing-box 1.10+ schema)
# ============================================================================
apply_config() {
    # 前置校验
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

    # 版本检测
    local sb_ver
    sb_ver=$(get_sb_version)
    if [ -n "$sb_ver" ]; then
        echo -e "${gl_hui}检测到 sing-box ${sb_ver}${gl_bai}"
        # 简单数值比较: 1.8 -> 18, 1.10 -> 110
        local ver_major ver_minor ver_num
        ver_major=$(echo "$sb_ver" | cut -d. -f1)
        ver_minor=$(echo "$sb_ver" | cut -d. -f2)
        ver_num=$((ver_major * 100 + ver_minor))
        if [ "$ver_num" -lt 110 ]; then
            echo -e "${gl_huang}⚠️  警告: 本脚本按 sing-box 1.10+ 格式生成配置${gl_bai}"
            echo -e "${gl_huang}   当前版本 ${sb_ver} 可能不兼容, 建议升级${gl_bai}"
            read -e -p "是否继续? (y/n): " c
            [ "$c" != "y" ] && return
        fi
    else
        echo -e "${gl_huang}未检测到 sing-box, 将仅生成配置文件${gl_bai}"
    fi

    # 备份旧配置
    if [ -f "$CONF_FILE" ]; then
        local bak_name="config_$(date +%Y%m%d_%H%M%S).json"
        cp "$CONF_FILE" "${BAK_DIR}/${bak_name}"
        echo -e "${gl_hui}旧配置已备份: ${BAK_DIR}/${bak_name}${gl_bai}"
    fi

    echo -e "${gl_lv}[1/3] 正在生成 JSON (纯原生jq引擎)...${gl_bai}"
    local json
    json=$(jq -n '{log:{level:"error"},inbounds:[],outbounds:[{type:"direct",tag:"direct"}],route:{rules:[],final:"direct"}}')

    for ((i=0; i<count; i++)); do
        local type mode port in_tag out_tag
        type=$(jq -r ".[$i].type" "$RULES_JSON")
        mode=$(jq -r ".[$i].mode" "$RULES_JSON")
        port=$(jq -r ".[$i].port" "$RULES_JSON")
        in_tag="in-${port}"
        out_tag="out-${port}"

        case "$type" in
            # ============================================================
            # VLESS + Reality
            # ============================================================
            vless-reality)
                if [ "$mode" == "standalone" ]; then
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
                ;;

            # ============================================================
            # Hysteria2
            # ============================================================
            hysteria2)
                if [ "$mode" == "standalone" ]; then
                    json=$(echo "$json" | jq \
                        --argjson p "$port" \
                        --arg pass "$(jq -r ".[$i].pass" "$RULES_JSON")" \
                        --arg sni "$(jq -r ".[$i].sni" "$RULES_JSON")" \
                        --argjson up "$(jq -r ".[$i].up // 0" "$RULES_JSON")" \
                        --argjson down "$(jq -r ".[$i].down // 0" "$RULES_JSON")" \
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
                            + (if $up > 0 then {"up_mbps": $up} else {} end)
                            + (if $down > 0 then {"down_mbps": $down} else {} end)
                        }]')
                else
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
                ;;

            # ============================================================
            # Argo + VLESS + WS
            # ============================================================
            argo)
                if [ "$mode" == "standalone" ]; then
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
                ;;

            # ============================================================
            # 纯端口转发
            # ============================================================
            direct)
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
                ;;
        esac
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
        echo -e "${gl_lv}✅ 成功！服务已运行中！${gl_bai}"
    else
        echo -e "${gl_red}❌ 服务崩溃退出！日志：${gl_bai}"
        journalctl -u sing-box -n 20 --no-pager
        echo -e "${gl_huang}提示: 可从 ${BAK_DIR} 恢复旧配置${gl_bai}"
    fi
    read -rs -n 1 -p "按任意键返回..."
}

# ============================================================================
# 恢复备份配置
# ============================================================================
restore_backup() {
    if [ ! -d "$BAK_DIR" ] || [ -z "$(ls -A "$BAK_DIR" 2>/dev/null)" ]; then
        echo -e "${gl_hui}没有可用的备份${gl_bai}"
        read -rs -n 1 -p "按任意键返回..."
        return
    fi
    echo -e "${gl_huang}可用备份列表:${gl_bai}"
    local idx=0
    declare -A bak_map
    for f in $(ls -t "$BAK_DIR"/*.json 2>/dev/null); do
        bak_map[$idx]="$f"
        echo -e "${gl_lv}[$idx] ${f##*/}${gl_bai}"
        ((idx++))
    done
    read -e -p "输入序号恢复 (回车取消): " sel
    if [[ "$sel" =~ ^[0-9]+$ ]] && [ -n "${bak_map[$sel]:-}" ]; then
        systemctl stop sing-box 2>/dev/null
        cp "${bak_map[$sel]}" "$CONF_FILE"
        systemctl start sing-box 2>/dev/null
        echo -e "${gl_lv}✅ 已恢复: ${bak_map[$sel]}${gl_bai}"
    else
        echo -e "${gl_hui}已取消${gl_bai}"
    fi
    read -rs -n 1 -p "按任意键返回..."
}

# ============================================================================
# 查看服务日志
# ============================================================================
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

        # 状态检测
        local r="${gl_red}未安装${gl_bai}"
        local s="${gl_red}未运行${gl_bai}"
        local b="${gl_red}未启用${gl_bai}"
        if command -v sing-box >/dev/null 2>&1 || [ -f "/usr/local/bin/sing-box" ]; then
            r="${gl_lv}已安装 ✅${gl_bai}"
            if systemctl is-active --quiet sing-box 2>/dev/null; then
                s="${gl_lv}运行中 ✅${gl_bai}"
            else
                s="${gl_red}未运行${gl_bai}"
            fi
            if systemctl is-enabled sing-box --quiet 2>/dev/null; then
                b="${gl_lv}已启用 ✅${gl_bai}"
            fi
        fi

        local n
        n=$(jq 'length' "$RULES_JSON")

        echo -e "${gl_kjlan}========================================${gl_bai}"
        echo -e "       Sing-Box 多协议节点管理脚本        "
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
        echo -e "${gl_huang}7. 📦 恢复备份配置${gl_bai}"
        echo -e "${gl_hui}8. 📜 查看服务日志${gl_bai}"
        echo -e "${gl_red}9. 🗑️  卸载 sing-box${gl_bai}"
        echo -e "----------------------------------------"
        echo -e "0. 退出"
        echo -e "${gl_kjlan}========================================${gl_bai}"
        read -e -p "请输入选择: " c

        case $c in
            1) install_core ;;
            2) add_node_menu ;;
            3)
                del_node_inline
                read -rs -n 1 -p "按任意键继续..."
                ;;
            4)
                view_links
                read -rs -n 1 -p "按任意键继续..."
                ;;
            5) apply_config ;;
            6)
                systemctl stop sing-box 2>/dev/null
                echo -e "${gl_lv}已停止${gl_bai}"
                read -rs -n 1 -p "按任意键继续..."
                ;;
            7) restore_backup ;;
            8) view_logs ;;
            9) uninstall_core ;;
            0|"") exit 0 ;;
            *) echo -e "${gl_red}输入无效${gl_bai}"; sleep 1 ;;
        esac
    done
}

# ============================================================================
# 入口
# ============================================================================
main_menu
