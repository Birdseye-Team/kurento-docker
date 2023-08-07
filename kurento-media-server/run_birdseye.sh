#!/bin/bash

KMS_VER=6.18.0
KMS_IMAGE=kurento/kurento-media-server-birdseye:$KMS_VER
KMS_NAME=${1:-kms-jemalloc}

echo Running $KMS_IMAGE as $KMS_NAME ...
docker run --name $KMS_NAME \
	--rm \
	--network host \
	$KMS_IMAGE
	