# Usage

Check to be sure the container is recognized as convertible by almaconvert8:
`./centos2alma_openvz.sh <CTID> --check`

If all is well, begin conversion:
`./centos2alma_openvz.sh <CTID>`

During the run of almaconvert8 you will probably see the followin warnings. Ones about Plesk repos can be safely ignored:
> Warning! Unsupported repositories detected

IMPORTANT: Once you have confirmed the conversion has been successul and you do not need to reset to the CentOS 7 snapshot, run these commands to delete the snapshots created by this process:
```
CTID=put_ctid_here
vzctl snapshot-list $CTID
# You probably need to do this part twice:
SNAP_ID=put_snapshot_id_here
vzctl snapshot-delete $CTID --id $SNAP_ID
```

You may also wish to remove old centos7 packages within the container. Here's some we found:
```
yum remove python-inotify python-dateutil pyxattr pyparsing alt-nghttp2 yum-metadata-parser python-gobject-base python-kitchen python-ply mozjs17 python-pycurl python-urlgrabber dbus-python python-iniparse python-enum34 python-decorator python-IPy pyliblzma pygpgme nginx-filesystem
```

You can run the following to see ones you have installed still:
```
rpm -qa | grep el7
```
Note: anything that says el7_9 is used in versions 7 through 9

## SolusVM
For those using SolusVM, run these on your master to update the OS name. Be sure to replace HOSTNAME with the actual hostname of the container.
```
bash /root/solusvmdb.sh
update vservers set templatename="almalinux-8-x86_64-ez" where hostname="HOSTNAME";
```

## WHMCS
For those using WHMCS, you will want to adjust the OS template configurable option there as well.

## Logging

Logs from almaconvert8 will be stored in /root/almaconvert8-$CTID.log

# Reverting to snapshot
In the event of failure, there are two snapshots you can revert to:

1. The first is taken before any changes are made at all, and
2. The second is taken by the almaconvert8 utility *after* conflicting packages are removed, but before the actual conversion occurs.

To revert to the first/earliest snapshot, simply run:
`./centos2alma_openvz.sh $CTID --revert`

To revert to the second one, run this to get their IDs:
```
CTID=put_ctid_here
vzctl snapshot-list $CTID
```

Run this to save the ID of the snapshot you want to restore to:
`SNAP_ID=put_snapshot_id_here`

Then switch to that snapshot and start the container:
```
vzctl snapshot-switch $CTID --id $SNAP_ID
vzctl start $CTID
```

Once you have confirmed the container is back to the original state, delete the snapshot:
`vzctl snapshot-delete $CTID --id $SNAP_ID`

# Troubleshooting

You can run each stage of this separately, so if any one part fails, you can re-run just that stage or start from the next if you've fixed the issue manually. Here are the stages:

Check if the almaconvert8 utility says it can be converted:
```
./centos2alma_openvz.sh <CTID> --check
```

Snapshot and remove conflicting packages like Plesk and MariaDB:
```
./centos2alma_openvz.sh <CTID> --prepare
```

Run almaconvert8 (also creates a snapshot of its own):
```
./centos2alma_openvz.sh <CTID> --convert
```

After conversion, reinstall MariaDB and Plesk packages and restore configurations:
```
./centos2alma_openvz.sh <CTID> --finish
```


Note: if Germany is blocked in firewall, the almalinux GPG key will fail to download.

# References

- almaconvert8: https://docs.virtuozzo.com/virtuozzo_hybrid_server_7_users_guide/advanced-tasks/converting-containers-with-almaconvert8.html
- Plesk Forum thread: https://talk.plesk.com/threads/upgrade-virtuozzo-container-from-centos-7.369729/