#!/bin/bash
#
# OpenClaw 快速修复脚本 v4.0
# 用于紧急恢复配置 - 支持 R4S 和 n5105
#
# 用法: ./openclaw-quickfix.sh [--n5105]
#

CORRECT_MODEL="openrouter/minimax/minimax-m2.7"
SSH_HOST=""
SSH_PORT="22"
SSH_USER="root"
SSH_PASS=""

# 解析参数
if [ "$1" = "--n5105" ]; then
    SSH_HOST="175.0.67.87"
    SSH_PORT="22222"
    SSH_PASS="x7z8y2k3k288"
    echo "模式: n5105 (175.0.67.87:22222)"
else
    echo "模式: 本机 R4S"
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
echo -e "${GREEN}=== OpenClaw 快速修复 v4.0 ===${NC}"

run_cmd() {
    if [ -n "$SSH_HOST" ]; then
        sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -p $SSH_PORT $SSH_USER@$SSH_HOST "$1" 2>&1
    else
        bash -c "$1"
    fi
}

# 1. 清理 session overrides
echo -e "${YELLOW}1/5${NC} 清理 session 模型覆盖..."
run_cmd "python3 << 'PYEOF' 2>/dev/null
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
            model = v.get('model', '')
            if 'minimax' in str(model).lower() or 'gpt-' in str(model).lower():
                v['model'] = '$CORRECT_MODEL'; fixed += 1
    if fixed: json.dump(d, open(f,'w'), indent=2)
    print(f'清理了 {fixed} 个覆盖')
except Exception as e: print(f'Error: {e}')
PYEOF"

# 2. 修复 auth-profiles.json
echo -e "${YELLOW}2/5${NC} 修复 auth-profiles.json..."
run_cmd "python3 << 'PYEOF' 2>/dev/null
import json
f = '/root/.openclaw/agents/main/agent/auth-profiles.json'
cfg = {
    'version': 1,
    'profiles': {
        'openrouter': {
            'type': 'api_key',
            'provider': 'openrouter',
            'key': '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'
        }
    },
    'lastGood': {'openrouter': 'openrouter'}
}
try:
    json.dump(cfg, open(f,'w'), indent=2)
    print('auth-profiles.json 已修复')
except Exception as e: print(f'Error: {e}')
PYEOF"

# 3. 修复 openclaw.json
echo -e "${YELLOW}3/5${NC} 修复 openclaw.json..."
run_cmd "python3 << 'PYEOF' 2>/dev/null
import json
f = '/root/.openclaw/openclaw.json'
d = json.load(open(f))

# 设置正确模型
d['agents']['defaults']['model'] = {'primary': '$CORRECT_MODEL'}

# 清理 minimax providers
if 'models' in d and 'providers' in d['models']:
    for p in ['minimax', 'minimax-portal']:
        if p in d['models']['providers']:
            del d['models']['providers'][p]
            print(f'移除: {p}')

# 移除 auth.profiles (由 auth-profiles.json 处理)
if 'auth' in d and 'profiles' in d.get('auth', {}):
    del d['auth']['profiles']
    print('清理 auth.profiles')

json.dump(d, open(f,'w'), indent=2)
print('openclaw.json 已修复')
PYEOF"

# 4. 清理 models.json (只保留 openrouter)
echo -e "${YELLOW}4/5${NC} 清理 models.json..."
run_cmd "python3 << 'PYEOF' 2>/dev/null
import json
f = '/root/.openclaw/agents/main/agent/models.json'
cfg = {
    'providers': {
        'openrouter': {
            'baseUrl': 'https://openrouter.ai/api/v1',
            'api': 'openai-completions',
            'authHeader': True,
            'models': [{
                'id': 'minimax/minimax-m2.7',
                'name': 'MiniMax M2.7 via OpenRouter',
                'reasoning': True,
                'input': ['text'],
                'contextWindow': 204800,
                'maxTokens': 131072
            }]
        }
    }
}
try:
    json.dump(cfg, open(f,'w'), indent=2)
    print('models.json 已修复 (仅 openrouter)')
except Exception as e: print(f'Error: {e}')
PYEOF"

# 5. 重启服务
echo -e "${YELLOW}5/5${NC} 重启 Gateway..."
run_cmd "pkill -9 -f openclaw 2>/dev/null; sleep 2
systemctl --user restart openclaw-gateway 2>/dev/null || systemctl restart openclaw 2>/dev/null || echo 'Restart command may need adjustment'"

echo ""
echo -e "${GREEN}=== 修复完成 ===${NC}"
echo "请测试 Telegram Bot"
