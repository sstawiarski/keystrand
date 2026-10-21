#!/usr/bin/env bash
set -euo pipefail

# Description: Creates a self-signed code-signing certificate in the login keychain.
# Usage: scripts/make-signing-cert.sh [--name NAME] [--force]

readonly KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
readonly OPENSSL="/usr/bin/openssl"

NAME="Keystrand Local"
WORK_DIR=""

usage() {
  cat <<'USAGE'
Usage: scripts/make-signing-cert.sh [--name NAME] [--force]

Creates a self-signed code-signing certificate and private key in the login
keychain, lets codesign use the key without asking, and trusts the
certificate for code signing. macOS asks for your login password once to
change the trust settings. scripts/install.sh signs with the certificate, so
the keychain keeps remembering that Keystrand may read its saved passwords
across rebuilds.

  --name NAME  certificate name; default "Keystrand Local"
  --force      replace an existing certificate with that name (asks first)
  -h, --help   show this help
USAGE
}

die() {
  printf 'make-signing-cert.sh: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."
}

step() {
  printf '\n==> %s\n' "$*"
}

cleanup() {
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    trash "$WORK_DIR" >/dev/null 2>&1 || true
  fi
}

identity_valid() {
  security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -qF "\"$NAME\""
}

certificate_exists() {
  security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1
}

confirm_replace() {
  [[ -t 0 ]] || die "--force needs a terminal to confirm the replacement."
  local answer
  read -r -p "Delete every certificate named \"$NAME\" and its key from the login keychain? [y/N] " answer
  [[ "$answer" == [yY] || "$answer" == [yY][eE][sS] ]] || die "nothing changed."
}

delete_existing() {
  step "Deleting the existing \"$NAME\""
  while certificate_exists; do
    security delete-identity -c "$NAME" -t "$KEYCHAIN" >/dev/null 2>&1 ||
      security delete-certificate -c "$NAME" -t "$KEYCHAIN" >/dev/null ||
      die "could not delete \"$NAME\"; remove it in Keychain Access."
  done
}

write_config() {
  cat >"$1" <<CONFIG
[req]
distinguished_name = dn
x509_extensions = codesign
prompt = no

[dn]
CN = $NAME

[codesign]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CONFIG
}

# The key and bundle are encrypted with a random password that is never
# stored, so the trashed work directory holds nothing usable.
create_bundle() {
  local config="$WORK_DIR/openssl.cnf"
  write_config "$config"
  "$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -days 3650 -config "$config" \
    -keyout "$WORK_DIR/key.pem" -passout env:CERT_PASSWORD -out "$WORK_DIR/cert.pem" 2>/dev/null ||
    die "openssl could not create the certificate."
  "$OPENSSL" pkcs12 -export -name "$NAME" -inkey "$WORK_DIR/key.pem" -passin env:CERT_PASSWORD \
    -in "$WORK_DIR/cert.pem" -passout env:CERT_PASSWORD -out "$WORK_DIR/identity.p12" ||
    die "openssl could not bundle the certificate and key."
}

test_signing() {
  step "Signing a test binary with \"$NAME\""
  cp /usr/bin/true "$WORK_DIR/signing-test"
  codesign --force --sign "$NAME" "$WORK_DIR/signing-test" ||
    die "codesign could not use \"$NAME\". Run: security find-identity -v -p codesigning"
  codesign --verify "$WORK_DIR/signing-test"
}

main() {
  local force=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name)
        [[ $# -ge 2 && -n "$2" ]] || die "--name needs a value."
        NAME="$2"
        shift
        ;;
      --force) force=true ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "unknown argument '$1'." ;;
    esac
    shift
  done

  for cmd in security codesign trash; do
    require_cmd "$cmd"
  done
  [[ -x "$OPENSSL" ]] || die "$OPENSSL is missing."
  [[ -f "$KEYCHAIN" ]] || die "the login keychain $KEYCHAIN does not exist."

  if certificate_exists; then
    if [[ "$force" == false ]]; then
      if identity_valid; then
        printf 'A code-signing identity named "%s" already exists. Use --force to replace it.\n' "$NAME"
        exit 0
      fi
      die "a certificate named \"$NAME\" exists but is not a valid code-signing identity. Run with --force to replace it."
    fi
    confirm_replace
    delete_existing
  fi

  local tmp="${TMPDIR:-/tmp}"
  WORK_DIR=$(mktemp -d "${tmp%/}/keystrand-cert.XXXXXX")
  trap cleanup EXIT
  CERT_PASSWORD=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32) || true
  export CERT_PASSWORD

  step "Creating the certificate \"$NAME\""
  create_bundle

  step "Importing it into the login keychain"
  security import "$WORK_DIR/identity.p12" -k "$KEYCHAIN" -f pkcs12 -P "$CERT_PASSWORD" \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

  step "Trusting it for code signing"
  printf 'macOS now asks for your login password to change the certificate trust settings.\n'
  security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK_DIR/cert.pem" ||
    die "the certificate is in the keychain but not trusted. Run with --force to try again."

  identity_valid || die "\"$NAME\" is not listed by: security find-identity -v -p codesigning"
  test_signing
  printf '\nCreated the code-signing identity "%s".\n' "$NAME"
}

main "$@"
