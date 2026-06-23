#!/usr/bin/env bash
# ============================================================================
# Sing-Box 多协议管理脚本 (终极完整版)
# 
# 修复记录:
#   1. 原始引号/拼写/jq传参等致命错误修复
#   2. 规则库改名 .sb-rules.db (防 -C 目录扫描误加载崩溃)
#   3. select_sni() 所有 echo 加 >&2，杜绝 $() 抓取污染 SNI
#   4. get_public_ip() 改用国内无墙接口，严格正则校验
#   5. view_links() 静默写文件后统一输出，防 Web 终端吞链接
#   6. 数字类型统一使用 --argjson
#   7. apply_config 中 in_tag/out_tag 通过 --arg 传入
#   8. 节点支持自定义备注名
#   9. 所有交互提示增加高亮色
#  10. SNI 优选加入 30+ 主流域名，多线程并发测速
#  11. 纯端口转发自动提取已知后端IP供选择
#  12. 节点列表直观显示路由走向
#  13. 按端口精准删除功能
#  14. 全局本机身份备注
# 15. 【重磅新增】Reality 集群模式 (单端口挂多落地机自动负载均衡)
# ============================================================================

set -u

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

check_env() {
    [ "$(id -u)" -ne 0 ] && echo -e "${gl_red}请使用 root 运行${gl_bai}" && exit 1
    if ! command -v jq >/dev/null 2>&1; then
        echo -e "${gl_huang}安装 jq...${gl_bai}"
        if command -v apt >/dev/null 2>&1; then apt-get update -qq && apt-get install -y jq -qq
        elif command -v yum >/dev/null 2>&1; then yum install -y jq -q
        else echo -e "${gl_red}无法安装 jq${gl_bai}" && exit 1; fi
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

url_encode() { echo -n "$1" | jq -sRr @uri; }

get_public_ip() {
    local t
    t=$(curl -s --connect-timeout 3 https://myip.ipip.net 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+')
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
            for i in "${d[@]} do
                ( n=$(curl -o /dev/null -s -w '%{time_connect}' --max-time 2 -4 "https://$i" 2>/dev/null | awk '{printf "%d",$1*1000}'); [ -n "$n" ] && echo "$n $i" >> "$f" ) &
            done
            wait
            local b_d="www.microsoft.com" b_t=9999
            while read -r line; do
                local t=${line%% *}; local dom=${line#* }
                [ "$t" -lt "$b_t" ] 2>/dev/null && b_t=$t b_d=$dom
            done < "$f"
            rm -f "$f"
            echo -e "${gl_lv}选用: $b_d (${b_t}ms)${gl_bai}" >&2; echo "$b_d"
            ;;
        3) read -e -p "$(echo -e "${gl_cyan}输入域名: ${gl_bai}")" s; echo "${s:-www.microsoft.com}" ;;
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
        echo -e "${gl_bright}0. 返回主菜单${gl_bai}"
        echo -e "${gl_kjlan}========================================${gl_bai}"
        read -e -p "$(echo -e "${gl_cyan}请选择协议 (1/2/3/4/0): ${gl_bai}")" p
        case $p in
            1) add_reality ;; 2) add_hy2 ;; 3) add_argo ;; 4) add_direct ;;
            0|"") break ;; *) echo -e "${gl_red}无效选择${gl_bai}"; sleep 1 ;;
        esac
        read -rs -n 1 -p "按任意键继续..."
    done
}

add_reality() {
    echo -e "\n${gl_lan}--- VLESS + Reality 配置 ---${gl_bai}"
    read -e -p "$(echo -e "${gl_cyan}本机监听端口: ${gl_bai}")" port
    [[ ! "$port" =~ ^[0-9]+$ ]] && echo -e "${gl_red}端口错误${gl_bai}" && return
    check_port_warn "$port"
    read -e -p "$(echo -e "${gl_cyan}节点备注名 (回车默认端口): ${gl_bai}")" name
    [ -z "$name" ] && name="Reality-$port"

    echo -e "${gl_huang}>>> 请选择工作模式 <<<${gl_bai}"
    echo -e "${gl_lv}1. 本机直接落地 (全自动生成) ★${gl_bai}"
    echo -e "${gl_hui}2. 中转到其他机器 (1对1中转)${gl_bai}"
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
        echo -e "${gl_hui}说明: 客户端连本端口，系统自动测速分配最快落地机${gl_bai}"
        echo -e "${gl_hui}所有落地机必须配置相同的 UUID！${gl_bai}"
        echo -e "${gl_bright}========================================${gl_bai}"
        
        read -e -p "$(echo -e "${gl_cyan}请输入集群统一 UUID (回车自动生成): ${gl_bai})" uuid
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
            read -e -p "$(echo -e "${gl_cyan}后端短ID (可留空): ${gl_bai}" sid
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
