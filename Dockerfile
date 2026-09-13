# syntax=docker/dockerfile:1

# ---- Build stage ----
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /app

# Resolve dependencies before copying source so this layer is cached across code changes.
COPY pom.xml .
RUN mvn -B dependency:go-offline

COPY src ./src
# Tests need Docker (Testcontainers) for RagIntegrationTest, which isn't available during
# an image build; mvn test is what CI and local development run instead.
RUN mvn -B package -DskipTests

# ---- Runtime stage ----
FROM eclipse-temurin:17-jre-jammy
WORKDIR /app
COPY --from=build /app/target/ask-my-docs-*.jar app.jar

EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
