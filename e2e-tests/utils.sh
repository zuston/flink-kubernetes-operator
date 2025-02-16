#!/usr/bin/env bash
################################################################################
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
################################################################################

function wait_for_logs {
  local jm_pod_name=$1
  local successful_response_regex=$2
  local timeout=$3

  # wait or timeout until the log shows up
  echo "Waiting for log \"$2\"..."
  for i in $(seq 1 ${timeout}); do
    if kubectl logs $jm_pod_name | grep -E "${successful_response_regex}" >/dev/null; then
      echo "Log \"$2\" shows up."
      return
    fi

    sleep 1
  done
  echo "Log $2 does not show up within a timeout of ${timeout} sec"
  exit 1
}

function retry_times() {
    local retriesNumber=$1
    local backoff=$2
    local command="$3"

    for i in $(seq 1 ${retriesNumber})
    do
        if ${command}; then
            return 0
        fi

        echo "Command: ${command} failed. Retrying..."
        sleep ${backoff}
    done

    echo "Command: ${command} failed ${retriesNumber} times."
    return 1
}

function debug_and_show_logs {
    echo "Debugging failed e2e test:"
    echo "Currently existing Kubernetes resources"
    kubectl get all
    kubectl describe all

    echo "Flink logs:"
    kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | while read pod;do
        containers=(`kubectl get pods  $pod -o jsonpath='{.spec.containers[*].name}'`)
        i=0
        for container in "${containers[@]}"; do
          echo "Current logs for $pod:$container: "
          kubectl logs $pod $container;
          restart_count=$(kubectl get pod $pod -o jsonpath='{.status.containerStatuses['$i'].restartCount}')
          if [[ ${restart_count} -gt 0 ]];then
            echo "Previous logs for $pod: "
            kubectl logs $pod $container --previous
          fi
        done
    done
}

function start_minikube {
    if ! retry_times 5 30 start_minikube_if_not_running; then
        echo "Could not start minikube. Aborting..."
        exit 1
   fi
}

function start_minikube_if_not_running {
    if ! minikube status; then
        echo "Starting minikube ..."
        minikube start \
        --extra-config=kubelet.image-gc-high-threshold=99 \
        --extra-config=kubelet.image-gc-low-threshold=98 \
        --extra-config=kubelet.minimum-container-ttl-duration=120m \
        --extra-config=kubelet.eviction-hard="memory.available<5Mi,nodefs.available<1Mi,imagefs.available<1Mi" \
        --extra-config=kubelet.eviction-soft="memory.available<5Mi,nodefs.available<2Mi,imagefs.available<2Mi" \
        --extra-config=kubelet.eviction-soft-grace-period="memory.available=2h,nodefs.available=2h,imagefs.available=2h"
        minikube update-context
    fi

    minikube status
    return $?
}

function stop_minikube {
    echo "Stopping minikube ..."
    if ! retry_times 5 30 "minikube stop"; then
        echo "Could not stop minikube. Aborting..."
        exit 1
    fi
}

function _on_exit_callback {
  # Export the exit code so that it could be used by the callback commands
  export TRAPPED_EXIT_CODE=$?
  # Un-register the callback, to avoid multiple invocations: some shells may treat some signals as subset of others.
  trap "" INT EXIT
  # Fast exit, if there is another keyboard interrupt.
  trap "exit -1" INT

  for command in "${_on_exit_commands[@]-}"; do
    eval "${command}"
  done
}

# Register for multiple signals: some shells interpret them as mutually exclusive.
trap _on_exit_callback INT EXIT

# Helper method to register a command that should be called on current script exit.
# It allows to have multiple "on exit" commands to be called, compared to the built-in `trap "$command" EXIT`.
# Note: tests should not use `trap $command INT|EXIT` directly, to avoid having "Highlander" situation.
function on_exit {
  local command="$1"

  # Keep commands in reverse order, so commands would be executed in LIFO order.
  _on_exit_commands=("${command}" "${_on_exit_commands[@]-}")
}
