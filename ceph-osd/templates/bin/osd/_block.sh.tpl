#!/bin/bash

{{/*
Copyright 2017 The Openstack-Helm Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/}}

source /tmp/osd-common.sh

set -ex

: "${OSD_SOFT_FORCE_ZAP:=1}"
: "${OSD_JOURNAL_DISK:=}"

if [ "x${STORAGE_TYPE%-*}" == "xdirectory" ]; then
  export OSD_DEVICE="/var/lib/ceph/osd"
else
  export OSD_DEVICE=$(readlink -f ${STORAGE_LOCATION})
fi

if [ "x$JOURNAL_TYPE" == "xdirectory" ]; then
  export OSD_JOURNAL="/var/lib/ceph/journal"
else
  export OSD_JOURNAL=$(readlink -f ${JOURNAL_LOCATION})
fi

if [[ -z "${OSD_DEVICE}" ]];then
  echo "ERROR- You must provide a device to build your OSD ie: /dev/sdb"
  exit 1
fi

if [[ ! -b "${OSD_DEVICE}" ]]; then
  echo "ERROR- The device pointed by OSD_DEVICE ${OSD_DEVICE} doesn't exist !"
  exit 1
fi

CEPH_DISK_OPTIONS=""
CEPH_OSD_OPTIONS=""
DATA_UUID=$(blkid -o value -s PARTUUID ${OSD_DEVICE}*1)

udev_settle

DATA_PART=$(dev_part ${OSD_DEVICE} 1)
MOUNTED_PART=${DATA_PART}

ceph-disk -v \
  --setuser ceph \
  --setgroup disk \
  activate ${CEPH_DISK_OPTIONS} \
    --no-start-daemon ${DATA_PART}

OSD_ID=$(grep "${MOUNTED_PART}" /proc/mounts | awk '{print $2}' | grep -oh '[0-9]*')

OSD_PATH="${OSD_PATH_BASE}-${OSD_ID}"
OSD_KEYRING="${OSD_PATH}/keyring"
# NOTE(supamatt): set the initial crush weight of the OSD to 0 to prevent automatic rebalancing
OSD_WEIGHT=0
# NOTE(supamatt): add or move the OSD's CRUSH location
crush_location

if [ "${OSD_BLUESTORE:-0}" -ne 1 ]; then
  if [ -n "${OSD_JOURNAL}" ]; then
    if [ -b "${OSD_JOURNAL}" ]; then
      OSD_JOURNAL_DISK="$(readlink -f ${OSD_PATH}/journal)"
      if [ -z "${OSD_JOURNAL_DISK}" ]; then
        echo "ERROR: Unable to find journal device ${OSD_JOURNAL_DISK}"
        exit 1
      else
        OSD_JOURNAL="${OSD_JOURNAL_DISK}"
        if [ -e "${OSD_PATH}/run_mkjournal" ]; then
          ceph-osd -i ${OSD_ID} --mkjournal
          rm -rf ${OSD_PATH}/run_mkjournal
        fi
      fi
    fi
    if [ "x${JOURNAL_TYPE}" == "xdirectory" ]; then
      OSD_JOURNAL="${OSD_JOURNAL}/journal.${OSD_ID}"
      touch ${OSD_JOURNAL}
      wait_for_file "${OSD_JOURNAL}"
    else
      if [ ! -b "${OSD_JOURNAL}" ]; then
        echo "ERROR: Unable to find journal device ${OSD_JOURNAL}"
        exit 1
      else
        chown ceph. "${OSD_JOURNAL}"
      fi
    fi
  else
    wait_for_file "${OSD_JOURNAL}"
    chown ceph. "${OSD_JOURNAL}"
  fi
fi

# NOTE(supamatt): Just in case permissions do not align up, we recursively set them correctly.
if [ $(stat -c%U ${OSD_PATH}) != ceph ]; then
  chown -R ceph. ${OSD_PATH};
fi

if [ "${OSD_BLUESTORE:-0}" -ne 1 ]; then
  # NOTE(supamatt): This function is a workaround to Ceph upstream bug #21142
  osd_pg_interval_fix
fi

if [ "x${JOURNAL_TYPE}" == "xdirectory" ]; then
  chown -R ceph. /var/lib/ceph/journal
  ceph-osd \
    --cluster ceph \
    --osd-data ${OSD_PATH} \
    --osd-journal ${OSD_JOURNAL} \
    -f \
    -i 0 \
    --setuser ceph \
    --setgroup disk \
    --mkjournal
fi

exec /usr/bin/ceph-osd \
    --cluster ${CLUSTER} \
    ${CEPH_OSD_OPTIONS} \
    -f \
    -i ${OSD_ID} \
    --setuser ceph \
    --setgroup disk & echo $! > /run/ceph-osd.pid
wait
