# Both profiles share split routes, DNS handling, and saved credentials.
function _vpn-switch-ready() {
    local service=$1 attempt policy_route public_route
    for attempt in {1..45}; do
        systemctl is-active --quiet "$service" || return 1
        policy_route=$(ip -4 route show table 10077 2>/dev/null)
        public_route=$(ip -4 route get 1.1.1.1 2>/dev/null)
        if [[ "$policy_route" == *'default via '*'dev tunmgid'* \
            && "$public_route" == *'dev enp1s0f0'* ]]; then
            return 0
        fi
        sleep 1
    done
    print -u2 'VPN routes did not become ready within 45 seconds.'
    return 1
}

function vpn-switch() {
    local target=${1:-status}
    local eu_service=openvpn-client@mgid-eu-split.service
    local ua_service=openvpn-client@mgid-ua-split.service
    local dns_service=mgid-vpn-domain-routing.service
    local helper_service=devbox-vpn.service
    local desired previous='' opposite profile switch_result

    if (( $# > 1 )); then
        print -u2 'Usage: vpn-switch [eu|ua|off|status]'
        return 2
    fi

    case "$target" in
        status)
            if systemctl is-active --quiet "$eu_service"; then
                print 'VPN: EU (split routing)'
            elif systemctl is-active --quiet "$ua_service"; then
                print 'VPN: UA (split routing)'
            elif systemctl is-active --quiet "$helper_service"; then
                print 'VPN: legacy helper is running'
            elif pgrep -x openvpn >/dev/null; then
                print 'VPN: another OpenVPN client is running'
            else
                print 'VPN: disconnected'
            fi
            return 0
            ;;
        eu|ua|off) ;;
        -h|--help)
            print 'Usage: vpn-switch [eu|ua|off|status]'
            print 'EU and UA use the same split routing and saved credentials.'
            return 0
            ;;
        *)
            print -u2 'Usage: vpn-switch [eu|ua|off|status]'
            return 2
            ;;
    esac

    if [[ "$target" == off ]]; then
        sudo -n systemctl stop "$eu_service" "$ua_service" "$helper_service" "$dns_service" || return $?
        if pgrep -x openvpn >/dev/null; then
            print -u2 'An OpenVPN client outside the managed services is still running.'
            return 1
        fi
        print 'VPN: disconnected'
        return 0
    fi

    desired="openvpn-client@mgid-$target-split.service"
    if systemctl is-active --quiet "$desired"; then
        _vpn-switch-ready "$desired" || return $?
        print "VPN: ${(U)target} split is already running"
        return 0
    fi

    for profile in eu ua; do
        if systemctl is-active --quiet "openvpn-client@mgid-$profile-split.service"; then
            previous="openvpn-client@mgid-$profile-split.service"
            break
        fi
    done

    if [[ "$target" == eu ]]; then
        opposite=$ua_service
    else
        opposite=$eu_service
    fi

    # Wait for the previous client to release the shared tunnel interface.
    # NOPASSWD sudo is already configured; -n prevents an unexpected prompt.
    sudo -n systemctl stop "$opposite" "$helper_service" || return $?
    sudo -n systemctl start "$desired"
    switch_result=$?
    if (( switch_result == 0 )); then
        _vpn-switch-ready "$desired"
        switch_result=$?
    fi
    if (( switch_result != 0 )); then
        sudo -n systemctl stop "$desired" || return $?
        if [[ -n "$previous" ]]; then
            print -u2 'Connection failed; restoring the previous VPN.'
            if ! sudo -n systemctl start "$previous" || ! _vpn-switch-ready "$previous"; then
                print -u2 'Could not restore the previous VPN; check its service status.'
            fi
        fi
        return "$switch_result"
    fi

    print "VPN: ${(U)target} split connected"
}
