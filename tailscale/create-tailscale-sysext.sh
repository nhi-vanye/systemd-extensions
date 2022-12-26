#! /bin/bash
#
# Copyright (c) 2022 Badon Hill Technologies. All rights reserved
#
# Script to build tailscale into a systemd-sysext.
#
# This does not download the tailscale tarball - pass the tarball's path via --tarball

# There are two usecases
#
# 1.  Called as part of a building an ISO to embed into installer
# 2.  Allow for updating the tailscale extension on live system
#
# This might explain some of the multiple ways to control script
#
#

# Installer writers
#
# If you want to preprocess this script to embed KEYS, then replace these strings (using sed)
#   INSTALLER_BOOTSTRAP_KEY
#   INSTALLER_HOST_KEY
#

set -eEu -o pipefail

export TAILSCALETARBALL=
export SYSEXTENSION=
export TAILSCALEVER=
export TAILSCALEKEYBOOTSTRAP=
export TAILSCALEKEYHOST=

SAFE=$(date +'%Y%m%dT%H%M%S.%N')

# ingore unreachability
# shellcheck disable=SC2317
function clean {
    echo "Cleaning up..."

    rm -rf build-root-"${SAFE}" tailscale_"${TAILSCALEVER}"_amd64

}

# ingore unreachability
# shellcheck disable=SC2317
function catch_error {

    local -n _bash_lineno="${1:-BASH_LINENO}"
    local _last_command="${2:-${BASH_COMMAND}}"
    local _code="${3:-0}"

    echo "Caught errno $_code at line #$_bash_lineno : $_last_command"

    exit "$_code"
}

trap 'catch_error "BASH_LINENO" "${BASH_COMMAND}" "${?}"' ERR
trap 'clean' EXIT

################################################################
#
# standard helpers
#

function h1 {

    echo ""
    echo "$(date +'%Y-%m-%dT%H:%M:%S') $*"
    echo "$(date +'%Y-%m-%dT%H:%M:%S') $*" | tr '[:print:]' '='
    echo ""

}

function h2 {

    echo ""
    echo "$*"
    echo "$*" | tr '[:print:]' '-'
    echo ""

}

function log {

    now=$(date +"%Y-%m-%dT%H:%M:%S")
    sed -e "s/^/$now /g"
}

################################################################
#
# application helpers
#

function create_tailscale_helper {

    buildroot=$1

    cat > "${buildroot}"/usr/local/bin/tailscale.sh <<- 'EOF'
		#! /bin/bash
		#
		# Copyright (c) 2022 Badon Hill Technologies
		#
		# wrapper around tailscale client to provide shell expansion of
		# variables for systemd.services

		# This file will be read-only
		if [ -r /usr/share/tailscale/tailscale ]
		then
		. /usr/share/tailscale/tailscale
		fi

		# Allow overriding of read-only defaults...
		if [ -r /etc/default/tailscale ]
		then
		. /etc/default/tailscale
		fi

		TAILSCALEAUTH="${HOSTKEY:-${BOOTSTRAPKEY}}"

		if [ "$1" = "login" ]
		then
		  if [ -n "$TAILSCALEAUTH" ]
		  then
		    /usr/bin/tailscale login --auth-key=$TAILSCALEAUTH $LOGINFLAGS ${@:2}
		    st=$?
		    exit $st
		  fi
		  echo "Neither BOOTSTRAPKEY or HOSTKEY is set in /usr/share/tailscale/tailscale"
		  echo "or /etc/default/tailscale."
		  echo "Copy /usr/share/tailscale/tailscale to /etc/default/tailscale and edit"
		  echo "as needed."
		  exit 1
		fi

		if [ "$1" = "logout" ]
		then
		    /usr/bin/tailscale logout $LOGOUTFLAGS ${@:2}
		    st=$?
		    exit $st
		fi

		if [ "$1" = "up" ]
		then
		  /usr/bin/tailscale up $UPFLAGS ${@:2}
		  st=$?
		  exit $st
		fi
		if [ "$1" = "down" ]
		then
		  /usr/bin/tailscale down $DOWNFLAGS ${@:2}
		  st=$?
		  exit $st
		fi

		exit 1
	EOF

    chmod 755 "${buildroot}"/usr/local/bin/tailscale.sh
}

function prepare {

    buildroot=$1

    rm -rf "${buildroot}" "${SYSEXTENSION}"

    mkdir -p "${buildroot}"/usr/bin/
    mkdir -p "${buildroot}"/usr/local/bin
    mkdir -p "${buildroot}"/usr/lib/extension-release.d
    mkdir -p "${buildroot}"/usr/lib/systemd/system/multi-user.target.wants/
    mkdir -p "${buildroot}"/usr/share/tailscale/

}

function unpack_tarball {

    buildroot=$1
    tarball=$2
    version=$3

    tar zxf "$tarball"

    cp -v tailscale_"${version}"_amd64/tailscale "${buildroot}"/usr/bin/
    cp -v tailscale_"${version}"_amd64/tailscaled "${buildroot}"/usr/bin/
}

function create_tailscale_defaults {

    buildroot=$1

    cat > "${buildroot}"/usr/share/tailscale/tailscale << EOF
#
# This is normally readonly, it can be overriden using
#
#   /etc/default/tailscale
#
# Usecases:
# During initial OS provisioning supply a BOOTSTRAPKEY
# this will give some (remote) access to the host
# allowing for further configuration before handing to
# production
#
# BOOTSTRAPKEY
#   typically an ephemeral multi-use key that will allow
#   joining a tailnet but might require an admin to
#   manually authorize connections
#
# HOSTKEY
#   is expected to be a host-specific key with whatever
#   attributes you wish (including pre-auth)
#
BOOTSTRAPKEY=$TAILSCALEKEYBOOTSTRAP

# HOSTKEY
HOSTKEY=$TAILSCALEKEYHOST

#
# Code in /usr/localbin/tailscale.sh will prefer HOSTKEY over BOOTSTRAPKEY

UPFLAGS="--ssh --accept-risk=lose-ssh"
DOWNFLAGS=""
LOGINFLAGS=""
LOGOUTFLAGS=""

EOF

}

function create_tailscaled_defaults {

    buildroot=$1

    cat > "${buildroot}"/usr/share/tailscale/tailscaled << EOF
# Set the port to listen on for incoming VPN packets.
# Remote nodes will automatically be informed about the new port number,
# but you might want to configure this in order to set external firewall
# settings.
PORT="41641"

# Extra flags you might want to pass to tailscaled.
FLAGS=""
EOF

}

function create_tailscale_services {

    buildroot=$1

    cat > "${buildroot}"/usr/lib/systemd/system/tailscale-login.service << EOF
[Unit]
Description=Tailscale Login
Documentation=https://tailscale.com/kb/
Wants=tailscaled.target systemd-sysext.service
After=systemd-sysext.service tailscaled.service tailscaled.service
Requires=systemd-sysext.service tailscaled.service

[Service]
Type=oneshot
RemainAfterExit=True
#
# /usr/local/bin/tailscale.sh handles all configuration
# by reading /usr/share/tailscale/tailscale and /etc/default/tailscale
# and supports conditional expansion
#
ExecStart=/usr/local/bin/tailscale.sh login
ExecStop=/usr/local/bin/tailscale.sh logout
Restart=never
RuntimeDirectory=tailscale
RuntimeDirectoryMode=0755
StateDirectory=tailscale
StateDirectoryMode=0700
CacheDirectory=tailscale
CacheDirectoryMode=0750

[Install]
WantedBy=multi-user.target

EOF
    ln -s ../tailscale-login.service "${buildroot}"/usr/lib/systemd/system/multi-user.target.wants/tailscale-login.service

    cat > "${buildroot}"/usr/lib/systemd/system/tailscale-up.service << EOF
[Unit]
Description=Tailscale Up
Documentation=https://tailscale.com/kb/
Wants=tailscaled.target
After=systemd-sysext.service tailscaled.service tailscaled.service
Requires=systemd-sysext.service tailscaled.service

[Service]
Type=oneshot
RemainAfterExit=True
#
# /usr/local/bin/tailscale.sh handles all configuration
# by reading /usr/share/tailscale/tailscale and /etc/default/tailscale
# and supports conditional expansion
#
ExecStart=/usr/local/bin/tailscale.sh up
ExecStop=/usr/local/bin/tailscale.sh down
Restart=never
RuntimeDirectory=tailscale
RuntimeDirectoryMode=0755
StateDirectory=tailscale
StateDirectoryMode=0700
CacheDirectory=tailscale
CacheDirectoryMode=0750

[Install]
WantedBy=multi-user.target

EOF

    ln -s ../tailscale-up.service "${buildroot}"/usr/lib/systemd/system/multi-user.target.wants/tailscale-up.service

}

function create_tailscaled_services {

    buildroot=$1

    cat > "${buildroot}"/usr/lib/systemd/system/tailscaled.service <<- 'EOF'
		[Unit]
		Description=Tailscale Agent
		Documentation=https://tailscale.com/kb/
		Wants=network-pre.target
		After=network-pre.target systemd-resolved.service systemd-sysext.service
		Requires=systemd-sysext.service

		[Service]
		EnvironmentFile=-/usr/share/tailscale/tailscaled
		EnvironmentFile=-/etc/default/tailscaled
		ExecStartPre=/usr/bin/tailscaled --cleanup
		ExecStart=/usr/bin/tailscaled --port=${PORT} $FLAGS
		ExecStopPost=/usr/bin/tailscaled --cleanup

		Restart=on-failure

		RuntimeDirectory=tailscaled
		RuntimeDirectoryMode=0755
		StateDirectory=tailscaled
		StateDirectoryMode=0700
		CacheDirectory=tailscaled
		CacheDirectoryMode=0750
		Type=notify

		[Install]
		WantedBy=multi-user.target

	EOF

    ln -s ../tailscaled.service "${buildroot}"/usr/lib/systemd/system/multi-user.target.wants/tailscaled.service

}

function create_metadata {

    buildroot=$1

    cat > "${buildroot}"/usr/lib/extension-release.d/extension-release.tailscale-"${TAILSCALEVER}" << EOF
ID=flatcar
SYSEXT_LEVEL=1.0
EOF
}

function create_squashfs {

    buildroot=$1
    outpath=$2

    find "${buildroot}" -ls

    mksquashfs "${buildroot}" "${outpath}" -reproducible -all-root -info -no-progress -noappend

}

function build_extension {

    h2 "Building extension for tailscale $TAILSCALEVER"

    echo "TAILSCALE_BOOTSTRAP_KEY=$TAILSCALEKEYBOOTSTRAP"
    echo "TAILSCALE_AUTHORIZED_KEY=$TAILSCALEKEYHOST"
    echo ""

    prepare build-root-"${SAFE}"

    unpack_tarball build-root-"${SAFE}" "${TAILSCALETARBALL}" "${TAILSCALEVER}"

    create_tailscale_helper build-root-"${SAFE}"

    create_tailscale_defaults build-root-"${SAFE}"

    create_tailscaled_defaults build-root-"${SAFE}"

    create_tailscale_services build-root-"${SAFE}"

    create_tailscaled_services build-root-"${SAFE}"

    create_metadata build-root-"${SAFE}"

    create_squashfs build-root-"${SAFE}" "${SYSEXTENSION}"

}

################################################################
#
# standard argument parsing - ArgBash
#

die() {
    local _ret="${2:-1}"
    test "${_PRINT_HELP:-no}" = yes && print_help >&2
    echo "$1" >&2
    exit "${_ret}"
}

# shellcheck disable=SC2317
begins_with_short_option() {
    local first_option all_short_options='ph'
    first_option="${1:0:1}"
    test "$all_short_options" = "${all_short_options/$first_option/}" && return 1 || return 0
}

_arg_tarball=""
_arg_extension=""
_arg_tailscale_ver=""
_arg_bootstrap_key=""
_arg_host_key=""

# shellcheck disable=SC2317
print_help() {
    printf 'Usage: %s [--tarball <arg>] [--extension <arg>] [--bootstrap-key <key>] ... [-h|--help]\n' "$0"
    printf '  %s\n' "--tarball=TGZ           : Path to (local) Tailscale TGZ"
    printf '  %s\n' "--extension=RAW         : Path to created extension "
    printf '  %s\n' "--tailscale-version=VER : Override parsing of verson from tarball"
    printf '  %s\n' "--bootstrap-key=KEY     : Use KEY as BOOTSTRAPKEY"
    printf '  %s\n' "--host-key=KEY          : Use KEY as HOSTKEY"
    printf '  %s\n' "-h, --help              : Prints help"

    printf '\n'
    printf 'BOOTSTRAPKEY\n'
    printf '  Typically a reusable key that will allow\n'
    printf '  joining a tailnet but might require an administrator\n'
    printf '  to manually authorize connections\n'

    printf '\n'
    printf 'HOSTKEY\n'
    printf '  Typically a long-lived single host key with whatever\n'
    printf '  attributes you wish (including pre-auth)\n'

    printf '\n'
    printf '\n'
    printf 'During initial OS provisioning you can supply a BOOTSTRAPKEY\n'
    printf 'this will give some (remote) access to the host allowing\n'
    printf 'for further configuration before transfer into production\n'

}

# shellcheck disable=SC2317
parse_commandline() {
    while test $# -gt 0; do
        _key="$1"
        case "$_key" in
            --tarball)
                test $# -lt 2 && die "Missing value for the optional argument '$_key'." 1
                _arg_tarball="$2"
                shift
                ;;
            --tarball=*)
                _arg_tarball="${_key##--tarball=}"
                ;;
            --extension)
                test $# -lt 2 && die "Missing value for the optional argument '$_key'." 1
                _arg_extension="$2"
                shift
                ;;
            --extension=*)
                _arg_extension="${_key##--extension=}"
                ;;
            --bootstrap-key)
                test $# -lt 2 && die "Missing value for the optional argument '$_key'." 1
                _arg_bootstrap_key="$2"
                shift
                ;;
            --bootstrap-key=*)
                _arg_bootstrap_key="${_key##--bootstrap-key=}"
                ;;
            --host-key)
                test $# -lt 2 && die "Missing value for the optional argument '$_key'." 1
                _arg_host_key="$2"
                shift
                ;;
            --host-key=*)
                _arg_host_key="${_key##--host-key=}"
                ;;
            --tailscale-version)
                test $# -lt 2 && die "Missing value for the optional argument '$_key'." 1
                _arg_tailscale_ver="$2"
                shift
                ;;
            --tailscale-version=*)
                _arg_tailscale_ver="${_key##--tailscale-version=}"
                ;;
            -h | --help)
                print_help
                exit 0
                ;;
            -h*)
                print_help
                exit 0
                ;;
            *)
                _PRINT_HELP=yes die "FATAL ERROR: Got an unexpected argument '$1'" 1
                ;;
        esac
        shift
    done
}

parse_commandline "$@"

TAILSCALETARBALL="$_arg_tarball"
SYSEXTENSION="$_arg_extension"
# INSTALLER BOOTSTRAP KEY and INSTALLER_HOST_KEY are macros that may be expanded as part
# of inserting this script into an OS installer
TAILSCALEKEYBOOTSTRAP=${_arg_bootstrap_key:-INSTALLER_BOOTSTRAP_KEY}
TAILSCALEKEYHOST=${_arg_host_key:-INSTALLER_HOST_KEY}
# shellcheck disable=SC2001
TAILSCALEVER="${_arg_tailscale_ver:-$(echo "$TAILSCALETARBALL" | sed -e 's/.*_\([0-9.]*\)_.*/\1/')}"

if [ -z "${TAILSCALEVER}" ]; then

    echo "Missing/could not parse tailscale version from tarball name"
    exit 1
fi

if [ -z "$TAILSCALEKEYBOOTSTRAP" ] || [ "$TAILSCALEKEYBOOTSTRAP" == "INSTALLER_BOOTSTRAP_KEY" ]; then
    echo ""
    # shellcheck disable=SC2034
    read -r -p "No bootstrap-key supplied. Hit <return> to continue" dummy

    # remove any reference to INSTALLER BOOTSTRAP KEY
    TAILSCALEKEYBOOTSTRAP=""
fi

if [ "$TAILSCALEKEYHOST" == "INSTALLER_HOST_KEY" ]; then
    # remove any reference to INSTALLER HOST KEY
    TAILSCALEKEYHOST=""
fi

if [ -z "${SYSEXTENSION}" ]; then

    echo "Missing destination."
    exit 1
fi

h1 "Building Tailscale Extension"

if [ "$TAILSCALETARBALL" -nt "$SYSEXTENSION" ] || [ "$0" -nt "$SYSEXTENSION" ]; then

    build_extension | log

else
    printf 'No need to build tailscale-%s extension. Up to date.' "${TAILSCALEVER}" | log
fi

exit 0
