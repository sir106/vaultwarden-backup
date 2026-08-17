variable "VERSION" {
  default = "latest"
}

variable "TEST_BASE_TAG" {
  default = "localhost:5000/base:dev"
}

target "docker-metadata-action" {}

target "_common" {
  inherits = ["docker-metadata-action"]
  context = "."
  dockerfile = "Dockerfile"
}

target "_common_multi_platforms" {
  platforms = [
    "linux/amd64",
    "linux/arm64",
    "linux/arm/v6",
    "linux/arm/v7"
  ]
}

target "_common_tags" {
  tags = [
    "ghcr.io/sir106/vaultwarden-backup:latest",
    "ghcr.io/sir106/vaultwarden-backup:${VERSION}"
  ]
}

target "image-stable" {
  inherits = ["_common", "_common_multi_platforms", "_common_tags"]
}

target "image-latest" {
  inherits = ["_common", "_common_multi_platforms"]
  tags = [
    "ghcr.io/sir106/vaultwarden-backup:latest"
  ]
}

target "image-schedule" {
  inherits = ["image-stable"]
}

target "image-beta" {
  inherits = ["_common", "_common_multi_platforms"]
  tags = [
    "ghcr.io/sir106/vaultwarden-backup:${VERSION}"
  ]
}

target "image-test-base" {
  inherits = ["_common", "_common_multi_platforms"]
  tags = [
    "${TEST_BASE_TAG}"
  ]
}

target "image-test" {
  inherits = ["_common"]
  dockerfile = "./tests/Dockerfile"
  contexts = {
    base = "docker-image://${TEST_BASE_TAG}"
  }
  tags = [
    "ghcr.io/sir106/vaultwarden-backup:test"
  ]
}
