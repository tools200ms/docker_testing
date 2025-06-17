#!/bin/bash

readonly VERSION="0.1.2"

#TODO: add support for escape characters

[ -n "$PRETEND" ] && [[ $(echo "$PRETEND" | tr '[:upper:]' '[:lower:]') =~ ^y|yes|1|on$ ]] && \
  RUN="echo " || RUN=""

[ -n "$DEBUG" ] && [[ $(echo "$DEBUG" | tr '[:upper:]' '[:lower:]') =~ ^y|yes|1|on$ ]] && \
  set -xe || set -e


DEV2_ENV=""
[ -n "$DEBUG_CONT" ] && [[ $(echo "$DEBUG_CONT" | tr '[:upper:]' '[:lower:]') =~ ^y|yes|1|on$ ]] && \
        DEV2_ENV="$DEV2_ENV -e DEBUG=yes" || true

# MCID - id of main (to perform tests on) container
# TCID - id of testing (to be used do tests) container

RUN_NAME=""
RUN_BEGIN_TIME=0
TEST_CNT=0

FILTER=""
SKIP_RUN=false

if [ -d "$1" ]; then
        # if first argument is a directory, set it as current direcory
        PWD=$(realpath $1)
        IMG_NAME=$2
        FILTER="$3"
else
        PWD=$(pwd)
        IMG_NAME=$1
        FILTER="$2"
fi

function add_log_option() {
  local path=${PWD}/logs/latest-${1}.log

  if [ -e "${path}" ]; then
    rm ${path}
  fi
# --log-opt path='${path}'
  echo "--log-driver=none"
}

# echo $(add_log_option 'test1')

# Start net. inspector
function create_neti() {
  local res=0
  local out=
  local cmd_line="$1"
  local options=""

  if [[ " $2 " =~ " ip6 " ]]; then
    options="${options} --ipv6 --subnet=2001:db8:1::/64"
  fi

  # create network for testing purposes
  NETNAME=$(echo "test-$(echo $IMG_NAME | tr ':' '_')-$(date +%d%m-%y)")

  docker network inspect --format '{{.Id}}' $NETNAME 2>/dev/null && \
        echo "Network already exists" || \
        docker network create $options $NETNAME

  # Create tester:
  docker pull 200ms/alpinenet_dev2
  TCID=$(docker run $DEV2_ENV \
      -e COMMENT="Ext. tests" \
      -e FEAT="repath" \
      -v ${PWD}/test/functional:/usr/local/tests \
      --network=$NETNAME --detach --rm 200ms/alpinenet_dev2)
  THID=$(echo $TCID | cut -c -12)

  if [ $# -ne 0 ]; then
    out=$(docker exec $THID "bash" "-c" "waitfor.sh && $cmd_line") || res=$?

    if [ $res -ne 0 ]; then
      echo "Failed to initialize test"
      echo "Output: $out"
    fi
  fi

  return $res
}

function clean_neti() {
  docker stop $TCID
  docker network rm $NETNAME
}

# External test. def
# ----- Test 1 Begin:

function run() {
  local env_str=$1
  local vol_str=$2

  if [ -n "$env_str" ] && [ "-" == "$env_str" ]; then
    env_str=""
  fi

  if [ -n "$vol_str" ] && [ "-" == "$vol_str" ]; then
    vol_str=""
  fi

  run_with_env "$env_str" "$vol_str"
}

function run_expect_error() {
    local env_str=$1
  local vol_str=$2

  if [ -n "$env_str" ] && [ "-" == "$env_str" ]; then
    env_str=""
  fi

  if [ -n "$vol_str" ] && [ "-" == "$vol_str" ]; then
    vol_str=""
  fi

  run_with_env "$env_str" "$vol_str" $3
}

function run_with_env() {
  local e=$1
  local v=$2
  local expc_err=$3
  local auto_rm_flag="--rm"
  local local_env=""
  local local_vol=""
  local exit_code=

  if [ -n "$expc_err" ]; then
    # if error code is expected
    auto_rm_flag=""
  fi

  for i in $e; do
    local_env="$local_env -e $i"
  done

  for i in $v; do
    # Replace escaped colons with a temporary placeholder
    vol_mnt_list=$(echo "$i" | sed 's/\\:/\x01/g')
    host_path="${vol_mnt_list%%:*}"
    guest_path="${vol_mnt_list#*:}"

    if [[ "$host_path" = /* ]]; then
        host_path_full=${host_path}
    else
        host_path_full=${PWD}/${host_path}
    fi

    local_vol="$local_vol -v ${host_path_full}:${guest_path}"
  done

  TEST_CNT=$(($TEST_CNT + 1))

  if [ -n "$v" ]; then
    v_cut=$(echo "$v" | sed 's/[^:]*\(:.*\)/\1/g')
  else
    v_cut=""
  fi

  if [ -z "$expc_err" ] || [ "$expc_err" -eq 0 ]; then
    echo "RUN: $e, $v_cut"
    echo "Test no.: $TEST_CNT"
    # Notice: pending '-' after md5sum command output
    TEST_GLID=$(echo "$e;$v_cut" | md5sum | cut -c -8)
  else
    echo "RUN (expect fail: $expc_err): $e, $v_cut"
    TEST_GLID=$(echo "$expc_err;$e;$v_cut" | md5sum | cut -c -8)
  fi

  echo "Test Global Id: $TEST_GLID"
  RUN_NAME=""

  if [ -n "$FILTER" ]; then
    if [[ ! $TEST_GLID =~ $FILTER ]]; then
      echo "Fast forward, Skipping RUN"
      SKIP_RUN=true
      return 0
    else
      SKIP_RUN=false
    fi
  fi

  RUN_BEGIN_TIME=$(date +%s)

  # Launch container
  MCID=$($RUN docker run --cap-add=SYS_ADMIN --cap-add=NET_ADMIN --device /dev/fuse \
    $local_env $DEV2_ENV \
    $local_vol \
    -e COMMENT="MainTest1" \
    $(add_log_option 'test1') \
    --network=$NETNAME $auto_rm_flag --detach $IMG_NAME)

  if [ -n "$RUN" ]; then
    MCID="ID000TESTING0000000000"
  fi

  MHID=$(echo $MCID | cut -c -12)

  if [ -n "$expc_err" ]; then
    # check is running:
    docker inspect -f '{{.State.Running}}' $MHID

    # wait until container dies
    FAIL_TEST_TIMEOUT=60  # seconds
    FAIL_TEST_END_TIME=$(( $(date +%s) + FAIL_TEST_TIMEOUT ))

    while true; do
      mhid_status=$(docker inspect -f '{{.State.Status}}' $MHID)
      if [[ "$mhid_status" == "exited" ]]; then
        break
      fi
      sleep .2

      if [[ $(date +%s) -gt $FAIL_TEST_END_TIME ]]; then
        echo "Fail Test Timeout!"
        return 1
      fi
    done

    exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$MHID")

    if [ ${exit_code} -eq ${expc_err} ]; then
      echo "Container has terminated returning an expected exit code, Good."
      echo "    Exit code: ${exit_code}"
      docker rm $MHID
      return 0
    else
      echo "NOT EXPECTED exit code: ${exit_code}"
      echo "    Expected code: ${expc_err}"
      return 1
    fi

    return 1
  fi
}

stop() {
  if $SKIP_RUN; then
    echo "Nothing to stop"
    return 0
  fi

  echo "Total test time: $(($(date +%s) - $RUN_BEGIN_TIME)) sec."
  # test how long stop takes
  $RUN docker stop $MCID
}

fail_if_lessthen_sec() {
  local ctime=$(($(date +%s) - $RUN_BEGIN_TIME))

  if $SKIP_RUN; then
    echo "Nothing to do"
    return 0
  fi

  if [ $ctime -gt 255 ]; then
    echo "Exceeded timeout value"
    exit 4
  fi

  if [ $ctime -ge $1 ]; then
    echo "Test took $ctime sec. so far, good as it is above minimum value of $1 sec."
  else
    echo "ERROR: too litle time has passed"
    return 1
  fi

  return 0
}

test_neti() {
  _test $THID "$@"
}

test() {
  _test $MHID "$@"
}

# This test is used to check if docker image has "produced"
# expected results
test_ext() {
  local condition="$1"
  local message="$2"
  local command="$3"

  if $SKIP_RUN; then
    echo "TestExt: Nothing to do"
    return 0
  fi

  eval "[[ $condition ]]" && res=0 || res=$?
  if [ $res -eq 0 ]; then
    echo "TestExt PASSED: $condition"
  else
    echo "TestExt FAILED: $condition"
  fi
  echo "    $message"

  # cleanup
  if [ -n "$command" ]; then
    eval $command
  fi

  return $res
}

restart() {
  echo "Restarting docker with --rm option"
  #docker restart $MHID
  #return $?
}

_test() {
  local target_cnt=$1
  shift
  local options=""

  if $SKIP_RUN; then
    echo "Nothing to do"
    return 0
  fi

  # extract shell options
  while [[ $1 == -* ]]; do
    options="$options $1"
    shift
  done

  local args=("$@")
  local res=0
  local cmd=
  local out=
  local assert="${args[-1]}"
  unset 'args[-1]'

  if $(echo "${args[@]}" | grep -q '{test}'); then
    cmd=$(echo "${args[@]}" | sed "s/{test}/$MHID/g")
    echo "FUNCTIONAL test: $cmd"
  else
    cmd="${args[@]}"
  fi

  out=$(docker exec $target_cnt 'bash' '-c' $options "${cmd}") || res=$?

  if [ $res -ne 0 ]; then
    echo "Non-zero exit code: "
    echo "${args[@]}"
    echo "Error code: $res"
    echo "Output: $out"

    return $res
  fi

  if [ "$assert" == '-' ]; then
    # no assertion, just check exit code
    echo "Test (no assertion) PASSED: "
    echo "    ${args[@]}"

    return 0
  fi

  # command call should return exactly one line
  # only no-assertion call can be multiline
  if [ $(echo "$out" | wc -l) -ne 1 ]; then
    # TODO: check for potential tailing empty lines - trim and accept if
    # TODO: overall still one line remains
    echo "ERROR - illegal assertion: Assertion can only work with one line output"
    return 50
  fi

  eval "[[ \"$out\" $assert ]]" || res=$?
  if [ $res -eq 0 ]; then
    echo "Test PASSED: "
    echo "    ${args[@]}"
    echo "    result: '$out' $assert"
  else
    echo "Assertion failed: "
    echo "${args[@]}"
    echo "Result: $out"
    echo "Expected: $assert"

    return $res
  fi
}

testm_except() {
  :
}
