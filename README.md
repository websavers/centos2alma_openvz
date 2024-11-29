# Preparation / Requirements

**PHP <7.1**: This script will switch any sites using PHP earlier than 7.1 to PHP 7.1 (which is required for AlmaLinux 8), however the reliability of that switch hasn't been confirmed. We recommend switching the sites manually prior to conversion so you can check to ensure the sites are compatible. If you're using 3rd party PHP versions of 7.0 or lower, you'll likely need to reinstall those after, then switch the sites back manually.

**OpenVZ <7.0.21**: We have tested and confirmed the conversion process works with:
- OpenVZ 7.0.21 (Virtuozzo Hybrid Server 7.5 Update 6 Hotfix 1 - Version 7.5.6-112)
- OpenVZ 7.0.22
- Plesk 17.0.60
- Plesk 17.0.65
- CentOS 7.9 stock
- CentOS 7.9 with Tuxcare Repos (Nov 2024, version 1.7) 

Any version of OpenVZ or Virtuozzo older than what's noted above is not likely to work. You should update all packages on both the node and the container prior to conversion. 

# Usage

Check to be sure the container is recognized as convertible by almaconvert8:
`./centos2alma_openvz.sh $CTID --check`

If all is well, begin conversion:
`./centos2alma_openvz.sh $CTID`

During the run of almaconvert8 you will probably see the following warnings. Ones about Plesk repos can be safely ignored:
> Warning! Unsupported repositories detected

Logs from almaconvert8 will be stored in /root/almaconvert8-$CTID.log

The process takes approximately 35 minutes on a server with just 1 domain. Perhaps an additional 10 minutes when many domains.

## After Conversion

The following sections are actions you might wish to take after conversion.

### Re-enable IP Address Banning / Fail2ban?

If you had it enabled prior to conversion, you should re-enable it now: `systemctl restart fail2ban`

### Removing snapshots after successful conversion

IMPORTANT: Once you have confirmed the conversion has been successul and you do not need to reset to the CentOS 7 snapshot, run these commands to delete the snapshots created by this process:
```
CTID=put_ctid_here
vzctl snapshot-list $CTID
# You probably need to do this part twice:
SNAP_ID=put_snapshot_id_here
vzctl snapshot-delete $CTID --id $SNAP_ID
```

### TuxCare Licenses

We remove the TuxCare repos to ensure everything works smoothly after conversion, however you will likely want to ensure to cancel any
such licenses, whether through Plesk or TuxCare/CloudLinux directly. Note: in our testing, Plesk *appears* to automatically cancel any TuxCare licenses through them upon license refresh.

### Old Packages

You may also wish to remove old centos7 packages within the container. Here's some we found:
```
yum remove python-inotify python-dateutil pyxattr pyparsing alt-nghttp2 yum-metadata-parser python-gobject-base python-kitchen python-ply mozjs17 python-pycurl python-urlgrabber dbus-python python-iniparse python-enum34 python-decorator python-IPy pyliblzma pygpgme nginx-filesystem
```

You can run the following to see ones you have installed still:
```
rpm -qa | grep el7
```
Note: anything that says el7_9 is used in versions 7 through 9 and should probably remain

### Using SolusVM?

For those using SolusVM, Install their DB helper script, then run these on your master to update the OS name. Be sure to replace HOSTNAME with the actual hostname of the container.
```
curl -o /root/solusvmdb.sh https://raw.githubusercontent.com/solusvm-support/helpers/master/solusvmdb.sh
bash /root/solusvmdb.sh
update vservers set templatename="almalinux-8-x86_64-ez" where hostname="HOSTNAME";
```

### Using WHMCS?

For those using WHMCS, you will want to adjust the OS template configurable option there as well.

# Conversion Failure? Revert to snapshot

In the event of failure, there are two snapshots you can revert to:

1. The first is taken before any changes are made at all, and
2. The second is taken by the almaconvert8 utility *after* conflicting packages are removed, but before the actual conversion occurs.

To revert to the first/earliest snapshot, simply run:
`./centos2alma_openvz.sh $CTID --revert`

***IMPORTANT: this will delete all snapshots after successful reversion.***

If you wish to avoid deletion of the snapshots, please use the steps below to manually switch to the snapshot of choice.
---

To revert to the second one, run this to get their IDs:
```
CTID=put_ctid_here
vzctl snapshot-list $CTID
```

Run this to save the ID of the snapshot you want to restore to:
`SNAP_ID=put_snapshot_id_here`

Then switch to that snapshot and start the container:
```
vzctl snapshot-switch $CTID --id $SNAP_ID --skip-resume
vzctl start $CTID
```

Once you have confirmed the container is back to the original state, delete the snapshot:
`vzctl snapshot-delete $CTID --id $SNAP_ID`

# Troubleshooting Tips

### If the almalinux GPG key fails to download

Germany is likely blocked by your firewall rules.

### If almaconvert8 fails with an error like this: 

`Failed to get VM config: The virtual machine could not be found. The virtual machine is not registered in the virtual machine directory on this server. Contact your Virtuozzo administrator for assistance.`

This means the container does not use a newer UUID CTID *and* the NAME of the container does not match the CTID. When at least one of either the UUID (longer CTIDs) or the NAME (shorter CTIDs, often resulting from a conversion from OpenVZ 6) do not match up with the CTID you've provided, prlctl fails to work on the container, which makes almaconvert8 fail since it relies upon it. To fix it run this (setting $CTID to the CTID):

`vzctl set $CTID --name=$CTID --save`

### General Troubleshooting

You can run each stage of this separately, so if any one part fails, you can re-run just that stage or start from the next if you've fixed the issue manually. Here are the stages:

Check if the almaconvert8 utility says it can be converted:
```
./centos2alma_openvz.sh $CTID --check
```

Snapshot and remove conflicting packages like Plesk and MariaDB:
```
./centos2alma_openvz.sh $CTID --prepare
```

Run almaconvert8 (also creates a snapshot of its own):
```
./centos2alma_openvz.sh $CTID --convert
```

After conversion, reinstall MariaDB and Plesk packages and restore configurations:
```
./centos2alma_openvz.sh $CTID --finish
```

# References
- almaconvert8: https://docs.virtuozzo.com/virtuozzo_hybrid_server_7_users_guide/advanced-tasks/converting-containers-with-almaconvert8.html
- centos2alma Plesk repo issue: https://github.com/plesk/centos2alma/issues/87
- Plesk Forum thread: https://talk.plesk.com/threads/upgrade-virtuozzo-container-from-centos-7.369729/