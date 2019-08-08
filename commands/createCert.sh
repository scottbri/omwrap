#!/bin/bash

# --------------------------------------------------
# Create a PCF wildcard certificate based on a domain name passed as an argument 
# Requires: the command openssl in the path
# --------------------------------------------------

if [ $# -lt 4 ] ; then
        echo "Usage: $0 Domain_Name Private_Key Certificate Cert_Configuration"
        echo ""
        echo "where:"
        echo "     Domain_Name: the parent domain from which the PCF subdomains and wildcards will originate"
        echo "     Private_Key: the file into which the Cert private key will be stored"
        echo "     Certificate: the file into which the Certificate will be stored"
        echo "     Cert_Configuration: the file into which the configuration will be stored that generates the Cert"
        echo ""
        exit 1
fi

PCF_DOMAIN_NAME="${1}"
CERT_PRIV_KEY="${2}"
CERT="${3}"
CERT_CONFIG="${4}"

cat > ${CERT_CONFIG} <<-EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
req_extensions = req_ext
distinguished_name = dn

[ dn ]
C=US
ST=California
L=San Francisco
O=PIVOTAL, INC.
OU=Workshops
CN = ${PCF_DOMAIN_NAME}

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = *.sys.${PCF_DOMAIN_NAME}
DNS.2 = *.login.sys.${PCF_DOMAIN_NAME}
DNS.3 = *.uaa.sys.${PCF_DOMAIN_NAME}
DNS.4 = *.apps.${PCF_DOMAIN_NAME}
DNS.5 = *.pks.${PCF_DOMAIN_NAME}
EOF

openssl req -x509 \
  -newkey rsa:2048 \
  -nodes \
  -keyout ${CERT_PRIV_KEY} \
  -out ${CERT} \
  -config ${CERT_CONFIG}

}
