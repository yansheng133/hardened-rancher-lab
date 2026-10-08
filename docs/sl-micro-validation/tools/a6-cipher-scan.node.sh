#!/bin/bash
# 在節點本機逐一測 TLS 1.2 加密套件是否被接受（openssl s_client，一次只給一個套件），並讀一個 Secret 在 etcd 的前綴。
# 用法：sudo bash a6-cipher-scan.node.sh <節點私有 IP>
IP=$1; T=/var/lib/rancher/rke2/server/tls
CIPHERS="ECDHE-ECDSA-AES128-GCM-SHA256 ECDHE-RSA-AES128-GCM-SHA256 ECDHE-ECDSA-AES256-GCM-SHA384 ECDHE-RSA-AES256-GCM-SHA384 ECDHE-ECDSA-CHACHA20-POLY1305 ECDHE-RSA-CHACHA20-POLY1305 ECDHE-ECDSA-AES128-SHA ECDHE-ECDSA-AES256-SHA ECDHE-RSA-AES128-SHA ECDHE-RSA-AES256-SHA AES128-GCM-SHA256 AES256-GCM-SHA384 AES128-SHA AES256-SHA"
probe() { local name=$1 hostport=$2 extra=$3; local ok=""; for c in $CIPHERS; do
  out=$(echo | timeout 5 openssl s_client -connect $hostport -tls1_2 -cipher "$c:@SECLEVEL=0" $extra 2>&1)
  echo "$out" | grep -q "Cipher is $c" && ok="$ok $c"; done; echo "$name 接受:${ok:- （無）}"; }
probe "kubelet:10250" $IP:10250 ""
probe "etcd-client:2379" 127.0.0.1:2379 "-cert $T/etcd/server-client.crt -key $T/etcd/server-client.key"
probe "etcd-peer:2380" $IP:2380 "-cert $T/etcd/peer-server-client.crt -key $T/etcd/peer-server-client.key"
probe "apiserver:6443" 127.0.0.1:6443 ""
probe "traefik:443" $IP:443 ""
CR="/var/lib/rancher/rke2/bin/crictl --runtime-endpoint unix:///run/k3s/containerd/containerd.sock"; id=$($CR ps --name etcd -q 2>/dev/null | head -1); E="etcdctl --cacert $T/etcd/server-ca.crt --cert $T/etcd/server-client.crt --key $T/etcd/server-client.key"
k=$($CR exec $id $E get /registry/secrets/kube-system/ --prefix --keys-only 2>/dev/null | grep . | head -1)
echo "Secret $k 前綴: $($CR exec $id $E get "$k" --print-value-only 2>/dev/null | head -c 26)"
n=0; m=0; for key in $($CR exec $id $E get /registry/secrets/ --prefix --keys-only 2>/dev/null | grep .); do n=$((n+1)); p=$($CR exec $id $E get "$key" --print-value-only 2>/dev/null | head -c 18); [ "$p" = "k8s:enc:secretbox:" ] && m=$((m+1)); done; echo "Secret 總數 $n，其中 secretbox 前綴 $m"
echo "secrets-encrypt status:"; /opt/rke2/bin/rke2 secrets-encrypt status 2>&1 | head -6
