#!/bin/sh

set -uex

# comma separated list of master host ip's
MASTER_HOSTS=""

# create on master host using "kubeadm token create --print-join-command --ttl 0"
TOKEN=""
TOKEN_CA_CERT_HASH=""

# kubernetes version, should match master version
KUBE_VERSION="1.10.3"
NODE_NAME=$(hostname -s)
CLUSTER_DNS="10.96.0.10"
CNI_VERSION="0.6.0"


# Configure Docker
if [ ! -e /etc/docker/daemon.json ]; then
    mkdir -p /etc/docker
    cat <<EOF >/etc/docker/daemon.json
{
    "storage-driver": "overlay2",
    "live-restore": true,
    "iptables": false,
    "ip-masq": false,
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "20m",
        "max-file": "3"
    }
}
EOF
fi

systemctl enable docker
systemctl start docker

# CNI
if [ ! -e /opt/cni/bin/loopback ]; then
    mkdir -p /opt/cni/bin
    curl -L "https://dl.bintray.com/kontena/pharos-bin/cni-plugins/cni-plugins-amd64-v${CNI_VERSION}.tgz" | tar -C /opt/cni/bin -xz
fi

# Install kubelet/kubeadm
if [ ! -e /opt/bin/kubelet ]; then
    mkdir -p /opt/bin
    cd /opt/bin
    curl -L --remote-name-all "https://dl.bintray.com/kontena/pharos-bin/kube/${KUBE_VERSION}/{kubeadm,kubelet}-amd64.gz"
    gunzip kube*.gz
    mv kubeadm-amd64 kubeadm
    mv kubelet-amd64 kubelet
    chmod +x *
fi

# Kubelet systemd unit
if [ ! -e /etc/systemd/system/kubelet.service ]; then
    cat <<EOF >/etc/systemd/system/kubelet.service
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=http://kubernetes.io/docs/

[Service]
ExecStart=/opt/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
fi

# Initialize Kontena Pharos kubelet proxy
if [ ! -e /etc/kubernetes/manifests/pharos-proxy.yaml ]; then
    mkdir -p /etc/kubernetes/manifests
    cat <<EOF >/etc/kubernetes/manifests/pharos-proxy.yaml
apiVersion: v1
kind: Pod
metadata:
  annotations:
    scheduler.alpha.kubernetes.io/critical-pod: ""
  labels:
    component: pharos-proxy
    tier: worker
  name: pharos-proxy
  namespace: kube-system
spec:
  containers:
    - image: quay.io/kontena/pharos-kubelet-proxy-amd64:0.3.6
      name: proxy
      env:
      - name: KUBE_MASTERS
        value: "${MASTER_HOSTS}"
  hostNetwork: true
EOF
fi

if [ ! -e /etc/kubernetes/kubelet.conf ]; then
    mkdir -p /etc/systemd/system/kubelet.service.d
    cat <<EOF >/etc/systemd/system/kubelet.service.d/05-pharos-kubelet-proxy.conf
[Service]
ExecStartPre=-/sbin/swapoff -a
ExecStart=
ExecStart=/opt/bin/kubelet --pod-manifest-path=/etc/kubernetes/manifests/ --read-only-port=0 --cadvisor-port=0 --address=127.0.0.1
EOF
    systemctl daemon-reload
    systemctl enable kubelet
    systemctl start kubelet
    echo "Waiting kubelet-proxy to launch on port 6443..."
    while ! ncat -z 127.0.0.1 6443; do
    sleep 1
    done
    echo "kubelet-proxy launched"
    rm /etc/systemd/system/kubelet.service.d/05-pharos-kubelet-proxy.conf
    systemctl daemon-reload
    systemctl restart kubelet
fi

# Join worker to master
if [ ! -e /etc/kubernetes/kubelet.conf ]; then
    cat <<"EOF" >/etc/systemd/system/kubelet.service.d/10-kubeadm.conf
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_SYSTEM_PODS_ARGS=--pod-manifest-path=/etc/kubernetes/manifests --allow-privileged=true"
Environment="KUBELET_NETWORK_ARGS=--network-plugin=cni --cni-conf-dir=/etc/cni/net.d --cni-bin-dir=/opt/cni/bin"
Environment="KUBELET_AUTHZ_ARGS=--authorization-mode=Webhook --client-ca-file=/etc/kubernetes/pki/ca.crt"
Environment="KUBELET_CGROUP_ARGS=--cgroup-driver=cgroupfs"
Environment="KUBELET_CADVISOR_ARGS=--cadvisor-port=0"
Environment="KUBELET_CERTIFICATE_ARGS=--rotate-certificates=true"
ExecStart=
ExecStart=/opt/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_SYSTEM_PODS_ARGS $KUBELET_NETWORK_ARGS $KUBELET_DNS_ARGS $KUBELET_AUTHZ_ARGS $KUBELET_CGROUP_ARGS $KUBELET_CADVISOR_ARGS $KUBELET_CERTIFICATE_ARGS $KUBELET_EXTRA_ARGS
EOF
cat <<EOF >/etc/systemd/system/kubelet.service.d/05-pharos.conf
Environment="KUBELET_EXTRA_ARGS=--hostname-override=${HOSTNAME} --read-only-port=0"
Environment="KUBELET_DNS_ARGS=--cluster-dns=${CLUSTER_DNS} --cluster-domain=cluster.local"
EOF
    systemctl daemon-reload
    systemctl restart kubelet
    # kubeadm join ....
    kubeadm join localhost:6443 --ignore-preflight-errors DirAvailable--etc-kubernetes-manifests \
        --discovery-token-ca-cert-hash ${TOKEN_CA_CERT_HASH} \
        --token ${TOKEN}
fi