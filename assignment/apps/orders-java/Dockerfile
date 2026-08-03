# Build stage. Dependencies are resolved in their own layer so that editing
# source does not re-download the Maven world on every rebuild.
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /build
COPY pom.xml .
RUN mvn -B -q dependency:go-offline
COPY src ./src
RUN mvn -B -q clean package -DskipTests

# Runtime stage. JRE only, and the same UID/GID (10001:2000) the Python image
# uses so the chart's securityContext and any shared EFS access point apply
# unchanged to both languages.
FROM eclipse-temurin:21-jre-alpine

RUN addgroup -g 2000 appgroup \
    && adduser -D -H -u 10001 -G appgroup appuser

WORKDIR /app
COPY --from=build --chown=10001:2000 /build/target/orders-java.jar /app/app.jar

USER 10001:2000
EXPOSE 8080

# MaxRAMPercentage makes the JVM size its heap from the container memory limit
# rather than from the host's total RAM, which is what makes a 768Mi limit
# survivable. UseSerialGC keeps GC overhead sane on a 1-CPU request.
#
# Deliberately no -XX:TieredStopAtLevel=1 here. It is a common container flag
# for faster startup, but it caps JIT compilation at C1 and costs several times
# the throughput on hot loops — including this service's own SQL work. Crippling
# the JIT of the application whose performance you are trying to observe would
# make every JavaMelody number a measurement of the flag.
ENTRYPOINT ["java", \
  "-XX:MaxRAMPercentage=70.0", \
  "-XX:+UseSerialGC", \
  "-Djava.security.egd=file:/dev/./urandom", \
  "-jar", "/app/app.jar"]
