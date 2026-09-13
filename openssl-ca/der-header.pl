# Turn mozilla-roots.pem into the C header ca_fallback.h includes:
#   perl der-header.pl < mozilla-roots.pem > unpin_ca_der.h
use strict;
use warnings;
use MIME::Base64;

local $/;
my $pem = <STDIN>;
my ($version) = $pem =~ /^# Mozilla NSS (\S+) /m or die "no NSS version header\n";
my @der = map { decode_base64($_) } $pem =~ /-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----/sg;
die "no certificates\n" unless @der;
printf "#define UNPIN_CA_COUNT %d\n", scalar @der;
printf "static const char unpin_ca_version[] =\n    \"unpins embedded CA roots: Mozilla NSS %s, %d certificates\";\n",
    $version, scalar @der;
print "static const unsigned char unpin_ca_der[] = {\n";
my @bytes = unpack 'C*', join '', @der;
while (my @line = splice @bytes, 0, 16) {
    print join(',', @line), ",\n";
}
print "};\n";
