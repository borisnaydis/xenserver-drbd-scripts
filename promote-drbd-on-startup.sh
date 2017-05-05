#!/bin/bash
PATH=$PATH:/bin:/sbin:/opt/xensource/bin

#echo 1 > /sys/devices/system/cpu/cpu1/online
while grep sync /proc/drbd > /dev/null 2>&1
do
    sleep 5
done

HOST_NAME=$(hostname)
SR_AUTOSTART_TAG="drbd_primary $HOST_NAME"
IFS=',' read -ra SR_NAME_LIST < <(xe sr-list tags:contains="$SR_AUTOSTART_TAG" params=name-label --minimal)

############################################
# Function drbdGetResourceByDevice
# finds name of DRBD resource by device name
# 
# Args passed in:
# Arg1 = device name (e.g. /dev/drbd1)
############################################
drbdGetResourceByDevice() {
    DRBD_RESOURCE_LIST=($(drbd-overview | awk -F'[/: ]+' '{ print $3}'))
    
    for ENTRY in ${DRBD_RESOURCE_LIST[*]}; do
        DRBD_MINOR=$(drbd-overview | grep $ENTRY | awk -F: '{ print $1 }' | sed 's\^  \\')
        if [[ $(echo "/dev/drbd$DRBD_MINOR") == $1 ]]; then
            echo "$ENTRY"
        fi
    done
} #end of drbdGetResourceByDevice function

drbdGetCurrentStatus() {
    read DRBD_STATUS DRBD_LOCAL_ROLE DRBD_REMOTE_ROLE VG_NAME < <(drbd-overview | grep $DRBD_RESOURCE_NAME | awk -F'[/: ]+' '{ print $5 " " $6 " " $7 " " $13}')
}


for SR_NAME in ${SR_NAME_LIST[*]}; do
    PBD_UUID=$(xe pbd-list sr-name-label=$SR_NAME host-name-label=$HOST_NAME --minimal)
    PBD_DEVICE=$(xe pbd-param-get uuid=$PBD_UUID param-name=device-config | sed 's\device: \\')
    DRBD_RESOURCE_NAME=$(drbdGetResourceByDevice $PBD_DEVICE)

    drbdGetCurrentStatus
    if [[ $DRBD_STATUS == "Connected" ]]; then
        if [[ $DRBD_LOCAL_ROLE == "Secondary" ]]; then
            if [[ $DRBD_REMOTE_ROLE == "Primary" ]]; then
                #drbdadm net-options --protocol=C --allow-two-primaries $DRBD_RESOURCE_NAME
                KOKO="koko"
            fi
            drbdadm primary $DRBD_RESOURCE_NAME
            drbdGetCurrentStatus
            vgchange -ay $VG_NAME
            xe pbd-plug uuid=$PBD_UUID
        elif [[ $DRBD_LOCAL_ROLE == "Primary" ]]; then
            if [[ $DRBD_REMOTE_ROLE == "Primary" ]]; then
                KOKO="koko"
            else
                echo "Current role of remote host is $DRBD_REMOTE_ROLE. Should be Primary for demoting of local host."
            fi
        else
            echo "Current role of local host is $DRBD_LOCAL_ROLE. Should be Secondary for promoting."
        fi
    else
        echo "Current status is $DRBD_STATUS. Should be Connected for changing role."
    fi
    
done
