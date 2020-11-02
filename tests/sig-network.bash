#!/usr/bin/env bash

set -euo pipefail

. ./shared.bash

trap _cleanup EXIT

_setup_worker() {
  node_name=$1
  logline "create a token for ${node_name}"
  token=$(./bin/footloose ssh --config $footlooseconfig root@node0 "k0s token create --role=worker")
  ip=$(./bin/footloose ssh --config $footlooseconfig root@node0 "hostname -i")
  logline "join worker ${node_name}"
  ./bin/footloose ssh --config $footlooseconfig "root@${node_name}" "nohup k0s worker ${token} >/tmp/k0s-worker.log 2>&1 &"
  logline "wait a bit for worker ${node_name} to start properly ..."
  while true; do
    >/dev/null 2>&1  ./bin/footloose ssh -c $footlooseconfig "root@${node_name}" "ps | grep calico-node" && break
    sleep 1
  done
}

_setup_cluster() {
  logline "start server"
  ./bin/footloose ssh --config $footlooseconfig root@node0 "nohup k0s server >/tmp/k0s-server.log 2>&1 &"
  logline "wait a bit ..."
  ## TODO Maybe we could replace all the sleeps with polling of the healthz endpoint
  while true; do
     >/dev/null 2>&1 ./bin/footloose ssh -c $footlooseconfig root@node0 "ps | grep kube-apiserver" && break
    sleep 1
  done
  # API is up, but it needs to do quite a bit of init work still
  sleep 20

  ./bin/footloose ssh --config $footlooseconfig root@node0 "cat /var/lib/k0s/pki/admin.conf" > kubeconfig

  _setup_worker "node1"
  _setup_worker "node2"
}

# Very crude "timeout" handling, should hopefully forcibly terminate
# everything and also dump log files
curpid=$$
(sleep 20m && kill $curpid) &
echo "Timer set to expire in 20mins to ensure we see logs of nodes"

_setup
title "sonobuoy[sig-network]: 1 controller, 2 workers"
_setup_cluster


export KUBECONFIG=./kubeconfig
./bin/kubectl get nodes -o wide
./bin/kubectl get pods --all-namespaces -o wide

(
  sleep 10
  exec ./bin/sonobuoy logs -f
)& 2>&1 | sed -le "s#^#sonobuoy:logs: #;"
logs_pid=$!

logline "run sonobuoy:"
set +e
./bin/sonobuoy run --wait=60 --plugin-env=e2e.E2E_USE_GO_RUNNER=true '--e2e-focus=\[sig-network\].*\[Conformance\]' '--e2e-skip=\[Serial\]' --e2e-parallel=y
kill $logs_pid
wait $logs_pid
set -e

results=$(./bin/sonobuoy retrieve)
./bin/sonobuoy results "${results}"
./bin/sonobuoy status | grep -q -E ' +e2e +complete +passed +'
result=$?
rm -f "${results}"
if [ "${result}" = "0" ]; then
  title "sonobuoy[sig-network]: SUCCESS!!!"
  exit 0
else
  title "sonobuoy[sig-network]: FAILURE!!!"
  exit $result
fi
