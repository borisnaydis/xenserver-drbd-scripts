#!/bin/bash

HOST_NAME=$(hostname)
HOST_UUID=$(xe host-list name-label=$HOST_NAME --minimal)
IFS=',' read -ra SR_NAME_LIST < <(xe sr-list type=lvm shared=true params=name-label --minimal)

#Placeholder for menu test. Remove after testing.
#IFS=',' read -ra SR_NAME_LIST < <(xe sr-list params=name-label --minimal)

OPTIONS=(${SR_NAME_LIST[*]})

menu() {
    clear
    echo ""
    echo "------------SR status------------"
    for ENTRY in ${SR_NAME_LIST[*]}; do
        SR_NAME=$ENTRY
        PBD_UUID=$(xe pbd-list sr-name-label=$SR_NAME host-name-label=$HOST_NAME --minimal)
        PBD_STATUS=$(xe pbd-list uuid=$PBD_UUID params=currently-attached --minimal)
        echo "[SR name]:$SR_NAME  [PBD]:$PBD_UUID  [Attached]:$PBD_STATUS"
    done
    unset SR_NAME PBD_UUID PBD_STATUS
    echo "---------------------------------"
    echo ""
    echo "-----------DRBD status-----------"
    drbd-overview
    echo "---------------------------------"
    if [[ $MESSAGE ]]; then
        echo ""
        echo "$MESSAGE"
    fi
    echo ""
    echo "Choose what SR to (un)plug:"
    for i in ${!OPTIONS[@]}; do
        echo "  $(($i+1)) ) ${OPTIONS[i]}"
    done

}

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

plugUnplugSR() {
    SR_NAME=${SR_NAME_LIST[(INPUT-1)]}
    SR_UUID=$(xe sr-list name-label=$SR_NAME --minimal)
    PBD_UUID=$(xe pbd-list sr-name-label=$SR_NAME host-name-label=$HOST_NAME --minimal)
    PBD_STATUS=$(xe pbd-list uuid=$PBD_UUID params=currently-attached --minimal)
    PBD_DEVICE=$(xe pbd-param-get uuid=$PBD_UUID param-name=device-config | sed 's\device: \\')
    #Probably it is bad assumption that suspend SR and SR used by VM will always be the same SR, but that is best that I could find at the moment.
    RESIDENT_VMS=($(xe vm-list is-control-domain=false resident-on=$HOST_UUID suspend-SR-uuid=$SR_UUID params=name-label --minimal))
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
            xe sr-param-add uuid=$SR_UUID param-name=tags param-key="drbd_primary $HOST_NAME"
        elif [[ $DRBD_LOCAL_ROLE == "Primary" ]]; then
            if [[ $DRBD_REMOTE_ROLE == "Primary" ]]; then
                if [[ $RESIDENT_VMS ]];then
                    echo "$RESIDENT_VMS are using this SR ($SR_NAME) on this host ($HOST_NAME). Migrate, suspend or shutdown them before unplugging."
                else
                    xe sr-param-remove uuid=$SR_UUID param-name=tags param-key="drbd_primary $HOST_NAME"
                    xe pbd-unplug uuid=$PBD_UUID
                    vgchange -an $VG_NAME
                    drbdadm secondary $DRBD_RESOURCE_NAME
                    drbdGetCurrentStatus
                    #drbdadm net-options --protocol=C --allow-two-primaries=no $DRBD_RESOURCE_NAME
                fi
            else
                echo "Current role of remote host is $DRBD_REMOTE_ROLE. Should be Primary for demoting of local host."
            fi
        else
            echo "Current role of local host is $DRBD_LOCAL_ROLE. Should be Primary for demoting or Secondary for promoting."
        fi
    else
        echo "Current status is $DRBD_STATUS. Should be Connected for changing role."
    fi
}




PROMPT="Choose an option (screen refreshes every 10 seconds, press 'Ctrl+C' to exit): "
while true; do
    menu && read -rp "$PROMPT" -t 10 INPUT
    
    #Check for correctness of input value
    if [[ $INPUT =~ "^[0-9]+$" ]] && (( $INPUT <= ${#OPTIONS[@]} )); then
        #MESSAGE=$(drdbChangeStatus)
        MESSAGE=$(plugUnplugSR)
        echo 'Unplugging'
    #Message for refresh
    elif [[ -z ${INPUT+x} ]];then
        MESSAGE=""
        echo -e "Refreshing screen"
    else
        MESSAGE="Wrong value"
    fi

    unset INPUT
    sleep 0.5
done
