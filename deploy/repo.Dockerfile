# Builds the TimeTagger API server from the repo.
# The build context must be the root of the repo. Used by CI for the ghcr image.
# Runs as an unprivileged user (UID 1000).

FROM eclipse-temurin:25-jdk AS build
WORKDIR /src
COPY server /src
RUN ./gradlew --no-daemon -q fatJar

FROM eclipse-temurin:25-jre
RUN groupadd -g 1000 timetagger && useradd -r -u 1000 -m -g timetagger timetagger
COPY --from=build /src/build/libs/timetagger.jar /opt/timetagger/timetagger.jar
USER 1000
WORKDIR /opt/timetagger
ENTRYPOINT ["java", "-jar", "/opt/timetagger/timetagger.jar"]
