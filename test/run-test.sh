#!/bin/bash

REDIS_PASSWORD=flubber
NUM_FOLLOWERS=50
ROADBLOCK_TIMEOUT=120
STAGE_1_DOCKER_FILE=client.test.stage1.dockerfile
STAGE_1_UPDATE_DOCKER_FILE=client.test.stage1.update.dockerfile
STAGE_2_DOCKER_FILE=client.test.stage2.dockerfile
STAGE_1_IMAGE_NAME=fedora-redis-python-client
STAGE_2_IMAGE_NAME=roadblock-client-test
MESSAGE_LOG="/tmp/roadblock.message.log"
POD_NAME=roadblock-test
BUILD=1
UPDATE=0
ABORT_TEST=0
TIMEOUT_TEST=0
RANDOMIZE_INITIATOR=1
#ROADBLOCK_DEBUG=" --debug "

# goto the root of the repo
REPO_DIR=$(dirname $0)/../
if pushd ${REPO_DIR} > /dev/null; then

    if [ "${BUILD}" == 1 ]; then
	echo -e "\nBuilding the container infrastructure"

	if [ -z "$(podman images --quiet localhost/${STAGE_1_IMAGE_NAME})" ] ; then
	    echo -e "\nBuilding the stage 1 container image"
	    if ! buildah bud -t ${STAGE_1_IMAGE_NAME} -f utilities/containers/${STAGE_1_DOCKER_FILE} ${REPO_DIR}; then
		echo "ERROR: Could not build stage 1 container image"
		exit 1
	    fi
	else
	    if [ "${UPDATE}" == 1 ]; then
		echo -e "\nUpdating the stage 1 container image"
		if ! buildah bud -t ${STAGE_1_IMAGE_NAME} -f utilities/containers/${STAGE_1_UPDATE_DOCKER_FILE} ${REPO_DIR}; then
		    echo "ERROR: Could not update stage 1 container image"
		    exit 2
		fi
	    fi
	fi

	if [ -n "$(podman images --quiet localhost/${STAGE_2_IMAGE_NAME})" ]; then
	    echo -e "\nRemoving stale stage 2 container image"
	    if ! buildah rmi localhost/${STAGE_2_IMAGE_NAME}; then
		echo "ERROR: Could not remove stale stage 2 container image"
		exit 9
	    fi
	fi

	echo -e "\nBuilding the stage 2 container image"
	if ! buildah bud -t ${STAGE_2_IMAGE_NAME} -f utilities/containers/${STAGE_2_DOCKER_FILE} ${REPO_DIR}; then
	    echo "ERROR: Could not build stage 2 container image"
	    exit 8
	fi

	# get the redis database container from the registry
	if ! podman pull docker.io/centos/redis-5-centos7; then
	    echo "ERROR: Could not pull the redis database container"
	    exit 3
	fi
    else
	echo -e "\nSkipping container infrastructure build"
    fi

    echo -e "\nStarting the roadblock test"

    # create a pod to place all the containers into
    echo -e "\nCreating roadblock pod"
    if ! podman pod create --name=${POD_NAME} --infra=false; then
	echo "ERROR: Could not create the pod"
	exit 6
    fi
    
    # start the redis database container
    echo -e "\nStarting the redis database container"
    if ! podman run --detach=true --name=redis_database --pod=${POD_NAME} -e REDIS_PASSWORD=${REDIS_PASSWORD} docker.io/centos/redis-5-centos7; then
	echo "ERROR: Could not start the redis database container"
	exit 4
    fi

    REDIS_IP_ADDRESS=$(podman inspect --format "{{.NetworkSettings.IPAddress}}" redis_database)

    # start the redis monitor container
    echo -e "\nStarting the redis monitor container"
    if ! podman run --detach=true --interactive=true --tty=true --name=redis_monitor --pod=${POD_NAME} localhost/${STAGE_2_IMAGE_NAME} -c \
	"/opt/roadblock/redis-monitor.py --redis-server=${REDIS_IP_ADDRESS} --redis-password=${REDIS_PASSWORD}"; then
	echo "ERROR: Could not start the redis monitor container"
	exit 10
    fi

    ROADBLOCK_UUID=$(uuidgen)
    FOLLOWERS=""
    FOLLOWER_PREFIX="roadblock_follower"
    LEADER_ID="roadblock_leader"

    for i in $(seq 1 ${NUM_FOLLOWERS}); do
	FOLLOWERS+="--followers=${FOLLOWER_PREFIX}_${i} "
    done

    # start the roadblock leader container
    echo -e "\nStarting the roadblock leader container"
    SLEEP_TIME=0
    if [ "${RANDOMIZE_INITIATOR}" == "1" ]; then
	SLEEP_TIME=$((RANDOM%20))
    fi
    if ! podman run --detach=true --interactive=true --tty=true --name=roadblock_leader --pod=${POD_NAME} localhost/${STAGE_2_IMAGE_NAME} -c \
	 "sleep ${SLEEP_TIME}; /opt/roadblock/roadblock.py --uuid=${ROADBLOCK_UUID} --role=leader --redis-server=${REDIS_IP_ADDRESS} --redis-password=${REDIS_PASSWORD} ${FOLLOWERS} \
	 --timeout=${ROADBLOCK_TIMEOUT} --leader-id=${LEADER_ID} --message-log=${MESSAGE_LOG} --user-messages=/opt/roadblock/user-messages.json ${ROADBLOCK_DEBUG}; \
         echo -e \"\nRoadblock Message Log\"; cat ${MESSAGE_LOG}"; then
	echo "ERROR: Could not start the roadblock leader container"
	exit 5
    fi

    # start the roadblock follower container(s)
    for i in $(seq 1 ${NUM_FOLLOWERS}); do
	ABORT=""
	if [ "${i}" == "1" ]; then
	    if [ "${ABORT_TEST}" == "1" ]; then
		ABORT=" --abort "
	    fi
	    if [ "${TIMEOUT_TEST}" == "1" ]; then
		continue
	    fi
	fi
	SLEEP_TIME=$((RANDOM%20))
	echo -e "\nStarting the roadblock follower ${i} container with a sleep ${SLEEP_TIME}"
	if ! podman run --detach --interactive=true --tty=true --name=${FOLLOWER_PREFIX}_${i} --pod=${POD_NAME} localhost/${STAGE_2_IMAGE_NAME} -c \
	     "sleep ${SLEEP_TIME}; /opt/roadblock/roadblock.py --uuid=${ROADBLOCK_UUID} --role=follower --follower-id=${FOLLOWER_PREFIX}_${i} --redis-server=${REDIS_IP_ADDRESS} \
	     --redis-password=${REDIS_PASSWORD} --timeout=${ROADBLOCK_TIMEOUT} --leader-id=${LEADER_ID} --message-log=${MESSAGE_LOG} --user-messages=/opt/roadblock/user-messages.json ${ROADBLOCK_DEBUG} ${ABORT}; \
             echo -e \"\nRoadblock Message Log\"; cat ${MESSAGE_LOG}"; then
	    echo "ERROR: Could not start roadblock follower ${i}"
	    echo "       This will cause a timeout to occur"
	fi
    done

    # wait for the roadblock leader container to exit
    echo -e -n "\nWaiting for the roadblock to complete"
    while true; do
	if podman ps --all --format "{{.Status}}" -f name=roadblock_leader | grep -q "^Exited"; then
	    break
	fi
	echo -n "."
	sleep 1
    done
    echo

    # get the roadblock leader container log
    echo -e "\nOutput from the roadblock leader:"
    podman logs -t roadblock_leader

    # get the roadblock follower container(s) log
    echo -e "\nOutput from the roadblock follower(s):"
    for i in $(seq 1 ${NUM_FOLLOWERS}); do
	echo -e "\nFollower ${i}:"
	podman logs -t ${FOLLOWER_PREFIX}_${i}
    done

    # get the redis monitor container log
    echo -e "\nOutput from the redis monitor:"
    podman logs -t redis_monitor

    # remove the roadblock leader container
    echo -e "\nRemoving the roadblock leader container"
    if ! podman rm roadblock_leader; then
	echo "ERROR: Failed to remove the roadblock leader container"
    fi

    # remove the roadblock follower container(s)
    for i in $(seq 1 ${NUM_FOLLOWERS}); do
	echo -e "\nRemoving the roadblock follower container ${i}"
	if ! podman rm ${FOLLOWER_PREFIX}_${i}; then
	    echo "ERROR: Failed to remove the roadblock follower ${i} container"
	fi
    done

    # stop the redis monitor container and remove it
    echo -e "\nStopping redis monitor container"
    if ! podman stop redis_monitor; then
	echo "ERROR: Failed to stop the redis monitor container"
    fi
    echo -e "\nRemoving the redis monitor container"
    if ! podman rm redis_monitor; then
	echo "ERROR: Failed to remove the redis monitor container"
    fi

    # stop the redis database container and remove it
    echo -e "\nStopping redis database container"
    if ! podman stop redis_database; then
	echo "ERROR: Failed to stop the redis database container"
    fi
    echo -e "\nRemoving redis database container"
    if ! podman rm redis_database; then
	echo "ERROR: Failed to remove the redis database container"
    fi

    # remove the pod and forceably cleanup any remaining containers
    echo -e "\nRemoving the roadblock pod"
    if ! podman pod rm --force ${POD_NAME}; then
	echo "ERROR: Failed to remove the roadblock pod"
	exit 7
    fi
fi
