#!/usr/bin/env bash

## author: Joshua Worley
## version: 2020.01.06

## Purpose:
## Daily index maintenance which will reduce replicas to 0, then delete


###Begin functions###

_LOG() {
  echo "$(date --iso-8601=seconds) [${1}] ${2}" >> /var/log/elastic_maint.log
}

_NOTIFY() {
  salt-call event.send 'salt/${HOSTNAME}/slack' "{\"message\":\"${1}\"}"
}

_INDICES() {
  # Pull list of indices matching user input
  curl -sXGET 'localhost:9200/_cat/indices' | grep "${1}" | awk '{ print $3 }' | sort -t . -k 4 -n
}

_HEALTH() {
  # Pull cluster health (return is JSON)
  curl -sXGET 'localhost:9200/_cluster/health'
}

_SANITY() {
  # Sanity check to kill script if cluster health is not green (healthy/normal)
  # Abort with exit code 2 (error) if necessary
  if [[ $(echo ${1} | jq -r .status) != "green" ]]; then
    MSG="Cluster unhealthy, abandon ship"
    _LOG "FATAL" "${MSG}" && _NOTIFY "${MSG}"
    exit 2
  else
    _LOG "INFO" "Cluster healthy, proceeding"
  fi
}

_REPLICA0() {
  # Set replicas for a given index to 0
  curl -sXPUT "localhost:9200/${1}/_settings" -H 'Content-Type: application/json' -d '{"index":{"number_of_replicas":0}}'
  if [[ $? -ne 0 ]]; then
    _LOG "INFO" "${1} replicas set to 0"
  else
    _LOG "WARN" "${1} unusual exit code when set to replica 0"
  fi
}

_DELETE() {
  # Delete given index
  curl -sXDELETE "localhost:9200/${1}"
  if [[ $? -ne 0 ]]; then
    _LOG "INFO" "${1} successfully deleted"
  else
    _LOG "WARN" "${1} unusual exit code when deleted"
  fi
}

_PENDING() {
  # Prevent cluster from being overburdened with tasks
  T=$(_HEALTH | jq -r .number_of_pending_tasks)
  while [ ${T} -ne 0 ]; do
    _LOG "ERROR" "${T} pending tasks"
    sleep 3
    T=$(_HEALTH | jq -r .number_of_pending_tasks)
  done
  _SANITY "$(_HEALTH)"
}

###End functions###

if [[ $# -ne 2 ]]; then
  echo "Usage: ${0} \$index-prefix \$date-math"
  echo "example ${0} \"\$index-name\" \"last month yesterday\""
  MSG="Invalid number of arguments $?"
  _LOG "FATAL" "${MSG}" && _NOTIFY "${MSG}"
  exit 2
else
  _LOG "INFO" "Script started; user input: ${1} ${2}"
fi

D=$(date --date "${2}" '+%Y.%m.%d')
if [[ $? -ne 0 ]]; then
  MSG="Date command did not complete successfully; check your date math!"
  _LOG "FATAL" "${MSG}" && _NOTIFY "${MSG}"

  exit 2
fi
I=${1}-
INDEX=${I}${D}

_SANITY "$(_HEALTH)"
# ^Initial test to judge cluster status before further tasks
I=(`_INDICES "${INDEX}"`)
# ^Build array of targeted indices

if [[ ${#I[@]} -eq 0 ]]; then
  # Kill script if no indices exist
  _LOG "ERROR" "There are no ${INDEX} indices"
  RESUME=0
else
  # Proceed by setting kill switch to 1
  _LOG "INFO" "There are ${#I[@]} ${INDEX} indices"
  RESUME=1
fi

if [[ ${RESUME} -eq 1 ]]; then
  for i in ${I[@]}; do
    _REPLICA0 "${i}"
    _PENDING
    _DELETE "${i}"
    _PENDING
  done
fi

MSG="Cluster maintenance completed successfully"
_LOG "INFO" "${MSG}" && _NOTIFY "${MSG}"
