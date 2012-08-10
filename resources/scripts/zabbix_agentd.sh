#!/bin/sh /etc/rc.common
# Copyright (C) 2008-2011 OpenWrt.org
START=60

SERVICE_PID_FILE=/var/run/zabbix/zabbix_agentd.pid

group_add() {
        local name="$1"
        local gid="$2"
        local rc
        [ -f "${IPKG_INSTROOT}/etc/group" ] || return 1
        [ -n "$IPKG_INSTROOT" ] || lock /var/lock/group
        echo "${name}:x:${gid}:" >> ${IPKG_INSTROOT}/etc/group
        rc=$?
        [ -n "$IPKG_INSTROOT" ] || lock -u /var/lock/group
        return $rc
}

group_exists() {
        grep -qs "^${1}:" ${IPKG_INSTROOT}/etc/group
}

user_add() {
        local name="${1}"
        local uid="${2}"
        local gid="${3:-$2}"
        local desc="${4:-$1}"
        local home="${5:-/var/run/$1}"
        local shell="${6:-/bin/false}"
        local rc
        [ -f "${IPKG_INSTROOT}/etc/passwd" ] || return 1
        [ -n "$IPKG_INSTROOT" ] || lock /var/lock/passwd
        echo "${name}:x:${uid}:${gid}:${desc}:${home}:${shell}" >> ${IPKG_INSTROOT}/etc/passwd
        echo "${name}:x:0:0:99999:7:::" >> ${IPKG_INSTROOT}/etc/shadow
        rc=$?
        [ -n "$IPKG_INSTROOT" ] || lock -u /var/lock/passwd
        return $rc
}

user_exists() {
        grep -qs "^${1}:" ${IPKG_INSTROOT}/etc/passwd
}

start() {
	[ -f /etc/zabbix_agentd.conf ] || return 1
	user_exists zabbix 53 || user_add zabbix 53
	group_exists zabbix 53 || group_add zabbix 53
	[ -d /var/log/zabbix ] || {
		mkdir -m0755 -p /var/log/zabbix
		chown zabbix:zabbix /var/log/zabbix
	}
	[ -d /var/run/zabbix ] || {
		mkdir -m0755 -p /var/run/zabbix
		chown zabbix:zabbix /var/run/zabbix
	}
        start-stop-daemon -S -x /usr/sbin/zabbix_agentd
}

stop() {
	start-stop-daemon -K -x /usr/sbin/zabbix_agentd
}
