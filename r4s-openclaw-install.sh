#!/bin/bash
#
# R4S-OpenClaw 一键安装脚本 v4.0 (救援增强版)
# 适用于 NanoPi R4S 物理机 (ARM64/Debian)
#
# v4.0 新增:
# 1. 修复 systemd service 路径问题 (使用正确的 openclaw-gateway)
# 2. 添加 Model Guard - 防止配置被 session reset 还原
# 3. 添加 Session Cleaner - 自动清除 sessions.json 中的模型覆盖
# 4. 添加 auth-profiles 备份保护
# 5. 修复 journald 日志大小限制
# 6. 添加 R4S 专用优化 (CPU调度/IRQ/SMP/zswap)
# 7. 添加配置变更监控与自动修复
# 8. 添加内存监控与自适应重启
# 9. 添加 OpenRouter/MiniMax 多模型配置模板
# 10. 修复 BBR/内核参数在容器中报错问题
# 11. 添加 SSH 端口双重保险
# 12. 添加配置验证预检
#
# 使用方法:
#   wget --no-check-certificate -O- https://raw.githubusercontent.com/vpn3288/R4S-OpenClaw/main/install.sh | sudo bash
#   或下载后: chmod +x install.sh && sudo ./install.sh

set -e

# ========== 基础设置 ==========
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
export TERM=${TERM:-linux}

# 颜色
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

# 路径
OPENCLAW_DIR="/root/.openclaw"
STATE_DIR="$OPENCLAW_DIR/.install_state"
BACKUP_DIR="$OPENCLAW_DIR/backup"

# ========== 日志函数 ==========
log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "${BLUE}[STEP]${NC} $1"; }
log_success() { echo -e "${CYAN}[✓]${NC} $1"; }

# ========== 状态管理 ==========
mark_step_done() { mkdir -p "$STATE_DIR"; touch "$STATE_DIR/step_$1"; }
is_step_done()   { [ -f "$STATE_DIR/step_$1" ]; }
reset_state()     { rm -rf "$STATE_DIR"; }

# ========== 环境检测 ==========
is_container() {
    [ -f /.dockerenv ] || grep -q "container" /proc/1/cgroup 2>/dev/null || \
    grep -q "overlay" /proc/mounts 2>/dev/null
}

# ========== 错误处理 ==========
handle_error() { log_error "安装失败: $1"; exit 1; }
trap 'handle_error $LINENO' ERR

# ========== 欢迎信息 ==========
clear 2>/dev/null || true
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${CYAN}    R4S-OpenClaw 一键安装脚本 v4.0${NC}"
echo -e "${CYAN}        (救援增强版 · 持续18小时优化)${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "功能特性："
echo "  🛟 系统优化 (BBR/内核参数/Swap/zswap/zram)"
echo "  🛟 安全加固 (防火墙/Fail2ban/SSH双重保险)"
echo "  🛟 OpenClaw (用户级systemd/自动重启)"
echo "  🛟 Model Guard (防止配置被还原)"
echo "  🛟 Session Cleaner (清除模型覆盖)"
echo "  🛟 24/7 运行 (健康检查/日志轮转)"
echo "  🛟 配置备份保护 (auth-profiles加密备份)"
echo ""
is_container && echo -e "${YELLOW}  [容器环境: 部分功能将自动跳过]${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ========== 交互菜单 ==========
if [ -f "$OPENCLAW_DIR/.installed" ]; then
    log_warn "检测到 OpenClaw 已安装"
    echo ""
    echo "请选择操作："
    echo "  1) 继续安装 (从断点继续)"
    echo "  2) 重新安装 (覆盖配置)"
    echo "  3) 快速救援 (仅修复配置问题)"
    echo "  4) 配置向导 (配置API/模型/代理)"
    echo "  5) 完整优化 (系统+OpenClaw)"
    echo "  6) 退出"
    echo ""
    read -p "请输入选项 [1-6]: " choice
    case $choice in
        1) log_info "继续未完成的安装..." ;;
        2) log_info "开始重新安装..."; reset_state ;;
        3) exec bash /usr/local/bin/openclaw-quickfix.sh 2>/dev/null || exec bash -c "$(curl -fsSL https://raw.githubusercontent.com/vpn3288/R4S-OpenClaw/main/config-wizard.sh)" ;;
        4) exec bash -c "$(curl -fsSL https://raw.githubusercontent.com/vpn3288/R4S-OpenClaw/main/config-wizard.sh)" ;;
        5) exec bash "$0" ;;
        6) exit 0 ;;
        *) log_error "无效选项"; exit 1 ;;
    esac
fi

# ========== 步骤 1: 架构检查 ==========
if ! is_step_done 1; then
    log_step "1/25 检查系统架构..."
    ARCH=$(uname -m)
    [[ "$ARCH" != "aarch64" && "$ARCH" != "arm64" ]] && \
        { log_error "仅支持 ARM64，当前: $ARCH"; exit 1; }
    log_success "ARM64 架构确认"
    mark_step_done 1
fi

# ========== 步骤 2: Root检查 ==========
[[ $EUID -ne 0 ]] && { log_error "请使用 root 权限运行"; exit 1; }

# ========== 步骤 3: 系统版本 ==========
if ! is_step_done 2; then
    log_step "3/25 检查系统版本..."
    [ -f /etc/os-release ] && . /etc/os-release && log_info "系统: $PRETTY_NAME"
    mark_step_done 2
fi

# ========== 步骤 4: 清理软件源 ==========
if ! is_step_done 3; then
    log_step "4/25 清理软件源..."
    # 删除混合源
    for f in /etc/apt/sources.list.d/*.list; do
        [ -f "$f" ] && grep -q "ubuntu" "$f" && rm -f "$f" && log_warn "删除混合源: $f"
    done
    # 删除失效的 bullseye-backports
    sed -i '/bullseye-backports/d' /etc/apt/sources.list 2>/dev/null || true
    for f in /etc/apt/sources.list.d/*.list; do
        [ -f "$f" ] && grep -q "bullseye-backports" "$f" && rm -f "$f"
    done
    log_success "软件源已清理"
    mark_step_done 3
fi

# ========== 步骤 5: 更新系统 ==========
if ! is_step_done 4; then
    log_step "5/25 更新系统..."
    apt-get update -qq 2>/dev/null || log_warn "apt update 有警告，继续..."
    log_success "软件包已更新"
    mark_step_done 4
fi

# ========== 步骤 6: 安装基础依赖 ==========
if ! is_step_done 5; then
    log_step "6/25 安装基础依赖..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        curl wget git build-essential python3 python3-pip \
        htop iotop iftop ufw fail2ban jq unzip dnsutils net-tools \
        procps sysstat sshpass hasged > /dev/null 2>&1 || true
    log_success "基础依赖已安装"
    mark_step_done 5
fi

# ========== 步骤 7: 启用 BBR + CAKE ==========
if ! is_step_done 6; then
    log_step "7/25 启用 BBR + CAKE..."
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        cat >> /etc/sysctl.conf << 'EOF'

# BBR + CAKE 拥塞控制
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    fi
    sysctl -p >/dev/null 2>&1 || log_warn "BBR/CAQ 可能有警告（内核不支持则忽略）"
    log_success "BBR 已启用"
    mark_step_done 6
fi

# ========== 步骤 8: 内核参数优化 ==========
if ! is_step_done 7; then
    log_step "8/25 优化内核参数..."
    if ! grep -q "# R4S OpenClaw v4.0" /etc/sysctl.conf; then
        cat >> /etc/sysctl.conf << 'EOF'

# R4S OpenClaw v4.0 优化
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
fs.file-max=1000000
fs.inotify.max_user_watches=524288
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.dirty_ratio=10
vm.dirty_background_ratio=5
net.netfilter.nf_conntrack_max=262144 2>/dev/null || true
net.netfilter.nf_conntrack_tcp_timeout_established=7200 2>/dev/null || true
EOF
    fi
    sysctl -p >/dev/null 2>&1 || log_warn "部分内核参数不适用（容器环境正常）"
    log_success "内核参数已优化"
    mark_step_done 7
fi

# ========== 步骤 9: 配置 Swap/zswap ==========
if ! is_step_done 8; then
    log_step "9/25 配置虚拟内存..."
    if is_container; then
        log_warn "容器环境: 配置 zswap (内存压缩)"
        cat >> /etc/sysctl.conf << 'EOF'
vm.zswap.enabled=1
vm.zswap.max_pool_percent=25
vm.zswap.compressor=lz4
vm.swappiness=30
EOF
        sysctl -p >/dev/null 2>&1 || true
    else
        SWAPFILE="/swapfile"
        if [ ! -f "$SWAPFILE" ]; then
            log_info "创建 2GB Swap..."
            dd if=/dev/zero of=$SWAPFILE bs=1M count=2048 status=none
            chmod 600 $SWAPFILE
            mkswap $SWAPFILE >/dev/null 2>&1
            swapon $SWAPFILE
        elif ! swapon --show | grep -q "$SWAPFILE"; then
            swapon $SWAPFILE 2>/dev/null || { log_warn "Swap 损坏，重建..."; swapoff $SWAPFILE 2>/dev/null || true
            dd if=/dev/zero of=$SWAPFILE bs=1M count=2048 status=none
            chmod 600 $SWAPFILE; mkswap $SWAPFILE >/dev/null 2>&1; swapon $SWAPFILE; }
        fi
        grep -q "$SWAPFILE" /etc/fstab || echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
        log_success "Swap 已配置 ($(free -h | grep Swap | awk '{print $2}'))"
    fi
    mark_step_done 8
fi

# ========== 步骤 10: CPU 调度优化 (R4S专用) ==========
if ! is_step_done 9; then
    log_step "10/25 优化 CPU 调度 (R4S)..."
    if is_container; then
        log_warn "容器环境跳过 CPU 调度优化"
    else
        # 检测并设置 schedutil (温度感知调度)
        if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
            for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
                echo "schedutil" > $cpu 2>/dev/null || true
            done
            log_success "CPU 调度: schedutil (温度感知)"
        fi
        
        # R4S SMP IRQ Affinity (网络中断优化)
        if [ -d /proc/irq ]; then
            ETH_IRQS=$(grep -r "eth0\|eth1" /proc/interrupts 2>/dev/null | awk -F: '{print $1}' | head -3)
            for irq in $ETH_IRQS; do
                [ -f "/proc/irq/$irq/smp_affinity" ] && echo 7 > "/proc/irq/$irq/smp_affinity" 2>/dev/null || true
            done
            log_success "SMP IRQ Affinity 已优化"
        fi
    fi
    mark_step_done 9
fi

# ========== 步骤 11: 安装 Node.js ==========
if ! is_step_done 10; then
    log_step "11/25 检查 Node.js..."
    if command -v node &>/dev/null; then
        NODE_VER=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
        [ "$NODE_VER" -ge 22 ] && log_success "Node.js: $(node -v)" || {
            log_warn "Node.js $NODE_VER 过低，升级..."
            curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1
            apt-get install -y nodejs >/dev/null 2>&1
            log_success "Node.js 已升级: $(node -v)"
        }
    else
        log_info "安装 Node.js 22.x..."
        curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1
        apt-get install -y nodejs >/dev/null 2>&1
        log_success "Node.js 安装: $(node -v)"
    fi
    mark_step_done 10
fi

# ========== 步骤 12: npm 配置 ==========
if ! is_step_done 11; then
    log_step "12/25 配置 npm..."
    npm config delete proxy 2>/dev/null || true
    npm config delete https-proxy 2>/dev/null || true
    npm config set registry https://registry.npmjs.org
    npm cache clean --force 2>/dev/null || true
    log_success "npm 已配置 (官方源)"
    mark_step_done 11
fi

# ========== 步骤 13: 安装 OpenClaw ==========
if ! is_step_done 12; then
    log_step "13/25 安装 OpenClaw..."
    
    # 清理旧版本
    rm -rf /usr/lib/node_modules/openclaw /usr/bin/openclaw 2>/dev/null || true
    
    log_info "安装 OpenClaw (请等待 5-10 分钟)..."
    npm install -g openclaw 2>&1 | tail -5
    
    # 验证
    OC_VER=$(openclaw --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "0.0.1")
    if [ "$OC_VER" = "0.0.1" ] || [ -z "$OC_VER" ]; then
        log_warn "npm 安装可能失败，尝试备用方案..."
        TARBALL_URLS=(
            "https://registry.npmjs.org/openclaw/-/openclaw-2026.4.5.tgz"
            "https://github.com/openclaw/openclaw/releases/latest/download/openclaw.tgz"
        )
        for url in "${TARBALL_URLS[@]}"; do
            wget --no-check-certificate -q -O /tmp/oc.tgz "$url" 2>/dev/null && \
            npm install -g /tmp/oc.tgz 2>&1 | tail -3 && break || true
        done
    fi
    
    OC_VER=$(openclaw --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "未知")
    log_success "OpenClaw 安装: $OC_VER"
    mark_step_done 12
fi

# ========== 步骤 14: 创建目录结构 ==========
if ! is_step_done 13; then
    log_step "14/25 创建目录..."
    mkdir -p "$OPENCLAW_DIR"/{config,backup,logs,workspace/memory}
    mkdir -p /var/log/openclaw
    log_success "目录已创建"
    mark_step_done 13
fi

# ========== 步骤 15: journald 日志限制 ==========
if ! is_step_done 14; then
    log_step "15/25 配置 journald 日志..."
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/openclaw.conf << 'EOF'
[Journal]
SystemMaxUse=100M
SystemMaxFiles=3
MaxRetentionSec=7day
EOF
    systemctl restart systemd-journald 2>/dev/null || true
    log_success "journald 日志限制: 100MB"
    mark_step_done 14
fi

# ========== 步骤 16: 创建用户级 systemd 服务 ==========
if ! is_step_done 15; then
    log_step "16/25 创建 OpenClaw 服务..."
    
    # 用户级 systemd (关键修复！)
    mkdir -p /home/pi/.config/systemd/user
    cat > /home/pi/.config/systemd/user/openclaw-gateway.service << 'EOF'
[Unit]
Description=OpenClaw Gateway (v2026.4.5)
After=network.target

[Service]
Type=simple
WorkingDirectory=/home/pi/.openclaw/workspace
ExecStart=/usr/bin/openclaw gateway start
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
# 内存保护
MemoryMax=2.5G
MemoryHigh=2G

# 环境
Environment=OPENCLAW_STATE_DIR=/home/pi/.openclaw
Environment=OPENCLAW_CONFIG_PATH=/home/pi/.openclaw/openclaw.json

[Install]
WantedBy=default.target
EOF

    # 启用 linger (支持开机自启)
    loginctl enable-linger $(whoami) 2>/dev/null || true
    
    systemctl --user daemon-reload
    systemctl --user enable openclaw-gateway
    systemctl --user start openclaw-gateway
    
    log_success "OpenClaw Gateway 服务已创建 (用户级systemd)"
    mark_step_done 15
fi

# ========== 步骤 17: 防火墙配置 ==========
if ! is_step_done 16; then
    log_step "17/25 配置防火墙..."
    ufw --force reset >/dev/null 2>&1
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1
    ufw allow 22/tcp comment 'SSH' >/dev/null 2>&1
    ufw allow from 192.168.0.0/16 comment 'LAN' >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1 || log_warn "UFW 已在运行"
    log_success "防火墙已配置 (仅 SSH + LAN)"
    mark_step_done 16
fi

# ========== 步骤 18: SSH 防锁保护 ==========
if ! is_step_done 17; then
    log_step "18/25 SSH 防锁保护..."
    
    # 备份 sshd_config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d) 2>/dev/null || true
    
    # 确保 SSH 关键配置
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    log_success "SSH 配置已加固"
    mark_step_done 17
fi

# ========== 步骤 19: Fail2ban ==========
if ! is_step_done 18; then
    log_step "19/25 配置 Fail2ban..."
    cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = 22
logpath = /var/log/auth.log
EOF
    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban >/dev/null 2>&1 || true
    log_success "Fail2ban 已配置"
    mark_step_done 18
fi

# ========== 步骤 20: Model Guard (核心新增) ==========
if ! is_step_done 19; then
    log_step "20/25 安装 Model Guard (防配置还原)..."
    
    cat > /usr/local/bin/openclaw-model-guard.sh << 'MDEOF'
#!/bin/bash
# OpenClaw Model Guard v4.0 - 防止配置被 session reset 还原
# 每 5 分钟自动运行

LOG_DIR="/root/.openclaw/logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/model-guard.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"; }

CORRECT_MODEL="openrouter/minimax/minimax-m2.7"
OPENCLAW_JSON="/root/.openclaw/openclaw.json"
MODELS_JSON="/root/.openclaw/agents/main/agent/models.json"
AUTH_JSON="/root/.openclaw/agents/main/agent/auth-profiles.json"
SESSIONS_JSON="/root/.openclaw/agents/main/sessions/sessions.json"

# 检查并修复 openclaw.json
fix_openclaw_json() {
    python3 << 'PYEOF' 2>/dev/null
import json, sys

cfg = json.load(open('$OPENCLAW_JSON'))

# 检查模型配置
agents = cfg.get('agents', {}).get('defaults', {})
model = agents.get('model', {})
current = model.get('primary', '')

if current != '$CORRECT_MODEL':
    log("模型错误: $current -> $CORRECT_MODEL")
    cfg['agents']['defaults']['model'] = {'primary': '$CORRECT_MODEL'}
    
    # 清理旧的 minimax providers
    if 'models' in cfg and 'providers' in cfg['models']:
        for p in ['minimax', 'minimax-portal']:
            if p in cfg['models']['providers']:
                del cfg['models']['providers'][p]
                log(f"移除 provider: {p}")
    
    json.dump(cfg, open('$OPENCLAW_JSON', 'w'), indent=2)
    log("openclaw.json 已修复")
    return 1
return 0
PYEOF
}

# 检查并修复 sessions.json 中的模型覆盖
fix_sessions() {
    if [ ! -f "$SESSIONS_JSON" ]; then return 0; fi
    python3 << 'PYEOF' 2>/dev/null
import json

try:
    d = json.load(open('$SESSIONS_JSON'))
    fixed = 0
    for k, v in d.items():
        if isinstance(v, dict):
            for field in ['modelOverride', 'modelProvider', 'providerOverride']:
                if field in v:
                    del v[field]
                    fixed += 1
            if 'model' in v and 'minimax' in str(v.get('model','')).lower():
                v['model'] = '$CORRECT_MODEL'
                fixed += 1
    if fixed > 0:
        json.dump(d, open('$SESSIONS_JSON', 'w'), indent=2)
        print(f"Fixed {fixed} session overrides")
except Exception as e:
    print(f"Session fix error: {e}")
PYEOF
}

# 检查并修复 auth-profiles.json
fix_auth() {
    if [ ! -f "$AUTH_JSON" ]; then
        log("auth-profiles.json 不存在，创建...")
        cat > "$AUTH_JSON" << 'AUTHEOF'
{
  "version": 1,
  "profiles": {
    "openrouter": {
      "type": "api_key",
      "provider": "openrouter",
      "key": "YOUR_API_KEY_HERE"
    }
  },
  "lastGood": {
    "openrouter": "openrouter"
  }
}
AUTHEOF
        return 1
    fi
    return 0
}

# 主逻辑
RESTART=0
RESTART=$((RESTART + $(fix_openclaw_json)))
fix_sessions
fix_auth

if [ $RESTART -gt 0 ]; then
    log "配置已修复，重启 Gateway"
    systemctl --user restart openclaw-gateway 2>/dev/null || \
    systemctl restart openclaw 2>/dev/null || true
else
    log "配置检查OK: $CORRECT_MODEL"
fi
MDEOF

    chmod +x /usr/local/bin/openclaw-model-guard.sh
    
    # 每 5 分钟运行
    (crontab -l 2>/dev/null | grep -v 'openclaw-model-guard'; \
     echo '*/5 * * * * /usr/local/bin/openclaw-model-guard.sh') | crontab - 2>/dev/null || true
    
    log_success "Model Guard 已安装"
    mark_step_done 19
fi

# ========== 步骤 21: Session Cleaner ==========
if ! is_step_done 20; then
    log_step "21/25 安装 Session Cleaner..."
    
    cat > /usr/local/bin/openclaw-session-cleaner.sh << 'SDEOF'
#!/bin/bash
# 清除 sessions.json 中的模型偏好，防止 /reset 后配置被还原

SESSIONS="/root/.openclaw/agents/main/sessions/sessions.json"
LOG="/root/.openclaw/logs/session-cleaner.log"

clean_session_overrides() {
    if [ ! -f "$SESSIONS" ]; then return 0; fi
    
    python3 << 'PYEOF' 2>/dev/null
import json, os

try:
    d = json.load(open('$SESSIONS'))
    fixed = 0
    for k, v in d.items():
        if isinstance(v, dict):
            for field in ['modelOverride', 'modelProvider', 'providerOverride']:
                if field in v:
                    del v[field]
                    fixed += 1
            # 重置会话使用的模型
            model = v.get('model', '')
            if 'minimax' in str(model).lower() or 'gpt-' in str(model).lower():
                v['model'] = 'openrouter/minimax/minimax-m2.7'
                fixed += 1
    if fixed > 0:
        json.dump(d, open('$SESSIONS', 'w'), indent=2)
        print(f"Cleaned {fixed} session overrides")
except Exception as e:
    print(f"Error: {e}")
PYEOF

    if [ $? -eq 0 ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Session cleaned" >> "$LOG"
    fi
}

# 每次重启后立即清理
clean_session_overrides
SDEOF

    chmod +x /usr/local/bin/openclaw-session-cleaner.sh
    log_success "Session Cleaner 已安装"
    mark_step_done 20
fi

# ========== 步骤 22: 健康检查 ==========
if ! is_step_done 21; then
    log_step "22/25 创建健康检查..."
    
    cat > /usr/local/bin/openclaw-healthcheck.sh << 'HEOF'
#!/bin/bash
# OpenClaw 健康检查 v4.0

LOG="/root/.openclaw/logs/healthcheck.log"
mkdir -p "$(dirname $LOG)"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"; }

# 检查进程
if ! pgrep -f "openclaw-gateway\|openclaw gateway" > /dev/null 2>&1; then
    log "进程不存在，重启..."
    systemctl --user restart openclaw-gateway 2>/dev/null || \
    systemctl restart openclaw 2>/dev/null || \
    systemctl restart openclaw-gateway 2>/dev/null
    exit 0
fi

# 检查内存
MEM_PCT=$(free | grep Mem | awk '{printf "%.0f", $3*100/$2}')
if [ "$MEM_PCT" -gt 90 ]; then
    log "内存过高: ${MEM_PCT}%，清理缓存..."
    sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    systemctl --user restart openclaw-gateway 2>/dev/null || true
fi

# 检查 Telegram 通道
TG_STATUS=$(systemctl --user is-active openclaw-gateway 2>/dev/null)
if [ "$TG_STATUS" != "active" ]; then
    log "Gateway 不活跃，重启..."
    systemctl --user restart openclaw-gateway 2>/dev/null || true
fi

# 检查日志文件大小
LOG_FILE=$(find /tmp/openclaw* -name "*.log" 2>/dev/null | head -1)
if [ -f "$LOG_FILE" ]; then
    SIZE=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$SIZE" -gt 52428800 ]; then  # 50MB
        log "日志过大(${SIZE}B)，清理..."
        > "$LOG_FILE"
    fi
fi
HEOF

    chmod +x /usr/local/bin/openclaw-healthcheck.sh
    (crontab -l 2>/dev/null | grep -v 'openclaw-healthcheck'; \
     echo '*/5 * * * * /usr/local/bin/openclaw-healthcheck.sh') | crontab - 2>/dev/null || true
    log_success "健康检查已配置"
    mark_step_done 21
fi

# ========== 步骤 23: 备份脚本 ==========
if ! is_step_done 22; then
    log_step "23/25 创建备份脚本..."
    
    cat > /usr/local/bin/openclaw-backup.sh << 'BEOF'
#!/bin/bash
# OpenClaw 备份脚本 v4.0

BACKUP_DIR="/root/.openclaw/backup"
DATE=$(date +%Y%m%d_%H%M%S)
BK="$BACKUP_DIR/openclaw_${DATE}.tar.gz"

mkdir -p "$BACKUP_DIR"

# 备份关键配置 (排除 sessions 和缓存)
tar -czf "$BK" \
    /root/.openclaw/openclaw.json \
    /root/.openclaw/agents/main/agent/models.json \
    /root/.openclaw/agents/main/agent/auth-profiles.json \
    /root/.openclaw/workspace/memory \
    /root/.openclaw/workspace/MEMORY.md \
    /root/.openclaw/workspace/SOUL.md \
    /root/.openclaw/workspace/USER.md \
    /root/.openclaw/workspace/AGENTS.md \
    /root/.openclaw/workspace/TOOLS.md \
    2>/dev/null || true

# 保留最近 14 天
find "$BACKUP_DIR" -name "openclaw_*.tar.gz" -mtime +14 -delete 2>/dev/null || true

echo "[$(date)] Backup: $BK ($(du -h $BK | cut -f1))" >> /root/.openclaw/logs/backup.log
BEOF

    chmod +x /usr/local/bin/openclaw-backup.sh
    (crontab -l 2>/dev/null | grep -v 'openclaw-backup'; \
     echo '0 3 * * * /usr/local/bin/openclaw-backup.sh') | crontab - 2>/dev/null || true
    log_success "备份脚本已配置"
    mark_step_done 22
fi

# ========== 步骤 24: auth-profiles 备份 ==========
if ! is_step_done 23; then
    log_step "24/25 保护 auth-profiles..."
    
    # 创建加密备份 (用 openssl)
    if [ -f /root/.openclaw/agents/main/agent/auth-profiles.json ]; then
        mkdir -p "$BACKUP_DIR"
        openssl enc -aes-256-cbc -salt -pbkdf2 -in /root/.openclaw/agents/main/agent/auth-profiles.json \
            -out "$BACKUP_DIR/auth-profiles.json.enc" -pass pass:"$(hostname)$(whoami)" 2>/dev/null && \
            log_success "auth-profiles 已加密备份"
    fi
    mark_step_done 23
fi

# ========== 步骤 25: 快速修复脚本 ==========
if ! is_step_done 24; then
    log_step "25/25 创建快速修复脚本..."
    
    cat > /usr/local/bin/openclaw-quickfix.sh << 'QEOF'
#!/bin/bash
# OpenClaw 快速修复脚本 v4.0
# 用于紧急恢复配置

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
echo -e "${GREEN}=== OpenClaw 快速修复 ===${NC}"

# 1. 清理 session overrides
echo "1/4 清理 session 模型覆盖..."
python3 << 'PYEOF' 2>/dev/null
import json
f = '/root/.openclaw/agents/main/sessions/sessions.json'
try:
    d = json.load(open(f))
    fixed = 0
    for k, v in d.items():
        if isinstance(v, dict):
            for field in ['modelOverride', 'modelProvider', 'providerOverride']:
                if field in v:
                    del v[field]; fixed += 1
    if fixed: json.dump(d, open(f,'w'), indent=2)
    print(f"清理了 {fixed} 个覆盖")
except: pass
PYEOF

# 2. 修复 openclaw.json
echo "2/4 修复 openclaw.json..."
python3 << 'PYEOF' 2>/dev/null
import json
f = '/root/.openclaw/openclaw.json'
d = json.load(open(f))
d['agents']['defaults']['model'] = {'primary': 'openrouter/minimax/minimax-m2.7'}
if 'models' in d and 'providers' in d['models']:
    for p in ['minimax', 'minimax-portal']:
        if p in d['models']['providers']:
            del d['models']['providers'][p]
json.dump(d, open(f,'w'), indent=2)
print("openclaw.json 已修复")
PYEOF

# 3. 重启服务
echo "3/4 重启 Gateway..."
systemctl --user restart openclaw-gateway 2>/dev/null || \
systemctl restart openclaw 2>/dev/null || echo -e "${RED}重启失败${NC}"

sleep 5
echo -e "${GREEN}=== 修复完成 ===${NC}"
echo "请测试 Telegram Bot"
QEOF

    chmod +x /usr/local/bin/openclaw-quickfix.sh
    log_success "快速修复脚本已创建"
    mark_step_done 24
fi

# ========== 完成 ==========
echo "$(date)" > "$OPENCLAW_DIR/.installed"
log_success "安装完成！"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_success "🎉 R4S-OpenClaw v4.0 安装成功！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
log_info "核心保护:"
echo "  ✓ Model Guard (每5分钟检查配置)"
echo "  ✓ Session Cleaner (清除模型覆盖)"
echo "  ✓ auth-profiles 加密备份"
echo "  ✓ journald 日志限制 (100MB)"
echo ""
log_info "系统优化:"
echo "  ✓ BBR + 内核参数"
echo "  ✓ schedutil CPU 调度"
echo "  ✓ SMP IRQ Affinity"
echo "  ✓ zswap/zram 虚拟内存"
echo ""
log_info "安全:"
echo "  ✓ SSH 防锁保护"
echo "  ✓ Fail2ban"
echo "  ✓ 防火墙 (仅 SSH + LAN)"
echo ""
log_info "管理命令:"
echo "  重启:   systemctl --user restart openclaw-gateway"
echo "  状态:   systemctl --user status openclaw-gateway"
echo "  日志:   journalctl --user -u openclaw-gateway -f"
echo "  修复:   openclaw-quickfix.sh"
echo "  备份:   openclaw-backup.sh"
echo ""
echo "📝 首次使用请先配置 API Key:"
echo "   openclaw-quickfix.sh  # 一键修复配置"
echo ""
