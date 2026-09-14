# Exercise the embedded CA fallback of a freshly built openssl CLI.
#   sh install-check.sh <openssl> <mozilla-roots.pem>
set -eu
o=$1 roots=$2
unset NIX_SSL_CERT_FILE SSL_CERT_FILE SSL_CERT_DIR UNPIN_CA_FALLBACK
export OPENSSL_CONF=/dev/null
t=$(mktemp -d)
fail() { echo "openssl CA fallback check: $*" >&2; exit 1; }
# -no-CApath/-no-CAstore: only the default FILE lookup is consulted; the default
# directory is exercised by the no-host-store block below. -no_check_time: a
# root that expires must not fail the build - nor rebuilds of old tags.
verify() { "$o" verify -no-CApath -no-CAstore -no_check_time "$@" >/dev/null 2>&1; }
verify_dir() { "$o" verify -no-CAstore -no_check_time "$@" >/dev/null 2>&1; }

awk -v d="$t" '/-----BEGIN CERTIFICATE-----/ { n++; f = sprintf("%s/root%03d.pem", d, n) }
  f { print > f } /-----END CERTIFICATE-----/ { close(f); f = "" }' "$roots"
n=$(ls "$t"/root*.pem | wc -l)
[ "$n" -gt 100 ] || fail "only $n roots split out of $roots"

# Every embedded root is a trust anchor: catches a truncated or misparsed table.
for r in "$t"/root*.pem; do
  UNPIN_CA_FALLBACK=force verify "$r" \
    || fail "embedded roots lack $("$o" x509 -noout -subject -in "$r")"
done

"$o" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 \
  -subj /CN=unpin-ca-negative -keyout "$t/key.pem" -out "$t/self.pem" >/dev/null 2>&1 \
  || fail "cannot create the test certificate"
UNPIN_CA_FALLBACK=force verify "$t/self.pem" \
  && fail "a self-signed certificate outside the bundle verified"

# SSL_CERT_FILE is exclusive: its certificate verifies, the embedded roots do not.
SSL_CERT_FILE="$t/self.pem" verify "$t/self.pem" || fail "SSL_CERT_FILE was not honoured"
SSL_CERT_FILE="$t/self.pem" verify "$t/root001.pem" \
  && fail "SSL_CERT_FILE did not exclude the embedded roots"

# Default policy needs a host with no trust store, which the Linux build sandbox is.
if [ ! -e /etc/ssl ] && [ ! -e /etc/pki ] && [ ! -e /var/lib/ca-certificates ] \
  && [ ! -e /system/etc/security ] && [ ! -e /data/data/com.termux ]; then
  verify "$t/root001.pem" || fail "no host trust store, yet the embedded roots were not used"
  verify_dir "$t/root001.pem" || fail "the default directory lookup broke the default trust"
  UNPIN_CA_FALLBACK=force verify_dir "$t/root001.pem" \
    || fail "UNPIN_CA_FALLBACK=force with the default directory lookup failed"
  UNPIN_CA_FALLBACK=off verify "$t/root001.pem" \
    && fail "UNPIN_CA_FALLBACK=off still used the embedded roots"
else
  echo "openssl CA fallback check: host trust store visible, default-policy assertions skipped"
fi
rm -rf "$t"
echo "openssl CA fallback check: $n embedded roots OK"
