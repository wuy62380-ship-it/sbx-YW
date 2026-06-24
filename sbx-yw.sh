#!/usr/bin/env bash

# 清理可能存在的 Windows 换行符
if [ -f "$0" ]; then
    sed -i 's/\r$//' "$0" 2>/dev/null
fi

# 颜色变量
R="\033[0m"
G="\033[32m"
Y="\033[33m"
H="\033[90m"
RED="\033[31m"
C="\033[36m"
B="\033[97m"

# 权限检查
[ "$(id -u)" -ne 0 ] && echo -e "${RED}请使用 root 运行${R}" && exit 1

clear
echo -e "${G}========================================${R}"
echo -e "${G}     极致中转一键部署 (内核级 T0)      ${R}"
echo -e "${G}========================================${R}"
echo -e "${H}本脚本将执行：${R}"
echo -e "  1. 拉取并运行 kernel-smart.sh (魔改内核调优)"
echo -e "  2. 配置 iptables 内核态 DNAT 转发 (零拷贝)"
echo -e "  3. 持久化转发规则防丢失"
echo -e "${G}========================================${R}"
read -rs -n 1 -p "按任意键开始部署..."

# ============================================================================
# 第一步：部署 kernel-smart.sh
# ============================================================================
echo ""
echo -e "${C}[1/3] 正在拉取 kernel-smart.sh 魔改内核脚本...${R}"

URL="https://raw.githubusercontent.com/wuy62380-ship-it/yw/main/kernel-smart.sh"
FILE="/tmp/kernel-smart.sh"

if ! curl -fsSL --connect-timeout 10 "$URL" -o "$FILE"; then
    echo -e "${RED}下载 kernel-smart.sh 失败！可能是网络问题或 GitHub 被墙。${R}"
    
    # 使用变量分离，彻底避免括号嵌套导致的语法错误
    TIP=$(echo -e "${C}是否跳过内核调优，仅配置 iptables 转发？
    read -e -p "$TIP" SKIP
    
    if [ "$SKIP" != "y" ]; then
        echo -e "${H}已取消部署。${R}"
        exit 1
    fi
else
    chmod +x "$FILE"
    echo -e "${G}下载成功，正在执行内核调优...${R}"
    echo -e "${Y}>>> 请在弹出的菜单中完成你的魔改 BBRv3 设置 <<<${R}"
    echo -e "${H}设置完成后，脚本会自动返回此处继续配置转发。${R}"
    echo -e "${H}----------------------------------------${R}"
    
    bash "$FILE"
    rm -f "$FILE"
    echo -e "${G}内核调优步骤完成！${R}"
fi

# ============================================================================
# 第二步：配置 iptables
# ============================================================================
echo ""
echo -e "${C}[2/3] 配置 iptables 内核态高透转发...${R}"

# 开启转发
if ! grep -q "^net.ipv4.ip_forward.*=.*1" /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    sysctl -p > /dev/null 2>&1
fi

# 获取参数
while true; do
    TIP2=$(echo -e "${C}请输入落地机的真实 IP: ${R}")
    read -e -p "$TIP2" BACKEND_IP
    if [[ "$BACKEND_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        break
    fi
    echo -e "${RED}IP 格式错误，请重新输入！${R}"
done

while true; do
    TIP3=$(echo -e "${C}请输入落地机的监听端口: ${R}")
    read -e -p "$TIP3" BACKEND_PORT
    if [[ "$BACKEND_PORT" =~ ^[0-9]+$ ]]; then
        break
    fi
    echo -e "${RED}端口格式错误，请重新输入！${R}"
done

while true; do
    TIP4=$(echo -e "${C}请输入中转机对外暴露的端口: ${R}")
    read -e -p "$TIP4" FRONTEND_PORT
    if [[ "$FRONTEND_PORT" =~ ^[0-9]+$ ]]; then
        break
    fi
    echo -e "${RED}端口格式错误，请重新输入！${R}"
done

# 防重复
if iptables -t nat -C PREROUTING -p tcp --dport "$FRONTEND_PORT" -j DNAT --to-destination "$BACKEND_IP:$BACKEND_PORT" 2>/dev/null; then
    echo -e "${Y}检测到端口 $FRONTEND_PORT 的转发规则已存在！${R}"
    TIP5=$(echo -e "${C}是否覆盖/跳过？
    read -e -p "$TIP5" OW
    if [ "$OW" != "y" ]; then
        echo -e "${H}已跳过。${R}"
        exit 0
    fi
    iptables -t nat -D PREROUTING -p tcp --dport "$FRONTEND_PORT" -j DNAT --to-destination "$BACKEND_IP:$BACKEND_PORT" 2>/dev/null
    echo -e "${H}已清理旧规则。${R}"
fi

# 写入规则
iptables -t nat -A PREROUTING -p tcp --dport "$FRONTEND_PORT" -j DNAT --to-destination "$BACKEND_IP:$BACKEND_PORT"

if ! iptables -t nat -C POSTROUTING -d "$BACKEND_IP" -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -d "$BACKEND_IP" -j MASQUERADE
fi

echo -e "${G}iptables 转发规则添加成功！${R}"

# ============================================================================
# 第三步：持久化
# ============================================================================
echo ""
echo -e "${C}[3/3] 持久化转发规则 (防止重启丢失)...${R}"

OK=0
if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save > /dev/null 2>&1 && OK=1
elif [ -f /etc/redhat-release ] && command -v iptables-service >/dev/null 2>&1; then
    service iptables save > /dev/null 2>&1 && OK=1
else
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null && OK=1
fi

if [ "$OK" -eq 1 ]; then
    echo -e "${G}规则持久化成功！重启不会丢失。${R}"
else
    echo -e "${Y}自动持久化失败，请手动安装：${R}"
    echo -e "${H}Debian/Ubuntu: apt install iptables-persistent -y${R}"
    echo -e "${H}CentOS/RedHat: yum install iptables-services -y${R}"
fi

# ============================================================================
# 结束
# ============================================================================
MYIP=$(curl -s --connect-timeout 3 https://ifconfig.me 2>/dev/null || curl -s --connect-timeout 3 https://checkip.amazonaws.com 2>/dev/null)

echo ""
echo -e "${G}========================================${R}"
echo -e "${G}          极致中转配置完毕！          ${R}"
echo -e "${G}========================================${R}"
echo -e "中转机入口: ${C}${MYIP:-未知IP}:${FRONTEND_PORT}${R}"
echo -e "转发至后端: ${C}${BACKEND_IP}:${BACKEND_PORT}${R}"
echo -e "${G}========================================${R}"
echo -e "${B}客户端链接怎么填？${R}"
echo -e "复制【落地机】生成的链接，把 IP 改成 ${G}${MYIP:-中转机IP}${R}"
echo -e "端口改成 ${G}${FRONTEND_PORT}${R}，其他参数绝对不要动！"
echo -e "${G}----------------------------------------${R}"
echo -e "${B}查看当前所有转发规则？${R}"
echo -e "执行: ${H}iptables -t nat -L PREROUTING -n --line-numbers${R}"
echo -e "${G}----------------------------------------${R}"
echo -e "${B}如何删除这条转发规则？${R}"
echo -e "执行: ${H}iptables -t nat -D PREROUTING -p tcp --dport ${FRONTEND_PORT} -j DNAT --to-destination ${BACKEND_IP}:${BACKEND_PORT}${R}"
echo -e "${G}========================================${R}"
