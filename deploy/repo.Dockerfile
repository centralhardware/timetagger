# Builds the TimeTagger API server from the repo.
# The build context must be the root of the repo. Used by CI for the ghcr image.
# Runs as an unprivileged user (UID 1000).

# The build output is plain JVM bytecode, so it is built once on the runner's own platform
# rather than again under QEMU for arm64, which took ~9 minutes.
FROM --platform=$BUILDPLATFORM eclipse-temurin:25-jdk AS build
WORKDIR /src
COPY server /src
RUN --mount=type=cache,target=/root/.gradle ./gradlew --no-daemon -q installDist

FROM eclipse-temurin:25-jre
# Ubuntu-based images ship a user "ubuntu" with UID 1000; replace it.
RUN (userdel -r ubuntu 2>/dev/null || true) && groupadd -g 1000 timetagger && useradd -r -u 1000 -m -g timetagger timetagger
COPY --from=build /src/build/install/timetagger /opt/timetagger
USER 1000
WORKDIR /opt/timetagger
ENV PATH="/opt/timetagger/bin:$PATH"
ENTRYPOINT ["timetagger"]
