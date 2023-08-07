#!/bin/bash

KMS_VER=6.18.0
KMS_IMAGE=kurento/kurento-media-server-birdseye:$KMS_VER

UBUNTU_VER=bionic

CLEAN=""

if [ $1 = "clean" ] 
then
  CLEAN="--pull --rm --no-cache"
fi

echo Building $KMS_IMAGE for Ubuntu $UBUNTU_VER ...

docker build $CLEAN \
	--build-arg UBUNTU_CODENAME=$UBUNTU_VER \
	--build-arg KMS_VERSION=$KMS_VER \
	--tag $KMS_IMAGE .
	