#!/usr/bin/env bash
# Builds the Keycloak ID-JAG issuer extension (keycloak/extensions/id-jag-issuer) with Maven in
# Docker and puts the jar into keycloak/providers, where Keycloak loads it at start.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:$PATH"
docker run --rm -v "$PWD/keycloak/extensions/id-jag-issuer":/src -v slatff-maven-cache:/root/.m2 -w /src \
  maven:3.9-eclipse-temurin-21 mvn -B -q package
mkdir -p keycloak/providers
cp keycloak/extensions/id-jag-issuer/target/slatff-id-jag-issuer.jar keycloak/providers/
chmod a+r keycloak/providers/slatff-id-jag-issuer.jar
echo "built keycloak/providers/slatff-id-jag-issuer.jar"
