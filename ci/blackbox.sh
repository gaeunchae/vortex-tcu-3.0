#!/bin/sh

# Copyright © 2019-2023
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

SCRIPT_DIR=$(dirname "$0")
ROOT_DIR=$SCRIPT_DIR/..

show_usage()
{
    echo "Vortex BlackBox Test Driver v1.0"
    echo "Usage: $0 [[--clusters=#n] [--cores=#n] [--warps=#n] [--threads=#n] [--l2cache] [--l3cache] [[--driver=#name] [--app=#app] [--args=#args] [--debug=#level] [--scope] [--saif] [--perf=#class] [--vcd_file=#file] [--saif_file=#file] [--log=logfile] [--nohup] [--help]]"
}

show_help()
{
    show_usage
    echo "  where"
    echo "--driver: gpu, simx, rtlsim, oape, xrt, xrt_vcs"
    echo "--app: any subfolder test under regression, graphics, mpi, opencl, or hip"
    echo "--class: 0=disable, 1=pipeline, 2=memsys"
    echo "--nohup: build and run in temp directory"
}

add_option() {
    if [ -n "$1" ]; then
        echo "$1 $2"
    else
        echo "$2"
    fi
}

DEFAULTS() {
    DRIVER=simx
    APP=sgemm
    DEBUG=0
    DEBUG_LEVEL=0
    SCOPE=0
    SAIF=0
    HAS_ARGS=0
    HAS_NP=0
    PERF_CLASS=0
    CONFIGS="$CONFIGS"
    TEMPBUILD=0
    LOGFILE=run.log
    VCD_FILE=$PWD/trace.vcd
    SAIF_FILE=$PWD/trace.saif
}

parse_args() {
    DEFAULTS
    for i in "$@"; do
        case $i in
            --driver=*) DRIVER=${i#*=} ;;
            --app=*)    APP=${i#*=} ;;
            --clusters=*) CONFIGS=$(add_option "$CONFIGS" "-DVX_CFG_NUM_CLUSTERS=${i#*=}") ;;
            --cores=*)  CONFIGS=$(add_option "$CONFIGS" "-DVX_CFG_NUM_CORES=${i#*=}") ;;
            --warps=*)  CONFIGS=$(add_option "$CONFIGS" "-DVX_CFG_NUM_WARPS=${i#*=}") ;;
            --threads=*) CONFIGS=$(add_option "$CONFIGS" "-DVX_CFG_NUM_THREADS=${i#*=}") ;;
            --l2cache)  CONFIGS=$(add_option "$CONFIGS" "-DVX_CFG_L2_ENABLE") ;;
            --l3cache)  CONFIGS=$(add_option "$CONFIGS" "-DVX_CFG_L3_ENABLE") ;;
            --perf=*)   CONFIGS=$(add_option "$CONFIGS" "-DPERF_ENABLE"); PERF_CLASS=${i#*=} ;;
            --debug=*)  DEBUG=1; DEBUG_LEVEL=${i#*=} ;;
            --scope)    SCOPE=1 ;;
            --saif)     SAIF=1 ;;
            --vcd_file=*)  VCD_FILE=${i#*=} ;;
            --saif_file=*) SAIF_FILE=${i#*=} ;;
            --args=*)   HAS_ARGS=1; ARGS=${i#*=} ;;
            --np=*)     HAS_NP=1; NP=${i#*=} ;;
            --log=*)    LOGFILE=${i#*=} ;;
            --nohup)    TEMPBUILD=1 ;;
            --help)     show_help; exit 0 ;;
            --*)        echo "Invalid argument: $i"; show_usage; exit 1 ;;
            *)          show_usage; exit 1 ;;
        esac
    done
}

# Two consecutive free TCP ports for the VCS co-simulation (ctrl, mem). Both are
# bound before being reported so a concurrent picker cannot take the pair.
kill_simv()
{
    [ -n "${VCS_PORT:-}" ] && pkill -u "$(id -u)" -f "simv \+SOCKET_PORT=$VCS_PORT" 2>/dev/null
    if [ -n "${VCS_PID:-}" ]; then
        kill $VCS_PID 2>/dev/null
        wait $VCS_PID 2>/dev/null
    fi
    return 0
}

pick_vcs_socket_port() {
    python3 -c '
import socket, sys
for _ in range(1000):
    socks = []
    try:
        ctrl = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        ctrl.bind(("", 0))
        port = ctrl.getsockname()[1]
        socks.append(ctrl)
        if port >= 65535:
            continue
        mem = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        mem.bind(("", port + 1))
        socks.append(mem)
        print(port)
        sys.exit(0)
    except OSError:
        pass
    finally:
        for s in socks:
            s.close()
sys.exit(1)
'
}

set_driver_path() {
    case $DRIVER in
        gpu) DRIVER_PATH="" ;;
        simx|rtlsim|opae|xrt) DRIVER_PATH="$ROOT_DIR/sw/runtime/$DRIVER" ;;
        xrt_vcs) DRIVER_PATH="$ROOT_DIR/sw/runtime/xrt" ;;
        *) echo "Invalid driver: $DRIVER"; exit 1 ;;
    esac
}

set_app_path() {
    if [ -d "$APP" ]; then
        APP_PATH="$APP"
    elif [ -d "$ROOT_DIR/tests/$APP" ]; then
        APP_PATH="$ROOT_DIR/tests/$APP"
    elif [ -d "$ROOT_DIR/tests/regression/$APP" ]; then
        APP_PATH="$ROOT_DIR/tests/regression/$APP"
    elif [ -d "$ROOT_DIR/tests/graphics/$APP" ]; then
        APP_PATH="$ROOT_DIR/tests/graphics/$APP"
    elif [ -d "$ROOT_DIR/tests/mpi/$APP" ]; then
        APP_PATH="$ROOT_DIR/tests/mpi/$APP"
    elif [ -d "$ROOT_DIR/tests/opencl/$APP" ]; then
        APP_PATH="$ROOT_DIR/tests/opencl/$APP"
    elif [ -d "$ROOT_DIR/tests/hip/$APP" ]; then
        APP_PATH="$ROOT_DIR/tests/hip/$APP"
    else
        echo "Application folder not found: $APP"
        exit 1
    fi
}

build_driver() {
    local cmd_opts=""
    [ $DEBUG -ne 0 ] && cmd_opts=$(add_option "$cmd_opts" "DEBUG=$DEBUG_LEVEL")
    [ $SCOPE -eq 1 ] && cmd_opts=$(add_option "$cmd_opts" "SCOPE=1")
    [ $SAIF -eq 1 ] && cmd_opts=$(add_option "$cmd_opts" "SAIF=1")
    [ $TEMPBUILD -eq 1 ] && cmd_opts=$(add_option "$cmd_opts" "DESTDIR=\"$TEMPDIR\"")
    [ -n "$CONFIGS" ] && cmd_opts=$(add_option "$cmd_opts" "CONFIGS=\"$CONFIGS\"")
    if [ "$DRIVER" = "xrt_vcs" ]; then
        local vcs_opts=""
        [ $DEBUG -ne 0 ] && vcs_opts=$(add_option "$vcs_opts" "DEBUG=$DEBUG_LEVEL")
        # The app's Makefile appends its own -DVX_CFG_EXT_*_ENABLE, but that
        # happens when run-xrt builds the app -- long after simv is elaborated.
        # Without lifting them here the RTL is built WITHOUT the extension while
        # the app expects it, and the only symptom is a bare "<X> extension not
        # supported!" from the runtime.
        local app_cfgs=""
        if [ -f "${APP_PATH:-}/Makefile" ]; then
            app_cfgs=$(grep -oE '\-DVX_CFG_EXT_[A-Z0-9_]+_ENABLE' "$APP_PATH/Makefile" 2>/dev/null | sort -u | tr '\n' ' ')
        fi
        local vcs_cfgs="$CONFIGS"
        for c in $app_cfgs; do
            case "$vcs_cfgs" in *"$c"*) ;; *) vcs_cfgs="$vcs_cfgs $c" ;; esac
        done
        [ -n "$vcs_cfgs" ] && vcs_opts=$(add_option "$vcs_opts" "CONFIGS=\"$vcs_cfgs\"")
        [ $TEMPBUILD -eq 1 ] && vcs_opts=$(add_option "$vcs_opts" "DESTDIR=\"$TEMPDIR\"")
        [ -n "${FSDB_DUMP:-}" ] && vcs_opts=$(add_option "$vcs_opts" "FSDB_DUMP=1")
        # Pipeline/mem/cache tracing turns simv.log into multiple GB. Keep it off
        # unless --debug asked for it: a run that X-propagates spins in the
        # assertion handler and once wrote a 59 GB log that filled the disk.
        if [ $DEBUG -eq 0 ]; then
            vcs_opts=$(add_option "$vcs_opts" "NO_DBG_TRACE=1")
        fi
        for tgt in simv applib; do
            echo "Running: $vcs_opts make -C $ROOT_DIR/sim/xrtsim_vcs $tgt"
            eval "$vcs_opts make -C $ROOT_DIR/sim/xrtsim_vcs $tgt"
            status=$?
            if [ $status -ne 0 ]; then
                echo "Error building VCS $tgt"
                exit $status
            fi
        done
        cmd_opts=$(add_option "$cmd_opts" "TARGET=xrtsim_vcs make -C $DRIVER_PATH > /dev/null")
    else
        cmd_opts=$(add_option "$cmd_opts" "make -C $DRIVER_PATH > /dev/null")
    fi
    echo "Running: $cmd_opts"
    eval "$cmd_opts"
    status=$?
    if [ $status -ne 0 ]; then
        echo "Error building driver: $DRIVER_PATH"
        exit $status
    fi
}

run_app() {
    local cmd_opts=""
    [ $DEBUG -ne 0 ] && cmd_opts=$(add_option "$cmd_opts" "DEBUG=$DEBUG_LEVEL")
    # The test target rebuilds the runtime; SCOPE must be propagated here
    # too, else it relinks libvortex without -DSCOPE and the scope drains
    # are silently compiled out.
    [ $SCOPE -eq 1 ] && cmd_opts=$(add_option "$cmd_opts" "SCOPE=1")
    [ $TEMPBUILD -eq 1 ] && cmd_opts=$(add_option "$cmd_opts" "VORTEX_RT_LIB=\"$TEMPDIR\"")
    [ $HAS_ARGS -eq 1 ] && cmd_opts=$(add_option "$cmd_opts" "OPTS=\"$ARGS\"")
    [ -n "$CONFIGS" ] && cmd_opts=$(add_option "$cmd_opts" "CONFIGS=\"$CONFIGS\"")
    local run_target=$DRIVER
    if [ "$DRIVER" = "xrt_vcs" ]; then
        run_target=xrt
        # run-xrt rebuilds the runtime; without TARGET it falls back to the
        # default xrtsim backend and relinks against the wrong library.
        cmd_opts=$(add_option "$cmd_opts" "TARGET=xrtsim_vcs")
    fi
    cmd_opts=$(add_option "$cmd_opts" "make -C \"$APP_PATH\" run-$run_target")
    [ $DEBUG -ne 0 ] && cmd_opts=$(add_option "$cmd_opts" "> $LOGFILE 2>&1")
    echo "Running: $cmd_opts"
    eval "$cmd_opts"
    status=$?
    return $status
}

main() {
    parse_args "$@"
    set_driver_path
    set_app_path

    if [ $SAIF -eq 1 ] && [ "$DRIVER" = "simx" ]; then
        echo "Error: SAIF is not supported with the simx driver"
        exit 1
    fi

    # execute on default installed GPU
    if [ "$DRIVER" = "gpu" ]; then
        run_app
        exit $?
    fi

    if [ -n "$CONFIGS" ]; then
        echo "CONFIGS=$CONFIGS"
    fi

    export VORTEX_PROFILING=$PERF_CLASS
    export VCD_FILE=$VCD_FILE
    export SAIF_FILE=$SAIF_FILE

    make -C "$ROOT_DIR/sw/runtime/stub" > /dev/null

    if [ $TEMPBUILD -eq 1 ]; then
        # setup temp directory
        TEMPDIR=$(mktemp -d)
        mkdir -p "$TEMPDIR"
        # build stub driver
        echo "Running: DESTDIR=$TEMPDIR make -C $ROOT_DIR/sw/runtime/stub"
        DESTDIR="$TEMPDIR" make -C $ROOT_DIR/sw/runtime/stub > /dev/null
        # stage a per-invocation copy of the app dir so concurrent trials do not
        # race on the shared `config.stamp` / build artifacts. Keep it as a
        # sibling of the original so relative paths (`../../..`, `../common.mk`)
        # still resolve.
        STAGED_APP="${APP_PATH%/}.trial.$$.$(date +%N)"
        cp -r "$APP_PATH" "$STAGED_APP"
        APP_PATH="$STAGED_APP"
        # register tempdir + staged app cleanup on exit
        trap "rm -rf $TEMPDIR $STAGED_APP" EXIT
    fi

    build_driver

    if [ "$DRIVER" = "xrt_vcs" ]; then
        local VCS_PORT
        VCS_PORT=${VCS_SOCKET_PORT:-$(pick_vcs_socket_port)}
        if [ -z "$VCS_PORT" ]; then
            echo "Error: could not reserve a VCS socket port pair"
            exit 1
        fi
        local SIMV_DIR
        if [ $TEMPBUILD -eq 1 ]; then
            SIMV_DIR="$(realpath "$TEMPDIR")"
        else
            SIMV_DIR="$(realpath "$ROOT_DIR/sim/xrtsim_vcs")"
        fi
        local SIMV_LOG="$SIMV_DIR/simv.log"
        echo "Launching VCS simv on port $VCS_PORT (log: $SIMV_LOG, cap ${SIMV_LOG_CAP:-256M})..."
        # head -c caps the log; when simv exceeds it the SIGPIPE kills the sim,
        # so a runaway assertion loop fails the test instead of the filesystem.
        (cd "$SIMV_DIR" && ./simv +SOCKET_PORT=$VCS_PORT -suppress=ASLR_DETECTED_INFO \
            ${VCS_SIMV_FLAGS:-} 2>&1 | head -c "${SIMV_LOG_CAP:-256M}" > "$SIMV_LOG") &
        VCS_PID=$!
        export VCS_SOCKET_PORT=$VCS_PORT
        # $! is the SUBSHELL, not simv, so killing it alone orphans the sim --
        # that is how stale simv processes leaked before. +SOCKET_PORT is unique
        # per run, so pkill on it targets exactly this simv and never blackbox.
        trap 'kill_simv' EXIT INT TERM HUP
    fi

    run_app
    status=$?

    kill_simv

    exit $status
}

main "$@"