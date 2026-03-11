#!/bin/sh
# Cloudflare Worker + DNS 自动配置脚本（IPv4/IPv6 双栈优化版）

# ====================== 配置区 ======================
# 如果你的 Lucky Web 服务端口不是 16633，请修改这里
DEFAULT_PORT="16633" 
# ====================================================

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# 安装必要依赖
for pkg in curl jq; do
    if ! command -v $pkg >/dev/null 2>&1; then
        opkg update >/dev/null 2>&1
        opkg install $pkg --force-depends >/dev/null 2>&1
    fi
done

# 接收 Lucky 传入参数
NEW_IP=$1
NEW_PORT=$2
API_TOKEN=$3
DOMAIN=$4
RULE_NAME=${5:-my}
ACCOUNT_ID=${6:-""}

# 获取 Account ID 和 Zone ID
if [ -z "$ACCOUNT_ID" ]; then
    ACCOUNT_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts" -H "Authorization: Bearer ${API_TOKEN}" | jq -r '.result[0].id')
fi
ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${DOMAIN}" -H "Authorization: Bearer ${API_TOKEN}" | jq -r '.result[0].id')

# 管理 KV 空间并写入值
KV_NAMESPACE_NAME="${RULE_NAME}-config"
KV_NAMESPACE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/storage/kv/namespaces" -H "Authorization: Bearer ${API_TOKEN}" | jq -r ".result[] | select(.title == \"${KV_NAMESPACE_NAME}\") | .id")
if [ -z "$KV_NAMESPACE_ID" ] || [ "$KV_NAMESPACE_ID" = "null" ]; then
    KV_NAMESPACE_ID=$(curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/storage/kv/namespaces" -H "Authorization: Bearer ${API_TOKEN}" --data "{\"title\":\"${KV_NAMESPACE_NAME}\"}" | jq -r '.result.id')
fi

curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/storage/kv/namespaces/${KV_NAMESPACE_ID}/values/ip" -H "Authorization: Bearer ${API_TOKEN}" --data "$NEW_IP"
curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/storage/kv/namespaces/${KV_NAMESPACE_ID}/values/port" -H "Authorization: Bearer ${API_TOKEN}" --data "$NEW_PORT"
curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/storage/kv/namespaces/${KV_NAMESPACE_ID}/values/domain" -H "Authorization: Bearer ${API_TOKEN}" --data "$DOMAIN"

# 生成智能重定向 Worker 代码
WORKER_CODE=$(cat <<EOF
addEventListener('fetch', event => {
  event.respondWith(handleRequest(event.request));
});

async function handleRequest(request) {
  const url = new URL(request.url);
  const pathSegments = url.pathname.split('/').filter(Boolean);
  
  if (pathSegments.length > 0) {
    const subdomain = pathSegments[0];
    const targetDomain = await CONFIG.get('domain');
    const stunPort = await CONFIG.get('port');
    const clientIP = request.headers.get("cf-connecting-ip") || "";
    
    // 关键逻辑：如果是 IPv6 访客，使用固定端口；如果是 IPv4，使用 STUN 随机端口
    let finalPort = clientIP.includes(":") ? "${DEFAULT_PORT}" : stunPort;
    
    const rest = pathSegments.slice(1).join('/');
    const targetUrl = "https://" + subdomain + "." + targetDomain + ":" + finalPort + (rest ? "/" + rest : "") + url.search;
    return Response.redirect(targetUrl, 302);
  }
  return new Response("Usage: https://${RULE_NAME}.${DOMAIN}/[subdomain]", { status: 404 });
}
EOF
)

# 推送 Worker 脚本
echo "$WORKER_CODE" > /tmp/worker.js
METADATA="{\"body_part\":\"script\",\"bindings\":[{\"name\":\"CONFIG\",\"namespace_id\":\"$KV_NAMESPACE_ID\",\"type\":\"kv_namespace\"}]}"
curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/workers/scripts/${RULE_NAME}-redirect" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    -F "metadata=${METADATA};type=application/json" \
    -F "script=@/tmp/worker.js;type=application/javascript"

# 设置 Worker 路由
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/workers/routes" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    --data "{\"pattern\":\"${RULE_NAME}.${DOMAIN}/*\",\"script\":\"${RULE_NAME}-redirect\"}"

# 更新 DNS 记录
# 1. 引导域名 (Proxy 开启)
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    --data "{\"type\":\"A\",\"name\":\"${RULE_NAME}\",\"content\":\"8.8.8.8\",\"proxied\":true}"

# 2. 通配符记录 (Proxy 关闭)
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
    -H "Authorization: Bearer ${API_TOKEN}" \
    --data "{\"type\":\"A\",\"name\":\"*\",\"content\":\"$NEW_IP\",\"proxied\":false}"

log "✅ 全部配置已同步。IPv4 访客将重定向至端口 $NEW_PORT，IPv6 访客将重定向至端口 $DEFAULT_PORT"
