#!/bin/bash

# Version 2.7
# Usage: ./centos2alma_openvz.sh <CTID>

CTID=$1
AC_BIN=/root/almaconvert8-plesk
SNAPSHOT_NAME=CentOS7PleskBase

# Check OS
source /etc/os-release
[[ ${PRETTY_NAME} != *"OpenVZ"* ]] && echo "This must be run on an OpenVZ node, not within the container. Exiting..." && exit 1

# Verify CTID
[ "$CTID" = "" ] && echo "The CTID paramter has NOT been provided. Exiting..." && exit 1
vzlist $CTID >/dev/null
[ ! $? -eq 0 ] && echo "CTID provided does not appear to be valid. Exiting..." && exit 1

# Even if the NAME value was provided rather than CTID, this ensures the CTID is used from now on
CTID=$(vzlist $CTID -H -o ctid | awk '{print $1}')

function main {

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

    CT_HOSTNAME=$(vzctl exec $CTID hostname)

    read -p "The following process will convert CTID $CTID with hostname $CT_HOSTNAME to AlmaLinux 8 (destructive changes). Are you sure you're ready to proceed? (y/n) " -n 1 -r
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

}

# Changes to node packages
function install_almaconvert { 

    echo "Installing latest vzdeploy8 / almaconvert8 packages on local node..."
    #yum -y install vzdeploy8
    yum -y install  https://repo.virtuozzo.com/vzlinux/vzdeploy/vzdeploy8.rpm
    #[ ! $? -eq 0 ] && echo "Unable to install vzdeploy8 / almaconvert8 packages. Exiting..." && exit 1

    vzdeploy8version=$(rpm -q vzdeploy8)

    # If our modified version already exists AND it's the most recent version of vzdeploy8, we're good to go
    if [ -f "$AC_BIN" ]; then
        if grep "$vzdeploy8version" $AC_BIN; then
            echo "Already using latest version of vzdeploy/almaconvert8! Continuing..."
            echo "----------------------------------------------"
            return 0
        fi
    fi

    # If our modified version doesn't exist OR it's older, create anew.
    echo "Creating modified version of almaconvert8..."
    cat /usr/bin/almaconvert8 > $AC_BIN
    chmod u+x $AC_BIN
    # Version it
    sed -i "2i # $vzdeploy8version" $AC_BIN
    # Remove Plesk from blocked packages
    sed -i -e "s/BLOCKER_PKGS = {'plesk': 'Plesk', 'cpanel': 'cPanel'}/BLOCKER_PKGS = {'cpanel': 'cPanel'}/g"  $AC_BIN
    # Always return an empty array in get_open_ports function because lsof's return value can break the whole conversion unnecessarily
    sed -i '/def get_open_ports/a \ \ \ \ return []' $AC_BIN

}

# Changes to the container only via vzctl commands
function reinstall_mariadb {
    if ! vzctl exec2 $CTID 'grep "10.11" /etc/yum.repos.d/mariadb.repo'; then
        vzctl exec $CTID curl -LsS -O https://downloads.mariadb.com/MariaDB/mariadb_repo_setup
        vzctl exec $CTID bash mariadb_repo_setup --mariadb-server-version=10.11
    fi 

    vzctl exec $CTID 'yum -y install boost-program-options MariaDB-server MariaDB-client MariaDB-shared'
    vzctl exec $CTID 'yum -y update MariaDB-server MariaDB-client MariaDB-shared MariaDB-*'

    # Restore original config
    if [ -f "/vz/root/$CTID/etc/my.cnf.rpmsave" ]; then
        vzctl exec $CTID mv /etc/my.cnf /etc/my.cnf.rpmnew
        vzctl exec $CTID mv /etc/my.cnf.rpmsave /etc/my.cnf
    fi
    # Fix bind-address syntax (now comma separated with 10.11)
    vzctl exec $CTID 'sed -i "/^bind-address/s/::ffff:127.0.0.1/::ffff,127.0.0.1/" /etc/my.cnf'

    echo "Restarting MariaDB..."
    vzctl exec2 $CTID systemctl restart mariadb
    [ ! $? -eq 0 ] && echo "MariaDB daemon not running. Exiting..." && exit 1
}

function ct_prepare {

    echo "Creating snapshot prior to any changes..."
    vzctl snapshot $CTID --name $SNAPSHOT_NAME
    [ ! $? -eq 0 ] && echo "Snapshot failure. Exiting..." && exit 1

    echo "Stopping mail services..."
    vzctl exec $CTID 'systemctl stop postfix dovecot'

    echo "Switching all domains on PHP versions older than 7.1 to version 7.1..."
    vzctl exec2 $CTID '
    for DOMAIN in $(plesk db -Ne "SELECT name FROM hosting hos,domains dom WHERE dom.id = hos.dom_id AND php = \"true\" AND php_handler_id LIKE \"plesk-php5%\""); do
        plesk bin domain -u $DOMAIN -php_handler_id plesk-php71-fpm
    done
    for DOMAIN in $(plesk db -Ne "SELECT name FROM hosting hos,domains dom WHERE dom.id = hos.dom_id AND php = \"true\" AND php_handler_id LIKE \"plesk-php70-%\""); do
        plesk bin domain -u $DOMAIN -php_handler_id plesk-php71-fpm
    done'

    echo "Removing PHP 5.x and 7.0"
    vzctl exec $CTID 'plesk installer remove --components php5.5 php5.6 php7.0'

    echo "Saving Plesk version and components list for later restore..."
    vzctl exec $CTID mkdir /root/centos2alma
    vzctl exec $CTID 'cat /etc/plesk-release | sed -n "1p" | sed -r "s/^([[:digit:]]+\.[[:digit:]]+\.[[:digit:]]+).*/\1/" > /root/centos2alma/plesk_version'
    vzctl exec $CTID 'cat /root/centos2alma/plesk_version | sed -r "s/\./_/g" > /root/centos2alma/plesk_version_underscores'
    # config-troubleshooter component has spacing issues, so ignore it
    vzctl exec $CTID 'plesk installer list PLESK_$(cat /root/centos2alma/plesk_version_underscores) --components 2>&1 | grep -E "upgrade|up2date" | grep -v "config-troubleshooter" | awk "{print \$1}" > /root/centos2alma/plesk_components'
    [ ! $? -eq 0 ] && echo "Error generating Plesk components list. Exiting..." && exit 1

    echo "Creating a backup of all databases at /root/all_databases_dump.sql.gz"
    vzctl exec $CTID '[ -f /etc/psa/.psa.shadow ] && mysqldump -uadmin -p$(cat /etc/psa/.psa.shadow) -f --events --max_allowed_packet=1G --opt --all-databases 2> /root/all_databases_error.log | gzip --rsyncable > /root/all_databases_dump.sql.gz'; 

    vzctl exec $CTID systemctl stop mariadb

    echo "Removing packages that conflict with the almaconvert8 conversion process, including Plesk RPMs..."
    vzctl exec $CTID rpm -e btrfs-progs --nodeps
    vzctl exec $CTID rpm -e python3-pip --nodeps
    vzctl exec $CTID rpm -e psa-phpmyadmin --nodeps
    vzctl exec $CTID yum -y remove "plesk-*"
    vzctl exec $CTID rpm -e openssl11-libs --nodeps
    vzctl exec $CTID rpm -e psa-mod_proxy --nodeps
    vzctl exec $CTID rpm -e lcms2-devel 
    vzctl exec $CTID rpm -e jasper-devel 
    vzctl exec $CTID rpm -e ilmbase-devel OpenEXR-devel
    vzctl exec $CTID rpm -e libpcap-devel 
    vzctl exec $CTID rpm -e MariaDB-server MariaDB-client MariaDB-shared MariaDB-common MariaDB-compat --nodeps
    # Old/stock verisons of mariadb
    vzctl exec $CTID yum -y remove mariadb-server mariadb-client mariadb-shared mariadb-common mariadb-compat mariadb-gssapi-server mariadb-connector-c mariadb-connector-c-config
    vzctl exec $CTID rpm -e python36-PyYAML --nodeps
    vzctl exec $CTID rpm -e fail2ban --nodeps
    vzctl exec $CTID yum -y remove "tomcat-*"
    # Remi Repo Conflicts:
    vzctl exec $CTID rpm -e libwebp7 libzip5 --nodeps
    # Plesk fail2ban dependencies:
    vzctl exec $CTID rpm -e python-inotify --nodeps
    vzctl exec $CTID rpm -e python2-inotify --nodeps
    # Plesk Kolab dependencies:
    vzctl exec $CTID 'yum -y remove erlang-*'
    # Plesk unknown dependencies that mess with reinstall in --finish:
    vzctl exec $CTID rpm -e xmlrpc-c xmlrpc-c-c++ --nodeps
    vzctl exec $CTID rpm -e file-devel --nodeps
    vzctl exec $CTID rpm -e libgs-devel --nodeps
    vzctl exec $CTID rpm -e docker-ce docker-ce-rootless-extras

    # Convert fails when there's a broken symlink to templates, so remove it ahead of time
    TEMPLATES_PATH=/vz/private/$CTID/templates
    if [ -L ${TEMPLATES_PATH} ] ; then
        if [ -e ${TEMPLATES_PATH} ] ; then
            echo "CT Templates symlink exists, ok to proceed normally"
        else
            echo "CT Templates symlink broken, removing it so almaconvert8 can create it properly..."
            rm -f ${TEMPLATES_PATH}
        fi
    fi

    echo "Prepare phase completed."
    echo "========================"
    echo ""

}

function ct_convert {

    if [[ $(vzctl exec2 $CTID 'rpm -qa | grep -E "^plesk-.*"') ]]; then
        echo "rpm shows plesk-* packages are still installed. You likely need to run --prepare still. Exiting..." && exit 1
    fi

    $AC_BIN convert $CTID --log /root/almaconvert8-$CTID.log
    [ ! $? -eq 0 ] && echo "Failure running almaconvert8 - Exiting... to try again from here, use --convert and --finish options" && exit 1

    # Detect when almaconvert8 has screwed up royally by failing to install almalinux packages and attempt repair
    vzctl exec2 $CTID 'grep -q "AlmaLinux release" /etc/redhat-release'
    if [ ! $? -eq 0 ]; then
        echo "AlmaLinux not found. Virtuozzo conversion failed and didn't tell us. Attempting to fix it..."
        vzctl exec2 $CTID 'grep -q "Virtuozzo" /etc/redhat-release'
        if [ $? -eq 0 ]; then
            vzctl exec $CTID rpm -e vzlinux-release --nodeps
            vzctl exec $CTID rpm -Uvh http://mirror.its.dal.ca/almalinux/8.10/BaseOS/x86_64/os/Packages/almalinux-release-8.10-1.el8.x86_64.rpm

            echo "Disable Plesk repo (it will be recreated in the next phase) and update Plesk extension repos"
            vzctl exec $CTID mv /etc/yum.repos.d/plesk.repo /etc/yum.repos.d/plesk.repo.old
            vzctl exec $CTID sed -i -e 's/CentOS-7/RedHat-el8/g' /etc/yum.repos.d/plesk-*.repo

            echo "Disable mariadb repo in case it's v10.4 or earlier (which don't exist anymore)"
            vzctl exec $CTID mv /etc/yum.repos.d/mariadb.repo /etc/yum.repos.d/mariadb.repo.old

            echo "Removing TuxCare and Plesk Migrator Repos (if utilized)"
            vzctl exec $CTID 'rm -f /etc/yum.repos.d/centos7-els*'
            vzctl exec $CTID 'rm -f /etc/yum.repos.d/plesk-migrator.repo'

            vzctl exec $CTID yum -y update --skip-broken
            # Swap all vl8 packages for al8 packages
            vzctl exec $CTID yum -y distro-sync --disablerepo=epel --skip-broken
            if [ ! $? -eq 0 ]; then
                echo "Manual conversion from vzlinux8 to almalinux8 failed during distro-sync. See readme for assistance." && exit 1
            fi

            vzctl exec2 $CTID 'grep -q "AlmaLinux release" /etc/redhat-release'
            if [ ! $? -eq 0 ]; then
                echo "Repair attempt failed. Exiting... " && exit 1
            else
                echo "Repair completed - AlmaLinux detected! Continuing..."
            fi
        fi
    else
        echo "Disable Plesk repo (it will be recreated in the next phase) and update extension repos"
        vzctl exec $CTID mv /etc/yum.repos.d/plesk.repo /etc/yum.repos.d/plesk.repo.old
        vzctl exec $CTID sed -i -e 's/CentOS-7/RedHat-el8/g' /etc/yum.repos.d/plesk-*.repo

        echo "Removing TuxCare and Plesk Migrator Repos (if utilized)"
        vzctl exec $CTID 'rm -f /etc/yum.repos.d/centos7-els*'
        vzctl exec $CTID 'rm -f /etc/yum.repos.d/plesk-migrator.repo'
    fi

    echo "Convert phase completed."
    echo "========================"
    echo ""

}

# Changes to the container only via vzctl commands
function ct_finish {

    vzctl exec $CTID systemctl stop grafana-server firewalld

    echo "Replacing plesk.repo with version without PHP 5.x"
    vzctl exec $CTID 'PLESK_VER=$(cat /root/centos2alma/plesk_version) && PLESK_VER_USCORES=$(cat /root/centos2alma/plesk_version_underscores) && 
echo "
## Persistent repositories for Plesk Products.

[PLESK_$PLESK_VER_USCORES-extras]
name=PLESK_$PLESK_VER_USCORES extras
baseurl=http://autoinstall.plesk.com/PSA_$PLESK_VER/extras-rpm-RedHat-el8-x86_64/
enabled=1
gpgcheck=1

[PLESK_17_PHP71]
name=PHP 7.1
baseurl=http://autoinstall.plesk.com/pool/PHP_7.1.33_98/dist-rpm-CentOS-8-x86_64/
enabled=1
gpgcheck=1

[PLESK_17_PHP72]
name=PHP 7.2
baseurl=http://autoinstall.plesk.com/pool/PHP_7.2.34_151/dist-rpm-CentOS-8-x86_64/
enabled=1
gpgcheck=1

[PLESK_17_PHP73]
name=PHP 7.3
baseurl=http://autoinstall.plesk.com/pool/PHP_7.3.33_248/dist-rpm-CentOS-8-x86_64/
enabled=1
gpgcheck=1

[PLESK_17_PHP74]
name=PHP 7.4
baseurl=http://autoinstall.plesk.com/PHP74_17/dist-rpm-RedHat-el8-x86_64/
enabled=1
gpgcheck=1

[PLESK_17_PHP80]
name=PHP 8.0
baseurl=http://autoinstall.plesk.com/PHP80_17/dist-rpm-RedHat-el8-x86_64/
enabled=1
gpgcheck=1

[PLESK_17_PHP81]
name=PHP 8.1
baseurl=http://autoinstall.plesk.com/PHP81_17/dist-rpm-RedHat-el8-x86_64/
enabled=1
gpgcheck=1

[PLESK_17_PHP82]
name=PHP 8.2
baseurl=http://autoinstall.plesk.com/PHP82_17/dist-rpm-RedHat-el8-x86_64/
enabled=1
gpgcheck=1

[PLESK_17_PHP83]
name=PHP 8.3
baseurl=http://autoinstall.plesk.com/PHP83_17/dist-rpm-RedHat-el8-x86_64/
enabled=1
gpgcheck=1
" > /etc/yum.repos.d/plesk.repo'

    # If there's a plesk docker repo, update it for CentOS 8 packages
    vzctl exec $CTID "sed -i 's#centos/7#centos/8#g' /etc/yum.repos.d/plesk.repo/plesk-ext-docker.repo"

    # Should replace Tuxcare BIND packages with those in AL8 repo
    vzctl exec $CTID 'yum -y install bind-9.11.36'

    # Remi repo conflicts with Plesk reinstall
    vzctl exec $CTID 'yum -y remove libargon2 libgs'

    echo "Repairing epel repo..."
    vzctl exec $CTID 'grep "Enterprise Linux 7" /etc/yum.repos.d/epel.repo >/dev/null && mv /etc/yum.repos.d/epel.repo /etc/yum.repos.d/epel.repo.old && mv /etc/yum.repos.d/epel.repo.rpmnew /etc/yum.repos.d/epel.repo'

    echo "Reinstalling necessary packages..."
    vzctl exec $CTID yum -y install python3 perl-Net-Patricia perl-Razor-Agent
    vzctl exec $CTID yum -y update

    [ ! $? -eq 0 ] && echo "Yum failure - Exiting..." && exit 1

    echo "Reinstalling MariaDB..."
    reinstall_mariadb

    # Reload Plesk DB from backup
    echo "Restoring Plesk Database..."
    vzctl exec $CTID 'zcat /var/lib/psa/dumps/mysql.plesk.core.prerm.`cat /root/centos2alma/plesk_version`.`date "+%Y%m%d"`-*dump.gz | MYSQL_PWD=`cat /etc/psa/.psa.shadow` mysql -uadmin'
    [ ! $? -eq 0 ] && echo "Failure restoring Plesk database (psa) - Exiting..." && exit 1

    # Restore all databases from backup (this is done because psa and phpmyadmin dbs are removed)
    #echo "Restoring MariaDB databases..."
    #vzctl exec2 $CTID '[ ! -d "/varlib/mysql/psa" ] && zcat /root/all_databases_dump.sql.gz | MYSQL_PWD=`cat /etc/psa/.psa.shadow` mysql -uadmin'
    #[ ! $? -eq 0 ] && echo "Failure restoring databases - Exiting..." && exit 1

    vzctl exec $CTID 'mysql_upgrade -uadmin -p`cat /etc/psa/.psa.shadow`'    

    echo "Reinstalling base Plesk packages..."

    vzctl exec $CTID 'PLESK_V=`cat /root/centos2alma/plesk_version` && echo "[PLESK-base]
name=PLESK base
baseurl=http://autoinstall.plesk.com/PSA_$PLESK_V/dist-rpm-RedHat-el8-x86_64/
#baseurl=http://autoinstall.plesk.com/pool/PSA_18.0.60_14244/dist-rpm-RedHat-el8-x86_64/
enabled=1
gpgcheck=1
" > /etc/yum.repos.d/plesk-base-tmp.repo'

    vzctl exec2 $CTID 'yum -y install plesk-release plesk-engine plesk-completion psa-autoinstaller psa-libxml-proxy plesk-repair-kit plesk-config-troubleshooter psa-updates psa-phpmyadmin'
    [ ! $? -eq 0 ] && echo "Failure with Plesk yum repository - Exiting..." && exit 1

    echo "Reinstalling Plesk components..."
    vzctl exec $CTID 'plesk installer install-all-updates'
    vzctl exec $CTID 'plesk installer add --components `cat /root/centos2alma/plesk_components | grep -v -E "(config-troubleshooter|php5\.6|php7\.0)"` --debug'
    vzctl exec $CTID 'plesk installer add --components php8.1 php8.2 php8.3'

    echo "Fixing phpMyAdmin..."
    # https://www.plesk.com/kb/support/plesk-repair-installation-shows-warning-phpmyadmin-was-configured-without-configuration-storage-in-database/
    vzctl exec $CTID 'plesk db "use mysql; DROP USER phpmyadmin@localhost; drop database phpmyadmin;"'
    vzctl exec $CTID 'systemctl restart mariadb && rpm -e --nodeps psa-phpmyadmin && plesk installer update'

    echo "Restoring roundcube config file..."
    vzctl exec $CTID 'pushd /usr/share/psa-roundcube/config/ && [ -f "config.inc.php.rpmsave" ] && mv -f config.inc.php config.inc.new && cp -f config.inc.php.rpmsave config.inc.php && popd'    
    
    echo "Restoring nginx and modsec config..."
    vzctl exec $CTID 'plesk installer remove --components nginx'
    vzctl exec $CTID 'plesk installer add --components nginx'
    vzctl exec $CTID '[ -f "/etc/nginx/nginx.conf.rpmsave" ] && mv -f /etc/nginx/nginx.conf /etc/nginx/nginx.conf.new && cp /etc/nginx/nginx.conf.rpmsave /etc/nginx/nginx.conf'
    vzctl exec $CTID '[ -f "/etc/httpd/conf.d/security2.conf.rpmsave" ] && cp -f /etc/httpd/conf.d/security2.conf.rpmsave /etc/httpd/conf.d/security2.conf'
    vzctl exec $CTID 'plesk sbin nginxmng --disable && plesk sbin nginxmng --enable'

    # https://support.plesk.com/hc/en-us/articles/12377651410839-Unable-to-start-Apache-on-a-Plesk-server-AH02093-mod-watchdog-is-required
    vzctl exec $CTID 'sed -i '/mod_watchdog.so/s/^#//g' /etc/httpd/conf.modules.d/00-base.conf'

    echo "Restoring PHP configs. (Note: you'll likely see failed to restart errors. This is normal.)"
    vzctl exec $CTID '
    PHP_VERSIONS="7.0 7.1 7.2 7.3 7.4 8.0 8.1 8.2 8.3"
    for ver in $PHP_VERSIONS; do
        if [ -f "/opt/plesk/php/$ver/etc/php.ini.rpmsave" ]; then
            pushd /opt/plesk/php/$ver/etc/
            mv php.ini php.ini.new && cp php.ini.rpmsave php.ini
            popd
        fi
        handler_ver=$(echo $ver | sed "s/\.//")
        systemctl restart plesk-php$handler_ver-fpm
    done'

    echo "Running Full Plesk Repairs..."
    vzctl exec $CTID 'plesk repair installation'

    echo "Running Plesk FS Repairs..."
    vzctl exec $CTID 'plesk repair fs -y'

    echo "Running php-fpm handlers Repairs..."
    vzctl exec $CTID 'plesk repair web -y -php-handlers'
    
    echo "Enable Mod_Security / WAF..."
    vzctl exec $CTID plesk bin server_pref --update-web-app-firewall -waf-rule-engine on

    # If using Imunify360
    if [[ $(vzctl exec $CTID 'systemctl | grep imunify360') ]]; then
        echo "Repairing Imunify360..."
        vzctl exec $CTID 'wget http://repo.imunify360.cloudlinux.com/defence360/i360deploy.sh -O /root/i360deploy.sh && bash /root/i360deploy.sh'
        vzctl exec $CTID 'yum -y remove firewalld'
    fi
    
    # If using Plesk Firewall
    if [[ $(vzctl exec $CTID 'grep -q "psa-firewall" /root/centos2alma/plesk_components') ]]; then
        vzctl exec $CTID 'yum -y remove firewalld'
        echo "WARNING: Please check that Plesk Firewall is currently active from Plesk UI."
    fi

    # Since Plesk enables this on new installs and it's better for security, enable it now
    #echo "Enabling apache listen only on localhost mode..."
    #vzctl exec $CTID 'plesk bin apache --listen-on-localhost true'

    echo "Starting Grafana Server, if previously installed..."
    vzctl exec $CTID systemctl start grafana-server

    # If using Installatron
    vzctl exec $CTID 'if [ -f "/usr/local/installatron/repair" ]; then
    cd /usr/local/installatron/bin
    mv run run.bak
    mv php php.bak
    ln -s /opt/plesk/php/8.3/bin/php run
    ln -s /opt/plesk/php/8.3/bin/php php
    /usr/local/installatron/repair -f --quick
    fi'

    echo "Cleaning up..."
    vzctl exec $CTID 'rm -f /etc/yum.repos.d/plesk-base-tmp.repo'

    echo "Finish phase completed."
    echo "========================"
    echo ""

}

# Changes to the container only via vzctl commands
function ct_revert {

    SNAP_ID=$(vzctl snapshot-list $CTID -H -o UUID,NAME | grep $SNAPSHOT_NAME | sed -n '1p' | awk '{print $1}')
    echo "Reverting CTID $CTID to snapshot ID $SNAP_ID ..."
    vzctl snapshot-switch $CTID --id $SNAP_ID --skip-resume
    [ ! $? -eq 0 ] && echo "Failure switching to snapshot $SNAP_ID - Exiting..." && exit 1
    vzctl snapshot-delete $CTID --id $SNAP_ID
    # Also remove the one created by almaconvert8 utility
    SNAP_ID_ALMACONVERT=$(vzctl snapshot-list $CTID -H -o UUID,NAME | grep Pre-Almalinux8 | sed -n '1p' | awk '{print $1}')
    vzctl snapshot-delete $CTID --id $SNAP_ID_ALMACONVERT
    vzctl start $CTID

}

function ct_check {

    install_almaconvert
    can_convert=$($AC_BIN list | grep $CTID)
    if [ "$can_convert" = "" ]; then 
        echo "almaconvert8 says $CTID can NOT be converted to AlmaLinux 8..."
        echo "But: part of the 'almaconvert8 list' command is just looking to see if the template name ends with centos-7-x86_64 or centos-7. Therefore, you can try changing the template name in the CT config file (/vz/private/$CTID/ve.conf) to match that pattern."
        exit 1
    fi
    echo "$CTID can be converted to AlmaLinux 8."
    echo "----------------------------------------------"

    netfilter=$(grep "NETFILTER" /vz/private/$CTID/ve.conf)
    if [[ -z "$netfilter" ]]; then # empty
        echo "Warning: NETFILTER not set for $CTID - this could result in firewall/iptables issues"
    fi
    if [[ "$netfilter" != *"full"* ]]; then
        echo "Warning: NETFILTER not set to 'full' for $CTID - this could result in firewall/iptables issues"
    fi

}

# call function main
main $@