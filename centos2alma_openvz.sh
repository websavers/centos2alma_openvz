#!/bin/bash

# Version 1.2b
# Usage: ./centos2alma_openvz.sh <CTID>

CTID=$1
AC_BIN=/root/almaconvert8-plesk
SNAPSHOT_NAME=CentOS7PleskBase

# Check OS
source /etc/os-release
[ "$NAME" != "Virtuozzo" ] && echo "This must be run on an OpenVZ node, not within the container. Exiting..." && exit 1

# Verify CTID
[ "$CTID" = "" ] && echo "The CTID paramter has NOT been provided. Exiting..." && exit 1
vzlist $CTID >/dev/null
[ ! $? -eq 0 ] && echo "CTID provided does not appear to be valid. Exiting..." && exit 1

# Even if the NAME value was provided rather than CTID, this ensures the CTID is used from now on
CTID=$(vzlist $CTID -H -o ctid)

###### FUNCTIONS BEGIN HERE ######

# Changes to node packages
function install_almaconvert { 

    if rpm -q --quiet vzdeploy8 ; then 
        #echo "Already have vzdeploy8. Skipping install..."
        echo ""
    else
        echo "Installing vzdeploy8 / almaconvert8 packages on local node..."
        yum install vzdeploy8 -y
        [ ! $? -eq 0 ] && echo "Unable to install vzdeploy8 / almaconvert8 packages. Exiting..." && exit 1
    fi

    if [ ! -f "$AC_BIN" ]; then
        echo "Creating modified version of almaconvert8 to ignore Plesk blocker checks..."
        cp /usr/bin/almaconvert8 $AC_BIN
        sed -i -e "s/BLOCKER_PKGS = {'plesk': 'Plesk', 'cpanel': 'cPanel'}/BLOCKER_PKGS = {'cpanel': 'cPanel'}/g"  $AC_BIN
    fi

}

# Changes to the container only via vzctl commands
function reinstall_mariadb {
    if ! vzctl exec $CTID grep "10.11" /etc/yum.repos.d/mariadb.repo; then
        vzctl exec $CTID curl -LsS -O https://downloads.mariadb.com/MariaDB/mariadb_repo_setup
        vzctl exec $CTID bash mariadb_repo_setup --mariadb-server-version=10.11
        vzctl exec $CTID yum -y install boost-program-options MariaDB-server MariaDB-client MariaDB-shared
        vzctl exec $CTID 'yum -y update MariaDB-server MariaDB-client MariaDB-shared MariaDB-*'
        # Restore original config
        vzctl exec $CTID mv /etc/my.cnf /etc/my.cnf.rpmnew
        vzctl exec $CTID mv /etc/my.cnf.rpmsave /etc/my.cnf
        vzctl exec $CTID systemctl restart mariadb
        vzctl exec $CTID mysql_upgrade -uadmin -p`cat /etc/psa/.psa.shadow`
    fi
}

function ct_prepare {

    echo "Creating snapshot prior to any changes..."
    vzctl snapshot $CTID --name $SNAPSHOT_NAME
    [ ! $? -eq 0 ] && echo "Snapshot failure. Exiting..." && exit 1

    echo "Saving Plesk version and components list for later restore..."
    vzctl exec $CTID mkdir /root/centos2alma
    vzctl exec $CTID 'cat /etc/plesk-release | sed -n "1p" | sed -r "s/^([[:digit:]]+\.[[:digit:]]+\.[[:digit:]]+).*/\1/" > /root/centos2alma/plesk_version'
    vzctl exec $CTID 'plesk installer list PLESK_18_0_60 --components 2>&1 | grep -E "upgrade|up2date" | awk "{print \$1}" > /root/centos2alma/plesk_components'

    echo "Creating database backup..."
    vzctl exec $CTID 'if [ -f /etc/psa/.psa.shadow ]; then mysqldump -uadmin -p$(cat /etc/psa/.psa.shadow) -f --events --max_allowed_packet=1G --opt --all-databases 2> /root/all_databases_error.log | gzip --rsyncable > /root/all_databases_dump.sql.gz && if [ -s /root/all_databases_error.log ]; then cat /root/all_databases_error.log | mail -s "mysqldump errors for $(hostname)" reports@websavers.ca; fi fi'; 

    vzctl exec $CTID systemctl stop mariadb

    echo "Removing packages that conflict with the almaconvert8 conversion process, including Plesk RPMs..."
    vzctl exec $CTID rpm -e btrfs-progs --nodeps
    vzctl exec $CTID rpm -e python3-pip --nodeps
    vzctl exec $CTID rpm -e psa-phpmyadmin --nodeps
    vzctl exec $CTID yum -y remove "plesk-*"
    vzctl exec $CTID rpm -e openssl11-libs --nodeps
    vzctl exec $CTID rpm -e psa-mod_proxy --nodeps
    vzctl exec $CTID rpm -e MariaDB-server MariaDB-client MariaDB-shared MariaDB-common MariaDB-compat --nodeps
    vzctl exec $CTID rpm -e python36-PyYAML --nodeps

}

function ct_convert {

    $AC_BIN convert $CTID --log /root/almaconvert8-$CTID.log
    echo ""
    echo ""

}

# Changes to the container only via vzctl commands
function ct_finish {

    vzctl exec $CTID yum -y install python3 perl-Net-Patricia
    vzctl exec $CTID sed -i -e 's/CentOS-7/RedHat-el8/g' /etc/yum.repos.d/plesk*
    vzctl exec $CTID yum -y update 

    reinstall_mariadb

    # Reload Plesk DB from backup
    #vzctl exec $CTID 'zcat /var/lib/psa/dumps/mysql.plesk.core.prerm.`cat /root/centos2alma/plesk_version`.`date "+%Y%m%d"`-*dump.gz | MYSQL_PWD=`cat /etc/psa/.psa.shadow` mysql -uadmin'
    
    # Restore all databases from backup (this is done because psa and phpmyadmin dbs are removed)
    echo "Restoring MariaDB databases..."
    vzctl exec $CTID 'zcat /root/all_databases_dump.sql.gz | MYSQL_PWD=`cat /etc/psa/.psa.shadow` mysql -uadmin'

    echo "Reinstalling base Plesk packages..."

    vzctl exec $CTID 'PLESK_V=`cat /root/centos2alma/plesk_version` && echo "[PLESK-base]
name=PLESK base
baseurl=http://autoinstall.plesk.com/PSA_$PLESK_V/dist-rpm-RedHat-el8-x86_64/
enabled=1
gpgcheck=1
" > /etc/yum.repos.d/plesk-base-tmp.repo'

    vzctl exec $CTID yum -y install plesk-release plesk-engine plesk-completion psa-autoinstaller psa-libxml-proxy plesk-repair-kit plesk-config-troubleshooter psa-updates psa-phpmyadmin

    echo "Reinstalling Plesk components..."
    vzctl exec $CTID plesk installer install-all-updates
    vzctl exec $CTID plesk installer remove --components nginx
    vzctl exec $CTID 'plesk installer add --components `cat /root/centos2alma/plesk_components | grep -v config-troubleshooter`'
    #vzctl exec $CTID plesk installer add --components roundcube modsecurity nginx bind postfix dovecot resctrl php7.4 php8.0 php8.1 php8.2 php8.3
    
    echo "Fixing nginx config..."
    vzctl exec $CTID cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
    vzctl exec $CTID cp /etc/nginx/nginx.conf.rpmsave /etc/nginx/nginx.conf
    vzctl exec $CTID plesk sbin nginxmng -e

    echo "Running Plesk Repair..."
    vzctl exec $CTID plesk repair installation

    echo "Cleaning up..."
    vzctl exec $CTID rm -f /etc/yum.repos.d/plesk-base-tmp.repo
    vzctl exec $CTID yum -y remove firewalld

}

# Changes to the container only via vzctl commands
function ct_revert {

    SNAP_ID=$(vzctl snapshot-list $CTID -H -o UUID,NAME | grep $SNAPSHOT_NAME | sed -n '1p' | awk '{print $1}')
    echo "Reverting CTID $CTID to snapshot ID $SNAP_ID ..."
    vzctl snapshot-switch $CTID --id $SNAP_ID
    [ ! $? -eq 0 ] && echo "Failure switching to snapshot $SNAP_ID - Exiting..." && exit 1
    vzctl snapshot-delete $CTID --id $SNAP_ID
    vzctl start $CTID

}

function ct_check {

    install_almaconvert
    can_convert=$(almaconvert8 list | grep $CTID)
    [ "$can_convert" = "" ] && echo "$CTID can *not* be converted to almalinux 8." && exit 1
    echo "$CTID can be converted to almalinux 8."

}

#### STANDARD PROCESSING BEGINS HERE ####

while test $# -gt 0
do
    case "$1" in
         --prepare) echo "Prepare parameter provided. Running only pre-conversion (destructive) changes..."
            ct_prepare
            exit 0
            ;;
         --convert) echo "Convert parameter provided. Running only conversion (destructive) changes..."
            ct_convert
            exit 0
            ;;
        --finish) echo "Finish parameter provided. Running only post-conversion repairs..."
            ct_finish
            exit 0
            ;;
        --revert) echo "Revert parameter provided. Doing reversion to CentOS7 snapshot..."
            ct_revert
            exit 0
            ;;
        --check) echo "Check parameter provided. Checking if container can be converted..."
            ct_check
            exit 0
            ;;
        #--*) echo "bad option $1"
        #    ;;
        #*) echo "argument $1"
        #    ;;
    esac
    shift
done

# Install and modify necessary utilities
install_almaconvert

read -p "The following process will convert CTID $CTID to AlmaLinux 8 (destructive changes). Are you sure you're ready to proceed? (y/n) " -n 1 -r
echo
if ! [[ $REPLY =~ ^[Yy]$ ]] ; then
    exit
fi

echo "STAGE 1: Preparing container for conversion..."
ct_prepare

echo "STAGE 2: Conversion begins using almaconvert8. Do not interrupt unless failure reported."
ct_convert

echo "STAGE 3: Post-Conversion Repairs..."
ct_finish

echo "Conversion completed!"