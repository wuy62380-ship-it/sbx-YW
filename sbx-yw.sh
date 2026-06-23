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
                        '.inbounds += [{"type": "vless", "tag": $in_tag, "listen": "::", "listen_port": $p, "users": [{"name": "user", "uuid": $u, "flow": "xtls-rprx-vision"}], "tls": {"enabled": true, "server_name": $sni, "reality": ({"enabled": true, "handshake": {"server": $sni, "server_port": 443}, "private_key": $pk} + (if $sid != "" then {"short_id": [$sid]} else {} end))}}]})
                elif [ "$mode" == "cluster" ]; then
                    local out_tags=""
                    local idx=0
                    while IFS= read -r be; do
                        local b_ip b_bp b_pub b_sid cur_out sid_json
                        b_ip=$(echo "$be" | jq -r ".ip"); b_bp=$(echo "$be" | jq -r ".bp"); b_pub=$(echo "$be" | jq -r ".pub_key"); b_sid=$(echo "$be" -r ".sid // empty")
                        cur_out="out-cluster-${idx}"
                        sid_json="{}"; [ -n "$b_sid" ] && sid_json=",\"short_id\":\"$b_sid\""
                        out_tags+=",\"${cur_out}\""
                        json=$(echo "$json" | jq \
                            --argjson p "$port" --arg out "${cur_out}" --arg ip "$b_ip" --argjson bp "$b_bp" --arg pub "$b_pub" --arg sid_json "$sid_json" \
                            '.outbounds += [{"type": "vless", "tag": $out, "server": $b_ip, "server_port": $b_bp, "uuid": "00000000-0000-0000-0000-000000000000", "flow": "xtls-rprx-vision", "tls": {"enabled": true, "server_name": "www.microsoft.com", "utls": {"enabled": true, "fingerprint": "chrome"}, "reality": {"enabled": true, "public_key": $b_pub, "short_id": $sid_json}}]})
                        ((idx++))
                    done < <(jq -c '.[]' ".[$i].backends")
                    out_tags="${out_tags#*,}"
                    json=$(echo "$json" | jq \
                        --arg in_tag "$in_tag" --arg u "$(jq -r ".[$i].uuid" "$RULES_JSON")" \
                        --arg sni "$(jq -r ".[$i].sni" "$RULES_JSON")" --arg fp "$(jq -r ".[$i].fp" "$RULES_JSON")" \
                        --arg outs "[$out_tags]" \
                        '.inbounds += [{"type": "vless", "tag": $in_tag, "listen": "::", "listen_port": $p, "users": [{"name": "user", "uuid": $u, "flow": "xtls-rprx-vision"}], "tls": {"enabled": true, "server_name": $sni, "reality": {"enabled": true, "handshake": {"server": $sni, "server_port": 443}}}}]
                         | .outbounds += [{"type": "urltest", "tag": "urltest-${port}", "outbounds": $outs, "url": "https://www.gstatic.com/generate_204", "interval": "5m"}]
                         | .route.rules += [{"inbound":[$in_tag], "outbound": "urltest-${port}"}]')
                else
                    json=$(echo "$json" | jq --argjson p "$port" --arg in_tag "$in_tag" --arg out_tag "$out_tag" \
                        --arg ip "$(jq -r ".[$i].ip" "$RULES_JSON")" --argjson bp "$(jq -r ".[$i].bp" "$RULES_JSON")" \
                        --arg pub "$(jq -r ".[$i].pub_key" "$RULES_JSON")" --arg sid "$(jq -r ".[$i].sid" "$RULES_JSON")" \
                        --arg sni "$(jq -r ".[$i].sni" "$RULES_JSON")" --arg fp "$(jq -r ".[$i].fp" "$RULES_JSON")" \
                        '.inbounds += [{"type":"mixed","tag":$in_tag,"listen":"::","listen_port":$p}] | .outbounds += [{"type": "vless", "tag": $out_tag, "server": $ip, "server_port": $bp, "uuid": "00000000-0000-0000-0000-000000000000", "flow": "xtls-rprx-vision", "tls": {"enabled": true, "server_name": $sni, "utls": {"enabled": true, "fingerprint": $fp}, "reality": {"enabled": true, "public_key": $pub, "short_id": $sid}}}]
                    json=$(echo "$json" | jq --arg in "$in_tag" --arg out "$out_tag" '.route.rules += [{"inbound":[$in], "outbound":$out}])
                fi ;;
            hysteria2)
                if [ "$mode" == "standalone" ]; then
                    json=$(echo "$json" | jq --argjson p "$port" --arg pass "$(jq -r ".[$i].pass" "$RULES_JSON")" \
                        --arg sni "$(jq -r ".[$i].sni" "$RULES_JSON")" \
                        --argjson up "$(jq -r ".[$i].up // 0" "$RULES_JSON")" --argjson down "$(jq -r ".[$i].down // 0" "$RULES_JSON")" \
                        '.inbounds += [{"type": "hysteria2", "tag": ("in-" + ($p|tostring)), "listen": "::", "listen_port": $p, "users": [{"name": "user", "password": $pass}], "tls": {"enabled": true, "server_name": $sni, "certificate_path": "/etc/sing-box/hy2.crt", "key_path": "/etc/sing-box/hy2.key"} + (if $up > 0 then {"up_mbps": $up} else {} end) + (if $down > 0 then {"down_mbps": $down else {} end)}]}])
                else
                    json=$(echo "$json" | jq --argjson p "$port" --arg in_tag "$in_tag" --arg out_tag "$out_tag" \
                        --arg ip "$(jq -r ".[$i].ip" "$RULES_JSON")" --argjson bp "$(jq -r ".[$i].bp" "$RULES_JSON")" \
                        --arg pass "$(jq -r ".[$i].pass" "$RULES_JSON")" --arg sni "$(jq -r ".[$i].sni" "$RULES_JSON")" \
                        '.inbounds += [{"type":"mixed","tag":$in_tag,"listen":"::","listen_port":$p}] | .outbounds += [{"type": "hysteria2", "tag": $out_tag, "server": $ip, "server_port": $bp, "password": $pass, "tls": {"enabled":true,"server_name":$sni,"insecure":true}}]')
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
                        '.inbounds += [{"type":"mixed","tag":$in_tag,"listen":"::","listen_port":$p}] | .outbounds += [{"type": "vless", "tag": $out_tag, "server": $ip, "server_port": $bp, "uuid": "00000000-0000-0000-0000-000000000000", "transport": {"type":"ws","path":$path}}])
                    json=$(echo "$json" | jq --arg in "$in_tag" --arg out "$out_tag" '.route.rules += [{"inbound":[$in], "outbound":$out}])
                fi ;;
            direct)
                json=$(echo "$json" | jq --argjson p "$port" --arg in_tag "$in_tag" \
                    --arg ip "$(jq -r ".[$i].ip" "$RULES_JSON")" --argjson bp "$(jq -r ".[$i].bp" "$RULES_JSON")" \
                    '.inbounds += [{"type": "direct", "tag": $in_tag, "listen": "::", "listen_port": $p, "override_address": $ip, "override_port": $bp}])
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

        local n; n=$(jq 'length' "$RULES_JSON")
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
        echo -e "${gl_huang}2. 添加节点 (支持集群)${gl_bai}"
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
        echo -e "${gl_bright}10. 🔪 按端口精准删除${gl_bright}"
        echo -e "${gl_cyan}11. 🏷️ 修改本机备注名${gl_bright}"
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
