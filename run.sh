#!/bin/bash

declare -A levels=([DEBUG]=0 [INFO]=1 [WARN]=2 [ERROR]=3)
script_logging_level="INFO"

function log {
  local log_message=$1
  local log_priority=$2
  #check if level exists:
  [[ ${levels[$log_priority]} ]] || return 1
  #check if level is enough:
  (( ${levels[$log_priority]} < ${levels[$script_logging_level]} )) && return 2
  echo "[$(date --rfc-3339=seconds)] : ${log_priority} : ${log_message}"
}

if [[ -z $NODE_TIMEOUT ]]
then
	NODE_TIMEOUT=30
fi
log "Node timeout: $NODE_TIMEOUT" "INFO"

if [[ -z $AUTO_UNCORDON ]]
then
	AUTO_UNCORDON=true
fi
log "Auto uncordon node on recovery is $AUTO_UNCORDON" "INFO"

if [[ -z $REMOVE_PODS ]]
then
  REMOVE_PODS=true
fi
log "Remove all pods from drained node is $REMOVE_PODS" "INFO"

if [[ -z $CATTLE_CLUSTER_AGENT ]]
then
  CATTLE_CLUSTER_AGENT=true
fi

touch ~/drained_nodes

while true
do
	if curl -v --silent http://localhost:4040/ 2>&1 | grep $HOSTNAME
	then
		log "Leader" "DEBUG"
		for node in $(kubectl get nodes --no-headers --output=name)
		do
			log "Checking $node" "DEBUG"
			current_status="$(kubectl get --no-headers $node | awk '{print $2}')"
			log "Current node status: $current_status" "DEBUG"
			if [[ "$current_status" == "Ready" ]] || [[ "$current_status" == "Ready,SchedulingDisabled" ]]
			then
				log "$node is ready" "DEBUG"
				if cat ~/drained_nodes | grep -x $node
				then
					log "$node has recovered" "INFO"
					cat ~/drained_nodes | grep -v -x $node > ~/drained_nodes.tmp
					mv ~/drained_nodes.tmp ~/drained_nodes
					if [[ "$AUTO_UNCORDON" == "true" ]]
					then
						log "uncordon $node" "INFO"
						kubectl uncordon $node
					fi
				fi

			else
				if cat ~/drained_nodes | grep -x $node
				then
					log "$node is already drained, skipping..." "INFO"
				else
					log "$node in Not ready, rechecking..." "INFO"
					count=0
					while true
					do
						current_status="$(kubectl get --no-headers $node | awk '{print $2}')"
						if [[ ! "$current_status" == "Ready" ]] || [[ "$current_status" == "Ready,SchedulingDisabled" ]]
						then
							log "Sleeping for $count seconds" "INFO"
							sleep 1
							count=$((count+1))
						else
							log "$node is now ready" "INFO"
							cat ~/drained_nodes | grep -v -x $node > ~/drained_nodes.tmp
	            mv ~/drained_nodes.tmp ~/drained_nodes
							break
						fi
						if [ $count -gt $NODE_TIMEOUT ]
						then
							log "$node has been down for greater than 30s." "INFO"
							log "Starting drain of node..." "INFO"
							kubectl drain $node --ignore-daemonsets --delete-local-data --force
							echo $node >> ~/drained_nodes
							log "Sleeping for 60 seconds..." "INFO"
							sleep 60
							if [[ "$REMOVE_PODS" == "true" ]]
							then
								log "Getting all pods on node..." "INFO"
								node_short="$(log $node | awk -F '/' '{print $2}')"
								kubectl get pods --all-namespaces -o wide --field-selector spec.nodeName="$node_short" --no-headers | awk '{print $1 "," $2}' > /tmp/pods.csv
								while IFS=, read -r namespace podname
								do
									log "Removing $podname from $namespace" "INFO"
									podcount=0
									while ! kubectl delete pods "$podname" -n "$namespace" --grace-period=0 --force
									do
										sleep 1
										podcount=$((podcount+1))
										if [ $podcount -gt 60 ]
										then
											break
										fi
									done
								done < /tmp/pods.csv
							fi
							if [[ "$CATTLE_CLUSTER_AGENT" == "true" ]]
							then
								log "Checking if cattle-cluster-agent is already running..." "DEBUG"
								if [[ ! "$(kubectl get pods -n cattle-system | grep ^'cattle-cluster-agent-' | awk '{print $3}')" == "Running" ]]
								then
									log "Scaling up to force pod to new node..." "DEBUG"
									kubectl scale --replicas=2 deployment/cattle-cluster-agent -n cattle-system
									cattlecount=0
									while ! kubectl get pods -n cattle-system | grep ^'cattle-cluster-agent-' | awk '{print $3}' | grep "Running"
									do
										sleep 1
                      cattlecount=$((cattlecount+1))
                      if [ $cattlecount -gt 30 ]
                      then
                        break
                      fi
									done
									log "Scaling back down to 1..." "DEBUG"
									kubectl scale --replicas=1 deployment/cattle-cluster-agent -n cattle-system
								else
									log "cattle-cluster-agent is already running..." "DEBUG"
								fi
							fi
							break
						fi
					done
				fi
			fi
		done
	else
		log "Standby" "DEBUG"
	fi
	log "Sleeping for 5s before rechecking..." "DEBUG"
	sleep 5
done
