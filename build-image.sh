#!/bin/bash

set -Eeuo pipefail

# Image to build. Update this once the target Quay namespace is settled; the demo is
# currently running quay.io/mregan/*-arm64 images.
IMAGE="${IMAGE:-quay.io/mregan/train-ceq-app-arm64}"
TAG="${TAG:-latest}"
PLATFORM="${PLATFORM:-linux/arm64/v8}"

# Maven runs in a container so that no JDK or Maven install is needed on the host.
# Note this repository ships mvnw but not .mvn/wrapper, so ./mvnw does not work here.
MAVEN_IMAGE="${MAVEN_IMAGE:-docker.io/library/maven:3.9-eclipse-temurin-17}"
M2_DIR="${M2_DIR:-$HOME/.m2}"

cd "$(dirname "$0")"

# Cache dependencies between runs, otherwise every build re-downloads the world.
mkdir -p "$M2_DIR"

echo "Packaging with $MAVEN_IMAGE ..."
podman run --rm \
    -v "$PWD":/project:z \
    -v "$M2_DIR":/root/.m2:z \
    -w /project \
    "$MAVEN_IMAGE" mvn clean package

podman build -f src/main/docker/Dockerfile.jvm -t "quarkus/train-ceq-app-jvm" --platform "$PLATFORM" .
podman tag "quarkus/train-ceq-app-jvm:latest" "${IMAGE}:${TAG}"

echo "Built ${IMAGE}:${TAG}"

# Pushing is opt-in so that running this script cannot publish by accident.
if [ "${PUSH:-0}" = "1" ]; then
    podman push "${IMAGE}:${TAG}"
    echo "Pushed ${IMAGE}:${TAG}"
else
    echo "Not pushed. Re-run with PUSH=1 to publish."
fi
