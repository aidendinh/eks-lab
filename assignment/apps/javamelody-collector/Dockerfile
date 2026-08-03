# The JavaMelody project publishes the collector server as a WAR on GitHub
# Releases but does not publish an official container image. The third-party
# images on Docker Hub are unmaintained and years behind, so this builds one
# from the official artifact instead — two lines, and the provenance is clear.
FROM eclipse-temurin:21-jre AS fetch
ARG JAVAMELODY_VERSION=2.8.0
ADD https://github.com/javamelody/javamelody/releases/download/javamelody-core-${JAVAMELODY_VERSION}/javamelody-collector-server-${JAVAMELODY_VERSION}.war /tmp/collector.war

FROM eclipse-temurin:21-jre

RUN groupadd -g 2000 appgroup \
    && useradd -u 10001 -g 2000 -M -s /usr/sbin/nologin appuser

WORKDIR /app
COPY --from=fetch --chown=10001:2000 /tmp/collector.war /app/collector-server.war

USER 10001:2000
EXPOSE 8080

# The WAR is executable (embedded servlet container). Everything the collector
# needs is a writable storage directory for the RRD files it aggregates; the
# Deployment mounts an emptyDir at /tmp for that.
ENTRYPOINT ["java", \
  "-XX:MaxRAMPercentage=70.0", \
  "-Djavamelody.storage-directory=/tmp/javamelody-collector", \
  "-Djava.security.egd=file:/dev/./urandom", \
  "-jar", "/app/collector-server.war"]
